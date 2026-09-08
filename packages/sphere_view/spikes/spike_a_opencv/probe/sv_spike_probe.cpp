// Spike A probe — proves the custom OpenCV build actually contains and can RUN
// every cv:: facility Phases 03/04/05 depend on.
//
// This deliberately goes further than PHASE_00_spikes.md's snippet, which only
// *constructs* each class. Construction is a weak proof for two reasons:
//
//   1. We link OpenCV statically with -ffunction-sections/--gc-sections. A
//      default constructor can survive while the algorithm body is stripped.
//   2. Several of these classes construct fine and then fail at first use
//      because an optional dependency is missing from the build.
//
// So every probe here *executes* the algorithm on a tiny synthetic input and
// reports a result value. Output is a JSON string, so the Dart side can display
// it and the human can paste it straight into the findings file.
//
// Throwaway. Nothing here ships.

#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/photo.hpp>
#include <opencv2/video/tracking.hpp>
#include <opencv2/stitching/detail/matchers.hpp>
#include <opencv2/stitching/detail/motion_estimators.hpp>
#include <opencv2/stitching/detail/seam_finders.hpp>
#include <opencv2/stitching/detail/blenders.hpp>
#include <opencv2/stitching/detail/exposure_compensate.hpp>
#include <opencv2/stitching/detail/warpers.hpp>

#include <chrono>
#include <sstream>
#include <string>
#include <vector>

namespace {

using clk = std::chrono::steady_clock;

double ms_since(clk::time_point t0) {
  return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}

// A small textured image: gradient + noise + a few hard edges. Enough for SIFT
// to find real keypoints, and for ECC/graph-cut to have gradients to work with.
cv::Mat make_textured(int w, int h, int shift) {
  cv::Mat m(h, w, CV_8UC3);
  cv::RNG rng(1234 + shift);
  rng.fill(m, cv::RNG::UNIFORM, 0, 60);
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      cv::Vec3b& p = m.at<cv::Vec3b>(y, x);
      int base = ((x + shift) * 3 + y * 2) % 200;
      p[0] = cv::saturate_cast<uchar>(p[0] + base);
      p[1] = cv::saturate_cast<uchar>(p[1] + (base / 2));
      p[2] = cv::saturate_cast<uchar>(p[2] + (200 - base));
    }
  }
  // Hard corners so SIFT has something scale-stable to latch onto.
  for (int i = 1; i < 5; ++i) {
    cv::rectangle(m, cv::Rect(shift + i * 17 % (w / 2), i * 13 % (h / 2), 21, 21),
                  cv::Scalar(255, 255, 255), -1);
    cv::circle(m, cv::Point((shift + i * 29) % w, (i * 31) % h), 7,
               cv::Scalar(0, 0, 0), -1);
  }
  return m;
}

// Each probe returns "ok:<detail>" or "FAIL:<what went wrong>". Exceptions are
// caught per-probe so one missing module cannot mask the rest of the report.
//
// Variadic because probe bodies contain top-level commas — `cv::Mat_<float>(3,3)
// << 250, 0, 160` reads as three macro arguments otherwise.
#define PROBE(name, ...)                                                     \
  do {                                                                       \
    const clk::time_point _t0 = clk::now();                                  \
    std::string _r;                                                          \
    try {                                                                    \
      __VA_ARGS__                                                            \
    } catch (const cv::Exception& e) {                                       \
      _r = std::string("FAIL:cv::Exception ") + e.what();                     \
    } catch (const std::exception& e) {                                      \
      _r = std::string("FAIL:std::exception ") + e.what();                    \
    } catch (...) {                                                          \
      _r = "FAIL:unknown exception";                                          \
    }                                                                        \
    json << "    \"" << name << "\": {\"result\": \"" << _r                   \
         << "\", \"ms\": " << (int)ms_since(_t0) << "},\n";                   \
  } while (0)

#define OK(x) _r = std::string("ok:") + (x)

