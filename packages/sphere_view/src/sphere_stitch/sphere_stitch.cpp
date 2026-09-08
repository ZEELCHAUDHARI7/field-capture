// sphere_stitch.cpp — the C ABI entry point and stage orchestration.
//
// Everything here is boundary work: parse the request, turn it into the plain
// C++ structs the stages consume, run them, serialise the report. The pipeline
// itself lives in registration.cpp so that this file stays readable as a
// contract rather than as an algorithm.

#include "sphere_stitch.h"

#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>

#include "compositing.h"
#include "hdr_fuse.h"
#include "registration.h"
#include "report.h"
#include "sv_geometry.h"
#include "sv_json.h"

namespace {

using namespace sv;

void writeError(char* buffer, int32_t length, const std::string& message) {
  if (!buffer || length <= 0) return;
  const size_t copied = std::min<size_t>(message.size(), static_cast<size_t>(length - 1));
  std::memcpy(buffer, message.data(), copied);
  buffer[copied] = '\0';
}

char* duplicate(const std::string& text) {
  // Allocated with new[] and released by sv_free's delete[]. The pairing is the
  // whole reason sv_free exists: the caller is Dart, whose allocator is not
  // ours, and freeing across that boundary is undefined.
  char* out = new char[text.size() + 1];
  std::memcpy(out, text.data(), text.size());
  out[text.size()] = '\0';
  return out;
}

std::string directoryOf(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

/// Deletes stage 5's fused frames on every exit path.
///
/// They are scratch — the fused frame is reproducible from the bracket — but they
/// are also 100+ MB of it at 12 MP, and a stitch that fails halfway must not leave
/// that behind on a device whose storage is the reason the tier table exists.
struct FusedFrameGuard {
  const sv::HdrFuseResult* result = nullptr;
  ~FusedFrameGuard() {
    if (result) sv::cleanUpFusedFrames(*result);
  }
};

std::string joinPath(const std::string& directory, const std::string& relative) {
  if (relative.empty()) return directory;
  if (relative.front() == '/') return relative;  // already absolute
  if (directory.empty()) return relative;
  if (directory.back() == '/') return directory + relative;
  return directory + "/" + relative;
}

/// The tier table (architecture §6.5): output size and strip count are a device
/// property, not a user setting, because the binding constraint is memory.
int tierWidth(const std::string& tier) {
  if (tier == "low") return 4096;
  if (tier == "high") return 8192;
  return 6144;
}

void applyTier(const std::string& tier, sv::CompositingOptions& options) {
  options.outputWidth = tierWidth(tier);
  if (tier == "low") {
    options.stripCount = 4;
  } else if (tier == "high") {
    options.stripCount = 8;
    // §7: at `high` also emit a small preview, so the UI can show a result
    // instantly while the full file is still being written.
    options.emitPreview = true;
  } else {
    options.stripCount = 6;
  }
}

Pose parsePose(const Json& json) {
  Pose pose;
  pose.qx = json["qx"].asDouble(0);
  pose.qy = json["qy"].asDouble(0);
  pose.qz = json["qz"].asDouble(0);
  pose.qw = json["qw"].asDouble(1);
  pose.gravityX = json["gravity_x"].asDouble(0);
  pose.gravityY = json["gravity_y"].asDouble(1);
  pose.gravityZ = json["gravity_z"].asDouble(0);
  pose.timestampUs = json["timestamp_us"].asInt(0);
  pose.angularSpeedRadPerSec = json["angular_speed_rad_per_sec"].asDouble(0);
  return pose;
}

bool parseIntrinsics(const Json& json, Intrinsics& out, std::string& error) {
  if (!json.isObject()) {
    error = "bundle.intrinsics is missing or not an object";
    return false;
  }
  out.fx = json["fx"].asDouble(0);
  out.fy = json["fy"].asDouble(0);
  out.cx = json["cx"].asDouble(0);
  out.cy = json["cy"].asDouble(0);
  out.source = json["source"].isString() ? json["source"].asString() : "derivedFromPhysics";

  const Json& size = json["image_size"];
  out.width = size["width"].asDouble(0);
  out.height = size["height"].asDouble(0);

  if (!(out.fx > 0) || !(out.fy > 0) || !(out.width > 0) || !(out.height > 0)) {
    error = "bundle.intrinsics has non-positive fx/fy or image size";
    return false;
  }

  // A null distortion model is the EXPECTED case on most of the iOS fleet
  // (R2), so absence here is silence, not an error.
  const Json& distortion = json["distortion"];
  if (!distortion.isObject()) return true;

  const std::string type = distortion["type"].asString();
  if (type == "brown_conrady") {
    out.hasDistortion = true;
    out.isLookupTable = false;
    // Already in OpenCV order. On Android these came from LENS_DISTORTION via
    // the pure reorder {κ1,κ2,κ4,κ5,κ3}; R2 verified against AOSP that no value
    // transform is involved, so they drop straight in.
    out.k1 = distortion["k1"].asDouble(0);
    out.k2 = distortion["k2"].asDouble(0);
    out.p1 = distortion["p1"].asDouble(0);
    out.p2 = distortion["p2"].asDouble(0);
    out.k3 = distortion["k3"].asDouble(0);
  } else if (type == "lookup_table") {
    out.hasDistortion = true;
    out.isLookupTable = true;
    const Json& table = distortion["magnifications"];
    for (size_t i = 0; i < table.size(); ++i) {
      out.magnifications.push_back(table.at(i).asDouble(1.0));
    }
    out.lutCenterX = distortion["center_x"].asDouble(out.width * 0.5);
    out.lutCenterY = distortion["center_y"].asDouble(out.height * 0.5);
    if (out.magnifications.size() < 4) {
      // Present but unusable. Say so rather than fitting three coefficients to
      // two samples and reporting a distortion model that is really noise.
      out.hasDistortion = false;
      out.isLookupTable = false;
    }
  }
  return true;
}

/// Throws whatever [what] names, so the ABI guard below can be tested.
///
/// A test hook, and a necessary one: Phase 10 §6 requires proof that a C++
/// exception at the boundary is caught and mapped rather than propagated, and
/// that a `bad_alloc` produces a tier downgrade and a retry. Neither can be
/// asserted by waiting for a real 3 GB tablet to run out of memory — that is a
/// test you cannot write, only hope for. The hook is inert unless the request
/// asks for it by name, and the names are the four cases the guard branches on.
void throwIfRequested(const std::string& what) {
  if (what.empty()) return;
  if (what == "bad_alloc") throw std::bad_alloc();
  if (what == "cv_no_mem") {
    // What OpenCV *actually* raises when a Mat allocation fails. Distinct from
    // std::bad_alloc, and the reason the guard inspects cv::Exception::code.
    CV_Error(cv::Error::StsNoMem, "forced allocation failure (test hook)");
  }
  if (what == "cv") CV_Error(cv::Error::StsBadArg, "forced cv::Exception (test hook)");
  if (what == "std") throw std::runtime_error("forced std::exception (test hook)");
  if (what == "unknown") throw 42;  // NOLINT — deliberately not a std::exception
  throw std::runtime_error("unknown force_error value: " + what);
}

int32_t runStitch(const char* request_json,
                  SvProgress* progress,
                  char* error_buf, int32_t error_buf_len,
                  char** report_json_out);

}  // namespace

extern "C" {

const char* sv_version(void) {
  static const std::string version =
      std::string("sphere_stitch schema ") + std::to_string(SV_SCHEMA_VERSION) +
      " / OpenCV " + CV_VERSION;
  return version.c_str();
}

void sv_free(char* p) { delete[] p; }

/// The ABI guard (Phase 10 §4).
///
/// `noexcept` and total: an exception unwinding out of here would cross into
/// Dart's frames, which is undefined behaviour and in practice a crash with no
/// Dart stack — the worst possible diagnostic. So every throw is caught here and
/// becomes a return code and a message, and the `noexcept` makes that a
/// compile-time promise rather than a convention someone can quietly break by
/// adding a `throw` three call levels down.
///
/// The order of the handlers is the whole of the correctness argument:
/// `cv::Exception` derives from `std::exception`, so it must precede it, and
/// OpenCV's out-of-memory failure arrives *as* a `cv::Exception` rather than a
/// `std::bad_alloc`, so the code is inspected before the type decides.
int32_t sv_stitch(const char* request_json,
                  SvProgress* progress,
                  char* error_buf, int32_t error_buf_len,
                  char** report_json_out) noexcept {
  try {
    return runStitch(request_json, progress, error_buf, error_buf_len, report_json_out);
  } catch (const std::bad_alloc&) {
    writeError(error_buf, error_buf_len,
               "ran out of memory. This device cannot hold the canvas this tier "
               "asks for; the stitch will be retried one tier down.");
    return SV_ERR_OUT_OF_MEMORY;
  } catch (const cv::Exception& e) {
    // StsNoMem is how cv::fastMalloc reports a failed allocation. That is the
    // tier being too large for this device, which is a retry rather than a bug,
    // and it is the reason the code is inspected at all: mapping every
    // cv::Exception to SV_ERR_OPENCV would leave the downgrade path dead on
    // exactly the device the tier table exists for, because at 8192x4096 the
    // allocation that fails is virtually always OpenCV's rather than ours.
    if (e.code == cv::Error::StsNoMem) {
      writeError(error_buf, error_buf_len,
                 std::string("ran out of memory inside OpenCV. This device "
                             "cannot hold the canvas this tier asks for; the "
                             "stitch will be retried one tier down. (") +
                     e.what() + ")");
      return SV_ERR_OUT_OF_MEMORY;
    }
    writeError(error_buf, error_buf_len, std::string("OpenCV error: ") + e.what());
    return SV_ERR_OPENCV;
  } catch (const std::exception& e) {
    writeError(error_buf, error_buf_len, std::string("internal error: ") + e.what());
    return SV_ERR_INTERNAL;
  } catch (...) {
    // Nothing here can say what happened, which is exactly why it must not be
    // allowed to escape: an unknown code the caller can report beats a crash
    // the caller cannot.
    writeError(error_buf, error_buf_len,
               "the stitcher failed with an error it could not describe. This "
               "is a bug; please send the capture bundle.");
    return SV_ERR_UNKNOWN;
  }
}

}  // extern "C"

namespace {

int32_t runStitch(const char* request_json,
                  SvProgress* progress,
                  char* error_buf, int32_t error_buf_len,
                  char** report_json_out) {
  const auto started = std::chrono::steady_clock::now();
  if (report_json_out) *report_json_out = nullptr;

  if (!request_json) {
    writeError(error_buf, error_buf_len, "request_json is null");
    return SV_ERR_BAD_JSON;
  }

  Json request;
  std::string parseError;
  if (!Json::parse(request_json, request, parseError)) {
    writeError(error_buf, error_buf_len, "request is not valid JSON: " + parseError);
    return SV_ERR_BAD_JSON;
  }

  const int64_t schema = request["schema_version"].asInt(-1);
  if (schema != SV_SCHEMA_VERSION) {
    writeError(error_buf, error_buf_len,
               "request schema_version " + std::to_string(schema) +
                   " but this build speaks " + std::to_string(SV_SCHEMA_VERSION));
    return SV_ERR_SCHEMA;
  }

  // Inert unless asked for by name; see throwIfRequested.
  throwIfRequested(request["force_error"].isString() ? request["force_error"].asString()
                                                     : std::string());

  const std::string bundleDir = request["bundle_dir"].asString();
  const std::string tier = request["tier"].isString() ? request["tier"].asString() : "mid";
  // Defaulting to the *diagnostic* mode meant a request that simply omitted the
  // key returned SV_OK with no panorama and an empty output path — a success code
  // for a stitch that never composited. Dart always sends it, so this was latent;
  // a hand-built request, a replay script or any future caller would have hit it.
  // The production mode is the one you get by omission.
  const bool registrationOnly = request["registration_only"].asBool(false);
  const std::string outputPath = request["output_path"].asString();

  if (!registrationOnly && outputPath.empty()) {
    writeError(error_buf, error_buf_len,
               "output_path is required unless registration_only is true");
    return SV_ERR_SCHEMA;
  }

  const Json& bundle = request["bundle"];
  if (!bundle.isObject()) {
    writeError(error_buf, error_buf_len, "request.bundle is missing or not an object");
    return SV_ERR_SCHEMA;
  }

  Intrinsics intrinsics;
  std::string intrinsicsError;
  if (!parseIntrinsics(bundle["intrinsics"], intrinsics, intrinsicsError)) {
    writeError(error_buf, error_buf_len, intrinsicsError);
    return SV_ERR_SCHEMA;
  }

  const Json& positions = bundle["positions"];
  std::vector<FrameInput> frames;
  std::vector<PositionShots> brackets;
  frames.reserve(positions.size());
  brackets.reserve(positions.size());

  for (size_t i = 0; i < positions.size(); ++i) {
    const Json& position = positions.at(i);
    const Json& shots = position["shots"];
    if (shots.size() == 0) continue;

    // Every exposure goes to stage 5, which collapses them into one frame. The
    // path in FrameInput is filled in from the fusion result below — deliberately
    // left empty here, so a stage-5 change that forgot to set it fails loudly at
    // the first imread instead of silently registering the wrong exposure.
    PositionShots bracket;
    bracket.positionIndex = static_cast<int>(i);
    bracket.shots.reserve(shots.size());
    for (size_t s = 0; s < shots.size(); ++s) {
      const Json& shot = shots.at(s);
      ShotInput input;
      input.imagePath = joinPath(bundleDir, shot["file_path"].asString());
      input.evBias = shot["ev_bias"].asDouble(0);
      input.exposureTimeNs = shot["exposure_time_ns"].asInt(0);
      input.iso = static_cast<int>(shot["iso"].asInt(0));
      bracket.shots.push_back(input);
    }
    brackets.push_back(bracket);

    FrameInput frame;
    frame.pose = parsePose(position["pose"]);
    frame.positionIndex = static_cast<int>(i);
    frame.targetIndex = static_cast<int>(position["target_index"].asInt(static_cast<int64_t>(i)));
    frames.push_back(frame);
  }

  if (frames.empty()) {
    writeError(error_buf, error_buf_len, "bundle contains no captured positions with shots");
    return SV_ERR_NO_FRAMES;
  }

  // Grade the *plan*, and then stitch it whatever the grade says.
  //
  // This block used to return SV_ERR_INSUFFICIENT, and it was wrong twice over.
  // The condition read
  //
  //     minimumPairwise < 0.25 || coveredOnce < 1.0 - 1e-9
  //
  // while the message it printed blamed *overlap* whichever clause had fired.
  // So a healthy capture came back with "adjacent frames overlap by only 35%
  // (feature matching needs at least 25%)" — a sentence that refutes itself,
  // and the reason nobody could see what the real complaint was.
  //
  // The clause that actually fired was coverage, and it could not have done
  // anything else. `fraction_covered_at_least_once` is `covered / 40000` over a
  // Fibonacci lattice, so a single uncovered lattice point lands 2.5e-5 below
  // 1.0 while the tolerance is 1e-9 — 25 000x too small to admit even one. Real
  // captures always leave a few, most often at the nadir under the operator's
  // own feet, so this refused all of them. It also ignored the nadir cap that
  // S5a explicitly lets a plan declare it is skipping, which is a second way to
  // fail a sphere that was never going to be complete by design.
  //
  // It is a grade now, not a gate: nothing in here returns an error. A weak plan
  // makes a weaker panorama, and on a site walk that is the operator's call —
  // the alternative is walking back. Everything downstream was already built for
  // this. Frames that cannot be matched fall back to their IMU prior and still
  // contribute pixels ("a hole in the sphere is worse than a soft frame"), and
  // stage 14 fills whatever is left by push-pull extrapolation. The output is a
  // complete sphere either way; what changes is how much of it was photographed
  // rather than inferred, and the report states exactly that.
  std::vector<SvWarning> planWarnings;
  {
    const Json& coverage = bundle["plan"]["coverage"];
    if (coverage.isObject()) {
      const double minimumPairwise = coverage["minimum_pairwise_overlap"].asDouble(1.0);
      const double coveredOnce = coverage["fraction_covered_at_least_once"].asDouble(1.0);

      // 25% is what SIFT needs to find correspondences reliably. Below it,
      // matching degrades rather than stopping: some pairs still solve, the rest
      // fall back to IMU. That is a prediction to record, not a verdict.
      const bool thinOverlap = minimumPairwise < 0.25;
      // Half a percent of 4π sr is roughly a 15-degree patch — large enough that
      // the operator would want to know it was extrapolated. Below that it is
      // lattice quantisation and a fill nobody can see.
      const bool realHole = coveredOnce < 0.995;

      if (thinOverlap || realHole) {
        char message[1024];
        if (thinOverlap && realHole) {
          std::snprintf(
              message, sizeof(message),
              "Weak capture geometry: adjacent frames share only %.0f%% of their "
              "area (feature matching wants 25%% or more) and %.1f%% of the sphere "
              "was photographed. Stitching anyway — pairs that cannot be matched "
              "are positioned from the tablet's motion sensors instead, and the "
              "unphotographed part is extrapolated from its surroundings. Expect "
              "visible misalignment and a soft patch. Re-shooting with the guided "
              "prompts, visiting every position, is what removes both.",
              minimumPairwise * 100.0, coveredOnce * 100.0);
        } else if (thinOverlap) {
          std::snprintf(
              message, sizeof(message),
              "Adjacent frames share only %.0f%% of their area, and feature "
              "matching wants 25%% or more. Stitching anyway: pairs that still "
              "match are used, and the rest are positioned from the tablet's "
              "motion sensors, which is less accurate. Expect some visible "
              "misalignment.",
              minimumPairwise * 100.0);
        } else {
          std::snprintf(
              message, sizeof(message),
              "%.1f%% of the sphere was photographed. The remainder — most often "
              "straight down, underneath the operator — is extrapolated from the "
              "pixels around it, so the panorama is complete but that part is "
              "invented rather than photographed.",
              coveredOnce * 100.0);
        }
        Json data = Json::object();
        data.set("minimum_pairwise_overlap", Json::number(minimumPairwise));
        data.set("fraction_covered_once", Json::number(coveredOnce));
        addWarning(planWarnings, SvWarningCode::kPlanCannotRegister, message, data);
      }
    }
  }

  // ----------------------------------------------------------- stage 5 ------
  // Exposure fusion runs first, and everything after it sees one frame per
  // position (Phase 05 §0). Its result outlives the pipeline because the report
  // quotes it and because the fused frames on disk are what stages 6-13 read;
  // the guard below is what deletes them, on every exit path.
  HdrFuseOptions hdrOptions;
  hdrOptions.outputWidth = tierWidth(tier);
  {
    // The canvas the caller actually asked for decides how much frame resolution
    // is usable (§5), and `tools/replay` overrides it so S6 compares like with
    // like. Read here rather than in the compositing block below because the
    // downscale decision has to be made before a single frame is decoded.
    const Json& composite = request["compositing_options"];
    if (composite.isObject() && composite.has("output_width")) {
      hdrOptions.outputWidth =
          static_cast<int>(composite["output_width"].asInt(hdrOptions.outputWidth));
    }
    const Json& overrides = request["hdr_options"];
    if (overrides.isObject()) {
      if (overrides.has("enabled")) hdrOptions.enabled = overrides["enabled"].asBool(true);
      if (overrides.has("aligner")) {
        const std::string name = overrides["aligner"].asString();
        hdrOptions.aligner = name == "none"  ? HdrAligner::kNone
                             : name == "mtb" ? HdrAligner::kMtb
                             : name == "ecc" ? HdrAligner::kEcc
                                             : HdrAligner::kEccThenMtb;
      }
      if (overrides.has("contrast_weight"))
        hdrOptions.contrastWeight =
            static_cast<float>(overrides["contrast_weight"].asDouble(1.0));
      if (overrides.has("exposure_weight"))
        hdrOptions.exposureWeight =
            static_cast<float>(overrides["exposure_weight"].asDouble(0.0));
      if (overrides.has("max_shift_fraction"))
        hdrOptions.maxShiftFraction = overrides["max_shift_fraction"].asDouble(0.015);
      if (overrides.has("ghost_suppression"))
        hdrOptions.ghostSuppression = overrides["ghost_suppression"].asBool(true);
      if (overrides.has("ghost_threshold_stops"))
        hdrOptions.ghostThresholdStops = overrides["ghost_threshold_stops"].asDouble(0.6);
      if (overrides.has("max_oversampling"))
        hdrOptions.maxOversampling = overrides["max_oversampling"].asDouble(2.0);
      if (overrides.has("jpeg_quality"))
        hdrOptions.jpegQuality = static_cast<int>(overrides["jpeg_quality"].asInt(97));
      if (overrides.has("keep_fused_frames"))
        hdrOptions.keepFusedFrames = overrides["keep_fused_frames"].asBool(false);
      if (overrides.has("parallel_decode"))
        hdrOptions.parallelDecode = overrides["parallel_decode"].asBool(true);
      if (overrides.has("work_dir")) hdrOptions.workDir = overrides["work_dir"].asString();
    }
    if (hdrOptions.workDir.empty()) {
      const std::string base = outputPath.empty() ? bundleDir : directoryOf(outputPath);
      hdrOptions.workDir =
          base + "/.sv_hdr_" + std::to_string(static_cast<long>(::getpid()));
    }
  }

  HdrFuseResult hdrResult;
  FusedFrameGuard fusedGuard{&hdrResult};
  {
    std::string hdrError;
    const int32_t status =
        fuseBrackets(brackets, intrinsics, hdrOptions, progress, hdrResult, hdrError);
    if (status != SV_OK) {
      writeError(error_buf, error_buf_len, hdrError);
      return status;
    }
    for (size_t i = 0; i < frames.size() && i < hdrResult.positions.size(); ++i) {
      frames[i].imagePath = hdrResult.positions[i].outputPath;
    }
  }

  // §5's downscale, if it fired, means the frames the solver sees are not the
  // frames the camera wrote — so the camera it is solving for is not the one the
  // bundle describes. Scaling the intrinsics here is the whole of that
  // bookkeeping: a focal in the wrong pixel units is invisible until the warp is
  // the wrong size, which is exactly the class of bug Phase 03 §8.3 is about. The
  // report is handed the ORIGINAL intrinsics and undoes the scale itself, because
  // a consumer reading `refined_intrinsics` means the camera that took the
  // photos.
  const Intrinsics capturedIntrinsics = intrinsics;
  if (hdrResult.frameScale < 1.0) {
    const double s = hdrResult.frameScale;
    intrinsics.fx *= s;
    intrinsics.fy *= s;
    intrinsics.cx *= s;
    intrinsics.cy *= s;
    intrinsics.width = std::round(intrinsics.width * s);
    intrinsics.height = std::round(intrinsics.height * s);
    intrinsics.lutCenterX *= s;
    intrinsics.lutCenterY *= s;
  }

  RegistrationOptions options;
  // Not a test hook: the roll between the pose's frame and the JPEG's frame is a
  // property of the device that captured this bundle, so it travels with the
  // bundle. Absent means zero, which is right for the synthetic harness and for
  // any camera mounted square to its display.
  options.captureQuarterTurns =
      static_cast<int>(request["capture_quarter_turns"].asInt(0));

  // Test hooks. Present so a profile can move one knob without a rebuild —
  // §4 explicitly asks for IMU_SLACK to be tuned against harsh_imu.
  const Json& overrides = request["registration_options"];
  if (overrides.isObject()) {
    if (overrides.has("imu_slack_degrees"))
      options.imuSlackRadians = overrides["imu_slack_degrees"].asDouble(10.0) * CV_PI / 180.0;
    if (overrides.has("match_conf"))
      options.matchConf = static_cast<float>(overrides["match_conf"].asDouble(0.3));
    if (overrides.has("min_inliers"))
      options.minInliers = static_cast<int>(overrides["min_inliers"].asInt(25));
    if (overrides.has("sift_contrast_threshold"))
      options.siftContrastThreshold = overrides["sift_contrast_threshold"].asDouble(0.03);
    if (overrides.has("registration_pixels"))
      options.targetRegistrationPixels = overrides["registration_pixels"].asDouble(0.6e6);
    if (overrides.has("decode_threads"))
      options.decodeThreads = static_cast<int>(overrides["decode_threads"].asInt(4));
    if (overrides.has("feature_threads"))
      options.featureThreads = static_cast<int>(overrides["feature_threads"].asInt(4));
    if (overrides.has("max_imu_only_fraction"))
      options.maxImuOnlyFraction = overrides["max_imu_only_fraction"].asDouble(0.6);
    if (overrides.has("skip_bundle_adjustment"))
      options.skipBundleAdjustment = overrides["skip_bundle_adjustment"].asBool(false);
  }

  RegistrationResult result;
  std::string registrationError;
  int32_t status =
      registerFrames(frames, intrinsics, options, progress, result, registrationError);

  // The plan grade goes in front of whatever registration found, on every exit
  // path including the failing ones — it is the context that explains the rest
  // of the list, and a reader who sees "most of this capture is IMU-positioned"
  // without also seeing "the frames only share 18%" has to guess at why.
  if (!planWarnings.empty()) {
    result.warnings.insert(result.warnings.begin(), planWarnings.begin(),
                           planWarnings.end());
  }

  auto elapsedNow = [&started]() {
    return static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - started).count());
  };