std::string run_probe() {
  std::ostringstream json;
  json << "{\n";
  json << "  \"opencv_version\": \"" << cv::getVersionString() << "\",\n";
  json << "  \"cpu_features\": \"" << cv::getCPUFeaturesLine() << "\",\n";
  json << "  \"threads\": " << cv::getNumThreads() << ",\n";
  // RTTI is the one build flag that silently changes behaviour rather than
  // failing to link, so record what we actually compiled with.
#ifdef __GXX_RTTI
  json << "  \"rtti\": true,\n";
#else
  json << "  \"rtti\": false,\n";
#endif
  json << "  \"probes\": {\n";

  const cv::Mat a = make_textured(320, 240, 0);
  const cv::Mat b = make_textured(320, 240, 24);  // 24 px horizontal shift

  // -- features2d: SIFT ------------------------------------------------------
  PROBE("sift", {
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create();
    if (!sift) { _r = "FAIL:SIFT::create returned null"; }
    else {
      std::vector<cv::KeyPoint> kp;
      cv::Mat desc;
      sift->detectAndCompute(a, cv::noArray(), kp, desc);
      if (kp.empty()) _r = "FAIL:zero keypoints";
      else OK(std::to_string(kp.size()) + " keypoints, desc " +
              std::to_string(desc.cols) + "d");
    }
  });

  // -- stitching: feature matching ------------------------------------------
  PROBE("best_of_2nearest", {
    cv::detail::ImageFeatures fa, fb;
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create();
    cv::detail::computeImageFeatures(sift, a, fa);
    cv::detail::computeImageFeatures(sift, b, fb);
    fa.img_idx = 0; fb.img_idx = 1;
    cv::detail::BestOf2NearestMatcher matcher(false, 0.3f);
    cv::detail::MatchesInfo info;
    matcher(fa, fb, info);
    matcher.collectGarbage();
    OK(std::to_string(info.matches.size()) + " matches, " +
       std::to_string(info.num_inliers) + " inliers");
  });

  // -- stitching: bundle adjustment -----------------------------------------
  // Only proves it links and accepts a refinement mask; a real convergence
  // test needs real geometry and belongs in Phase 03.
  PROBE("bundle_adjuster_ray", {
    cv::detail::BundleAdjusterRay ba;
    ba.setConfThresh(1.0);
    cv::Mat mask = cv::Mat::ones(3, 3, CV_8U);
    ba.setRefinementMask(mask);
    OK("constructed, refinement mask accepted");
  });

  // -- stitching: spherical warper ------------------------------------------
  PROBE("spherical_warper", {
    cv::detail::SphericalWarper warper(200.f);
    cv::Mat K = (cv::Mat_<float>(3, 3) << 250, 0, 160, 0, 250, 120, 0, 0, 1);
    cv::Mat R = cv::Mat::eye(3, 3, CV_32F);
    cv::Mat dst;
    // RotationWarper::warp returns the top-left corner of the warped image in
    // destination coordinates, not a Rect.
    cv::Point tl = warper.warp(a, K, R, cv::INTER_LINEAR, cv::BORDER_REFLECT, dst);
    if (dst.empty()) _r = "FAIL:empty warp output";
    else OK("warped to " + std::to_string(dst.cols) + "x" +
            std::to_string(dst.rows) + " at (" + std::to_string(tl.x) + "," +
            std::to_string(tl.y) + ")");
  });

  // -- stitching: gain compensation -----------------------------------------
  PROBE("blocks_gain_compensator", {
    std::vector<cv::Point> corners{{0, 0}, {24, 0}};
    std::vector<cv::UMat> imgs(2), masks(2);
    a.copyTo(imgs[0]); b.copyTo(imgs[1]);
    cv::Mat m = cv::Mat::ones(a.size(), CV_8U) * 255;
    m.copyTo(masks[0]); m.copyTo(masks[1]);
    std::vector<std::pair<cv::UMat, uchar>> mp(2);
    mp[0] = {masks[0], 255}; mp[1] = {masks[1], 255};
    cv::detail::BlocksGainCompensator comp(4, 4);
    comp.feed(corners, imgs, mp);
    comp.apply(0, corners[0], imgs[0], masks[0]);
    OK("fed 2 images, applied");
  });

  // -- stitching: graph-cut seam finder -------------------------------------
  // The highest-value probe in the list. R1 says OpenCV's in-house GCGraph
  // makes this self-contained; this is where that claim gets executed.
  PROBE("graphcut_seam_finder", {
    std::vector<cv::UMat> imgs(2), masks(2);
    cv::Mat af, bf;
    a.convertTo(af, CV_32F); b.convertTo(bf, CV_32F);
    af.copyTo(imgs[0]); bf.copyTo(imgs[1]);
    cv::Mat m = cv::Mat::ones(a.size(), CV_8U) * 255;
    m.copyTo(masks[0]); m.copyTo(masks[1]);
    std::vector<cv::Point> corners{{0, 0}, {160, 0}};  // 50% overlap
    cv::detail::GraphCutSeamFinder finder(
        cv::detail::GraphCutSeamFinderBase::COST_COLOR_GRAD);
    finder.find(imgs, corners, masks);
    int nz0 = cv::countNonZero(masks[0].getMat(cv::ACCESS_READ));
    int nz1 = cv::countNonZero(masks[1].getMat(cv::ACCESS_READ));
    int total = a.rows * a.cols;
    // A real cut must have carved something out of at least one mask.
    if (nz0 == total && nz1 == total) _r = "FAIL:masks unchanged, no cut made";
    else OK("cut made, mask0 " + std::to_string(nz0 * 100 / total) +
            "% mask1 " + std::to_string(nz1 * 100 / total) + "%");
  });

  // -- stitching: multi-band blender ----------------------------------------
  PROBE("multiband_blender", {
    cv::detail::MultiBandBlender blender(false, 5);
    cv::Rect dst_roi(0, 0, 480, 240);
    blender.prepare(dst_roi);
    cv::Mat as, bs;
    a.convertTo(as, CV_16S); b.convertTo(bs, CV_16S);
    cv::Mat m = cv::Mat::ones(a.size(), CV_8U) * 255;
    blender.feed(as, m, cv::Point(0, 0));
    blender.feed(bs, m, cv::Point(160, 0));
    cv::Mat result, result_mask;
    blender.blend(result, result_mask);
    if (result.empty()) _r = "FAIL:empty blend output";
    else OK("blended to " + std::to_string(result.cols) + "x" +
            std::to_string(result.rows) + " type " +
            std::to_string(result.type()));
  });

  // -- photo: Mertens exposure fusion (Phase 05) ----------------------------
  PROBE("merge_mertens", {
    cv::Ptr<cv::MergeMertens> mm = cv::createMergeMertens();
    if (!mm) { _r = "FAIL:createMergeMertens returned null"; }
    else {
      std::vector<cv::Mat> stack;
      for (double g : {0.5, 1.0, 2.0}) {
        cv::Mat e; a.convertTo(e, CV_8U, g, 0); stack.push_back(e);
      }
      cv::Mat fused;
      mm->process(stack, fused);
      if (fused.empty()) _r = "FAIL:empty fusion output";
      else OK("fused 3 exposures to " + std::to_string(fused.cols) + "x" +
              std::to_string(fused.rows));
    }
  });

  // -- photo: AlignMTB ------------------------------------------------------
  PROBE("align_mtb", {
    cv::Ptr<cv::AlignMTB> am = cv::createAlignMTB();
    if (!am) { _r = "FAIL:createAlignMTB returned null"; }
    else {
      std::vector<cv::Mat> in{a, b}, out;
      am->process(in, out);
      OK("aligned " + std::to_string(out.size()) + " images");
    }
  });

  // -- video: findTransformECC (Phase 05 bracket alignment) -----------------
  // This is the probe that proves the `video` module made it into BUILD_LIST.
  PROBE("find_transform_ecc", {
    cv::Mat ga, gb;
    cv::cvtColor(a, ga, cv::COLOR_BGR2GRAY);
    cv::cvtColor(b, gb, cv::COLOR_BGR2GRAY);
    ga.convertTo(ga, CV_32F, 1.0 / 255);
    gb.convertTo(gb, CV_32F, 1.0 / 255);
    cv::Mat warp = cv::Mat::eye(2, 3, CV_32F);
    double cc = cv::findTransformECC(
        ga, gb, warp, cv::MOTION_TRANSLATION,
        cv::TermCriteria(cv::TermCriteria::COUNT + cv::TermCriteria::EPS, 30, 1e-4));
    OK("cc=" + std::to_string(cc) + " dx=" +
       std::to_string(warp.at<float>(0, 2)));
  });

  // -- calib3d: undistort (Phase 06 distortion model) ----------------------
  PROBE("undistort", {
    cv::Mat K = (cv::Mat_<double>(3, 3) << 250, 0, 160, 0, 250, 120, 0, 0, 1);
    cv::Mat d = (cv::Mat_<double>(1, 5) << -0.12, 0.03, 0.001, -0.001, 0.0);
    cv::Mat out;
    cv::undistort(a, out, K, d);
    if (out.empty()) _r = "FAIL:empty undistort output";
    else OK("undistorted " + std::to_string(out.cols) + "x" +
            std::to_string(out.rows));
  });

  // -- imgcodecs: JPEG round trip ------------------------------------------
  // opencv-mobile ships imgcodecs OFF and substitutes an stb_image shim, so
  // this probe is how we tell a real libjpeg-turbo build from that substitute.
  PROBE("jpeg_roundtrip", {
    std::vector<uchar> buf;
    if (!cv::imencode(".jpg", a, buf, {cv::IMWRITE_JPEG_QUALITY, 92})) {
      _r = "FAIL:imencode returned false";
    } else {
      cv::Mat back = cv::imdecode(buf, cv::IMREAD_COLOR);
      if (back.empty()) _r = "FAIL:imdecode returned empty";
      else if (back.size() != a.size()) _r = "FAIL:size mismatch after decode";
      else {
        cv::Mat diff;
        cv::absdiff(a, back, diff);
        OK(std::to_string(buf.size()) + " bytes, mean abs err " +
           std::to_string(cv::mean(diff)[0]));
      }
    }
  });

  json << "    \"_end\": true\n";
  json << "  }\n}";
  return json.str();
}

}  // namespace

extern "C" {

// Returns a JSON report. The returned pointer is owned by the library and
// stays valid until the next call.
const char* sv_spike_opencv_probe() {
  static std::string out;
  out = run_probe();
  return out.c_str();
}

// Cheap liveness check that does not run the full suite.
const char* sv_spike_opencv_version() {
  static std::string out;
  out = cv::getVersionString();
  return out.c_str();
}

}  // extern "C"