  auto emitReport = [&](const CompositingResult* compositing) {
    if (!report_json_out) return;
    const Json report = buildReport(result, capturedIntrinsics, tier, elapsedNow(),
                                    compositing, &hdrResult);
    *report_json_out = duplicate(report.dump(2));
  };

  // A report is emitted even on a partial failure. Architecture §8's rule is
  // never to degrade silently: a run that could not register should still hand
  // back the numbers that prove it, rather than only an error string.
  if (status != SV_OK) {
    if (status != SV_ERR_CANCELLED) emitReport(nullptr);
    writeError(error_buf, error_buf_len, registrationError);
    return status;
  }

  if (registrationOnly) {
    emitReport(nullptr);
    return SV_OK;
  }

  // ---------------------------------------------------- stages 10-15 --------
  CompositingOptions compositingOptions;
  applyTier(tier, compositingOptions);
  compositingOptions.outputPath = outputPath;

  // Test hooks, same reasoning as the registration overrides above: §8's table
  // asks for a strip-vs-full-canvas comparison and a graph-cut-vs-feather
  // comparison, and both have to be reachable without a rebuild or they will
  // not be run.
  const Json& composite = request["compositing_options"];
  if (composite.isObject()) {
    if (composite.has("output_width"))
      compositingOptions.outputWidth = static_cast<int>(composite["output_width"].asInt(6144));
    if (composite.has("strip_count"))
      compositingOptions.stripCount = static_cast<int>(composite["strip_count"].asInt(6));
    if (composite.has("wrap_pad"))
      compositingOptions.wrapPadPx = static_cast<int>(composite["wrap_pad"].asInt(256));
    if (composite.has("num_bands"))
      compositingOptions.numBands = static_cast<int>(composite["num_bands"].asInt(0));
    if (composite.has("strip_pad"))
      compositingOptions.stripPadPx = static_cast<int>(composite["strip_pad"].asInt(0));
    if (composite.has("seam_finder")) {
      const std::string mode = composite["seam_finder"].asString();
      // The two sides of §8's parallax_1m comparison. "feather" is not a
      // shipping mode; it is the control the graph cut has to beat, and it moves
      // the blender with it because the control is the whole of what the old Dart
      // stitcher did — no seam finder, feather across the entire overlap.
      compositingOptions.seamMode =
          mode == "feather" ? SeamMode::kFeather : SeamMode::kGraphCut;
      compositingOptions.blendMode =
          mode == "feather" ? BlendMode::kFeather : BlendMode::kMultiBand;
    }
    // Set after the pairing above so it can override it. Naming the blender
    // separately is what turns the comparison into an experiment with one
    // variable: holding multi-band fixed and moving only the seam finder
    // attributes the difference to the seam finder, which is the claim §4
    // actually makes.
    if (composite.has("blender")) {
      compositingOptions.blendMode = composite["blender"].asString() == "feather"
                                         ? BlendMode::kFeather
                                         : BlendMode::kMultiBand;
    }
    if (composite.has("verify_strip_equivalence"))
      compositingOptions.verifyStripEquivalence =
          composite["verify_strip_equivalence"].asBool(false);
    if (composite.has("emit_debug_maps"))
      compositingOptions.emitDebugMaps = composite["emit_debug_maps"].asBool(false);
    if (composite.has("fill_poles"))
      compositingOptions.fillPoles = composite["fill_poles"].asBool(true);
    if (composite.has("gain_compensation"))
      compositingOptions.compensateExposure = composite["gain_compensation"].asBool(true);
    if (composite.has("emit_preview"))
      compositingOptions.emitPreview = composite["emit_preview"].asBool(false);
    if (composite.has("jpeg_quality"))
      compositingOptions.jpegQuality = static_cast<int>(composite["jpeg_quality"].asInt(92));
    if (composite.has("work_dir"))
      compositingOptions.workDir = composite["work_dir"].asString();
  }

  CompositingResult compositingResult;
  std::string compositingError;
  status = compositePanorama(frames, intrinsics, result, compositingOptions, progress,
                             compositingResult, compositingError);

  if (status != SV_OK) {
    if (status != SV_ERR_CANCELLED) emitReport(&compositingResult);
    writeError(error_buf, error_buf_len, compositingError);
    return status;
  }

  emitReport(&compositingResult);
  return SV_OK;
}

}  // namespace
