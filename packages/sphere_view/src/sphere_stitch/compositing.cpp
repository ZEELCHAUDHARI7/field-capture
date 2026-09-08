#include "compositing.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <utility>

#include <fcntl.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/stitching/detail/blenders.hpp>
#include <opencv2/stitching/detail/exposure_compensate.hpp>
#include <opencv2/stitching/detail/seam_finders.hpp>
#include <opencv2/stitching/detail/util.hpp>
#include <opencv2/stitching/detail/warpers.hpp>

#include "pole_fill.h"

namespace sv {
namespace {

using Clock = std::chrono::steady_clock;

/// Peak RSS so far, in MB. `ru_maxrss` is bytes on Darwin and kilobytes on
/// Linux, which is a difference worth encoding once rather than discovering on
/// the device.
int peakRssMb() {
  struct rusage usage {};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
#if defined(__APPLE__)
  return static_cast<int>(usage.ru_maxrss / (1024 * 1024));
#else
  return static_cast<int>(usage.ru_maxrss / 1024);
#endif
}

int elapsedMs(Clock::time_point since) {
  return static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - since).count());
}

void setStage(SvProgress* progress, int32_t stage, int32_t permille) {
  if (!progress) return;
  progress->stage = stage;
  progress->permille = permille;
}

bool cancelled(const SvProgress* progress) {
  return progress && progress->cancel != 0;
}

std::string directoryOf(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

std::string stemOf(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  const std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
  const size_t dot = name.find_last_of('.');
  return dot == std::string::npos ? name : name.substr(0, dot);
}

std::string lowerExtension(const std::string& path) {
  const size_t dot = path.find_last_of('.');
  if (dot == std::string::npos) return "";
  std::string extension = path.substr(dot);
  for (char& c : extension) c = static_cast<char>(std::tolower(c));
  return extension;
}

// ───────────────────────── the warped-frame scratch store ────────────────────

/// A read-only mmap of one file.
///
/// §5: "warped frames are held on disk as intermediate files and memory-mapped
/// per strip, not all kept in RAM — otherwise the warped frames themselves
/// (29 × ~12 MB) exceed the budget before blending starts." Mapping rather than
/// reading also means a sub-rectangle costs nothing: the kernel pages in the
/// rows a strip touches and no more.
class MappedFile {
 public:
  MappedFile() = default;
  MappedFile(const MappedFile&) = delete;
  MappedFile& operator=(const MappedFile&) = delete;
  ~MappedFile() { close(); }

  bool open(const std::string& path, size_t expected) {
    close();
    const int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    void* mapped = ::mmap(nullptr, expected, PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (mapped == MAP_FAILED) return false;
    base_ = static_cast<const uchar*>(mapped);
    size_ = expected;
    return true;
  }

  void close() {
    if (base_) ::munmap(const_cast<uchar*>(base_), size_);
    base_ = nullptr;
    size_ = 0;
  }

  const uchar* base() const { return base_; }

 private:
  const uchar* base_ = nullptr;
  size_t size_ = 0;
};

/// The warped frames, on disk, addressable by sub-rectangle.
class WarpStore {
 public:
  explicit WarpStore(std::string directory) : directory_(std::move(directory)) {
    ::mkdir(directory_.c_str(), 0700);
  }

  ~WarpStore() {
    entries_.clear();
    for (const std::string& path : written_) std::remove(path.c_str());
    ::rmdir(directory_.c_str());
  }

  WarpStore(const WarpStore&) = delete;
  WarpStore& operator=(const WarpStore&) = delete;

  bool add(int index, const cv::Mat& bgr, const cv::Mat& mask, std::string& error) {
    CV_Assert(bgr.type() == CV_8UC3 && mask.type() == CV_8U && bgr.size() == mask.size());
    const std::string imagePath = path(index, "bgr");
    const std::string maskPath = path(index, "msk");
    if (!writeRows(imagePath, bgr, error) || !writeRows(maskPath, mask, error)) return false;
    written_.push_back(imagePath);
    written_.push_back(maskPath);

    while (entries_.size() <= static_cast<size_t>(index)) {
      entries_.push_back(std::unique_ptr<Entry>(new Entry()));
    }
    Entry& entry = *entries_[index];
    entry.size = bgr.size();
    if (!entry.image.open(imagePath, static_cast<size_t>(bgr.rows) * bgr.cols * 3) ||
        !entry.mask.open(maskPath, static_cast<size_t>(mask.rows) * mask.cols)) {
      error = "could not memory-map the warped frame scratch file " + imagePath;
      return false;
    }
    return true;
  }

  cv::Size sizeOf(int index) const { return entries_[index]->size; }

  /// Zero-copy header over the mapped bytes. The Mat is read-only in fact
  /// though not in type; every caller clones before touching it.
  cv::Mat image(int index, const cv::Rect& local) const {
    const Entry& entry = *entries_[index];
    const size_t stride = static_cast<size_t>(entry.size.width) * 3;
    auto* start = const_cast<uchar*>(entry.image.base()) + local.y * stride + local.x * 3;
    return cv::Mat(local.height, local.width, CV_8UC3, start, stride);
  }

  cv::Mat mask(int index, const cv::Rect& local) const {
    const Entry& entry = *entries_[index];
    const auto stride = static_cast<size_t>(entry.size.width);
    auto* start = const_cast<uchar*>(entry.mask.base()) + local.y * stride + local.x;
    return cv::Mat(local.height, local.width, CV_8U, start, stride);
  }

 private:
  struct Entry {
    cv::Size size;
    MappedFile image;
    MappedFile mask;
  };

  std::string path(int index, const char* suffix) const {
    return directory_ + "/w" + std::to_string(index) + "." + suffix;
  }

  static bool writeRows(const std::string& path, const cv::Mat& source, std::string& error) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
      error = "could not create the warped frame scratch file " + path;
      return false;
    }
    const std::streamsize rowBytes = static_cast<std::streamsize>(source.cols) * source.elemSize();
    for (int y = 0; y < source.rows; ++y) {
      out.write(reinterpret_cast<const char*>(source.ptr(y)), rowBytes);
    }
    out.close();
    if (!out) {
      error = "could not write the warped frame scratch file " + path +
              " (out of disk space?)";
      return false;
    }
    return true;
  }

  std::string directory_;
  std::vector<std::string> written_;
  std::vector<std::unique_ptr<Entry>> entries_;
};

// ───────────────────────────── gain application ──────────────────────────────

/// Applies a `BlocksGainCompensator` gain map to a sub-rectangle of a tile.
///
/// `BlocksCompensator::apply` resizes the gain map onto the *whole* image it is
/// handed, so handing it a strip's worth of a tile would stretch the whole
/// correction field over that strip. Doing the interpolation here, against the
/// tile's full size and the sub-rectangle's absolute offset within it, is what
/// lets the gain be applied one strip at a time — and it is also what keeps a
/// wrap-duplicate tile in exact step with its original, since both index the
/// same map with the same local coordinates.
void applyGainMap(cv::Mat& bgr, const cv::Mat& gain, cv::Size tileSize, cv::Point offset) {
  if (gain.empty() || bgr.empty()) return;
  CV_Assert(bgr.type() == CV_8UC3 && gain.type() == CV_32F);

  // The same convention cv::resize's INTER_LINEAR uses, so a full-tile call
  // here and BlocksCompensator::apply agree pixel for pixel.
  const double sx = static_cast<double>(gain.cols) / tileSize.width;
  const double sy = static_cast<double>(gain.rows) / tileSize.height;

  std::vector<int> x0(bgr.cols), x1(bgr.cols);
  std::vector<float> wx(bgr.cols);
  for (int x = 0; x < bgr.cols; ++x) {
    double u = (offset.x + x + 0.5) * sx - 0.5;
    u = std::max(0.0, std::min(u, gain.cols - 1.0));
    x0[x] = static_cast<int>(u);
    x1[x] = std::min(x0[x] + 1, gain.cols - 1);
    wx[x] = static_cast<float>(u - x0[x]);
  }

  for (int y = 0; y < bgr.rows; ++y) {
    double v = (offset.y + y + 0.5) * sy - 0.5;
    v = std::max(0.0, std::min(v, gain.rows - 1.0));
    const int y0 = static_cast<int>(v);
    const int y1 = std::min(y0 + 1, gain.rows - 1);
    const auto wy = static_cast<float>(v - y0);

    const float* top = gain.ptr<float>(y0);
    const float* bottom = gain.ptr<float>(y1);
    cv::Vec3b* row = bgr.ptr<cv::Vec3b>(y);
    for (int x = 0; x < bgr.cols; ++x) {
      const float a = top[x0[x]] * (1 - wx[x]) + top[x1[x]] * wx[x];
      const float b = bottom[x0[x]] * (1 - wx[x]) + bottom[x1[x]] * wx[x];
      const float g = a * (1 - wy) + b * wy;
      cv::Vec3b& pixel = row[x];
      pixel[0] = cv::saturate_cast<uchar>(pixel[0] * g);
      pixel[1] = cv::saturate_cast<uchar>(pixel[1] * g);
      pixel[2] = cv::saturate_cast<uchar>(pixel[2] * g);
    }
  }
}

/// Nearest-neighbour upscale of a seam-scale mask onto [sub], which is given in
/// the full-resolution tile's own coordinates.
///
/// §4 upscales seam masks with `INTER_NEAREST` precisely because seam paths do
/// not need full resolution. Nearest is also the only interpolation that lets
/// this be done a sub-rectangle at a time and still agree exactly with a
/// whole-tile resize, which is what the strip blend depends on.
void upscaleMaskNearest(const cv::Mat& small, cv::Size tileSize, const cv::Rect& sub,
                        cv::Mat& out) {
  out.create(sub.height, sub.width, CV_8U);
  const double sx = static_cast<double>(small.cols) / tileSize.width;
  const double sy = static_cast<double>(small.rows) / tileSize.height;

  std::vector<int> columns(sub.width);
  for (int x = 0; x < sub.width; ++x) {
    columns[x] = std::min(static_cast<int>((sub.x + x) * sx), small.cols - 1);
  }
  for (int y = 0; y < sub.height; ++y) {
    const int sourceY = std::min(static_cast<int>((sub.y + y) * sy), small.rows - 1);
    const uchar* source = small.ptr<uchar>(sourceY);
    uchar* target = out.ptr<uchar>(y);
    for (int x = 0; x < sub.width; ++x) target[x] = source[columns[x]];
  }
}

// ───────────────────────────── warped-frame tiles ────────────────────────────

/// Warps one frame onto the equirect, over a ROI that is right at the poles.
///
/// This exists because `SphericalWarper::buildMaps` gets the ROI wrong for a
/// frame that looks at a pole, and gets it wrong in the direction that silently
/// throws photography away. Measured on `pristine`, whose plan includes two
/// zenith and two nadir shots:
///
/// - the zenith frame's centre projects to `v = 0.2` — the pole itself — and the
///   ROI came back as rows `141…1023`. The entire polar cap, 141 rows of full
///   canvas width, lay outside the ROI and was never rendered. Coverage came out
///   at 0.959 with both caps black.
/// - the nadir frame's centre projects to `v = 1023.8`, and its ROI came back as
///   rows `0…882`. The same defect, mirrored.
///
/// The cause is visible in `SphericalWarper::detectResultRoi`: it decides which
/// pole a frame contains from the sign of `±rinv[4]`, the y-component of the pano
/// +Y axis in camera coordinates. For a frame aimed *at* a pole that axis is
/// almost perpendicular to camera y, so `rinv[4] ≈ 0` and the sign is decided by
/// floating-point noise; and the point it then projects to test visibility,
/// `(rinv[1], −rinv[4], rinv[7])`, is not the pole direction (that would be
/// `−(rinv[1], rinv[4], rinv[7])`), with no check that the pole is even in front
/// of the camera. Both frames took the branch for the pole they do *not* contain,
/// so each ROI was extended away from its own cap and toward the far one.
///
/// So the ROI is computed here and the maps are filled here — but through
/// `SphericalProjector`, OpenCV's own mapping, rather than a re-derivation of
/// §3. The projection stays the library's; only the rectangle it is evaluated
/// over becomes ours.
struct WarpedFrame {
  cv::Rect roi;    ///< In warper coordinates: u ∈ [−W/2, W/2], v ∈ [0, H].
  cv::Mat image;   ///< CV_8UC3, `roi.size() + (1,1)`.
  cv::Mat mask;    ///< CV_8U.
};

/// Whether the pano direction [pole] falls inside a [srcSize] frame with
/// intrinsics [k] and rotation [rotation] (camera→pano).
bool poleIsInsideFrame(const cv::Vec3f& pole, const cv::Mat& k, const cv::Mat& rotation,
                       cv::Size srcSize) {
  // rotation is camera→pano and orthonormal, so its transpose takes the pano
  // direction into camera coordinates.
  cv::Vec3f camera(0, 0, 0);
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) camera[r] += rotation.at<float>(c, r) * pole[c];
  }
  // Behind the camera cannot be visible, whatever the pinhole algebra says. This
  // is the check whose absence lets the stock version fire on the wrong pole.
  if (camera[2] <= 1e-6f) return false;
  const float x = k.at<float>(0, 0) * camera[0] / camera[2] + k.at<float>(0, 2);
  const float y = k.at<float>(1, 1) * camera[1] / camera[2] + k.at<float>(1, 2);
  return x >= 0 && x <= srcSize.width - 1 && y >= 0 && y <= srcSize.height - 1;
}

/// Warps [source] and [sourceMask] onto the equirect band the frame occupies.
///
/// [canvasWidth] and [canvasHeight] are the unpadded equirect; the ROI is
/// returned in warper coordinates and the caller places it.
WarpedFrame warpFrameToEquirect(double warpScale, const cv::Mat& k, const cv::Mat& rotation,
                                const cv::Mat& source, const cv::Mat& sourceMask,
                                int canvasWidth, int canvasHeight) {
  const cv::Rect roi =
      sphericalWarpRoi(warpScale, k, rotation, source.size(), canvasWidth, canvasHeight);

  WarpedFrame out;
  out.roi = roi;

  cv::detail::SphericalProjector projector;
  projector.scale = static_cast<float>(warpScale);
  projector.setCameraParams(k, rotation);

  // `RotationWarperBase::buildMaps` walks v and u inclusive of the bottom-right
  // corner, which is why a warped frame is `roi.size() + (1,1)`. Matching that
  // exactly matters: using roi.size() instead shears the frame by a pixel at the
  // far edge.
  cv::Mat xmap(roi.height + 1, roi.width + 1, CV_32F);
  cv::Mat ymap(roi.height + 1, roi.width + 1, CV_32F);
  for (int v = 0; v <= roi.height; ++v) {
    float* xrow = xmap.ptr<float>(v);
    float* yrow = ymap.ptr<float>(v);
    for (int u = 0; u <= roi.width; ++u) {
      projector.mapBackward(static_cast<float>(roi.x + u), static_cast<float>(roi.y + v),
                            xrow[u], yrow[u]);
    }
  }

  // Bicubic for the colour, and the reason is worth stating because the usual
  // instinct when a warp scales *down* is the opposite one — prefilter, or the
  // result aliases.
  //
  // Whether that instinct applies depends on what is in the source above the
  // output's Nyquist frequency, and here the answer is nothing. A captured frame
  // has already been band-limited by the lens and the sensor's own pixel
  // aperture, and the equirect at any tier we ship is at least as fine as the
  // frame is (at `mid`, 0.059°/px against a frame's 0.11°/px), so the warp is
  // magnifying and a sharp interpolator is simply better. Prefiltering would
  // throw away detail to prevent aliasing that is not there.
  //
  // Bicubic overshoots at a hard edge, and at the frame border it would reach
  // past it into the BORDER_CONSTANT zero and leave a dark fringe. It does not,
  // because §1's mask erosion removes 1.5% of the frame's smaller dimension —
  // seven pixels on a 480×640 frame against bicubic's two-pixel support — so the
  // fringe is outside the mask before the seam finder ever sees it. The two
  // decisions are load-bearing for each other.
  cv::remap(source, out.image, xmap, ymap, cv::INTER_CUBIC, cv::BORDER_CONSTANT);
  cv::remap(sourceMask, out.mask, xmap, ymap, cv::INTER_NEAREST, cv::BORDER_CONSTANT);
  return out;
}

/// One frame's warped footprint, and the copies of it the wrap padding needs.
struct FrameTiles {
  int frameIndex = 0;
  int positionIndex = 0;

  /// Size of the warped frame as stored, which is `warpRoi().size() + (1,1)` —
  /// `RotationWarperBase::buildMaps` allocates one extra row and column beyond
  /// the Rect it returns, and using the Rect's size instead shears the frame by
  /// a pixel at the far edge.
  cv::Size warpedSize;

  /// The primary copy, at the position the warper put it. Always lies entirely
  /// inside the crop window, since `u = scale·atan2(x,z) ∈ [−W/2, W/2]`.
  cv::Rect primary;

  /// Every copy on the padded canvas, primary first. `local` is the copy's
  /// offset inside the warped frame, so a duplicate indexes the same gain map
  /// and the same seam mask as the primary and is therefore identical to it by
  /// construction rather than by coincidence (§2).
  struct Copy {
    cv::Rect rect;
    cv::Point local;
  };
  std::vector<Copy> copies;

  /// Seam-scale image and mask, held in RAM: at 0.1 MP of canvas the whole set
  /// is a few MB.
  cv::Mat small;
  cv::Mat smallMask;

  /// The seam-cut mask, at seam scale, covering the whole warped frame.
  cv::Mat seamMask;

  /// The compensator's gain map for this frame.
  cv::Mat gain;
};

/// Area-weighted (`cos(pitch)`) fraction of rows at or above each count.
void coverageFractions(const cv::Mat& counts, double& atLeastOnce, double& atLeastTwice) {
  double total = 0, once = 0, twice = 0;
  for (int y = 0; y < counts.rows; ++y) {
    const double pitch = (CV_PI * 0.5) * (1.0 - 2.0 * (y + 0.5) / counts.rows);
    const double area = std::cos(pitch);
    const uchar* row = counts.ptr<uchar>(y);
    for (int x = 0; x < counts.cols; ++x) {
      total += area;
      if (row[x] >= 1) once += area;
      if (row[x] >= 2) twice += area;
    }
  }
  atLeastOnce = total > 0 ? once / total : 0.0;
  atLeastTwice = total > 0 ? twice / total : 0.0;
}

/// `SVMP`, width, height, bytes-per-pixel, then the rows.
///
/// A raw file rather than a PNG for two separate reasons, and both matter.
///
/// For the debug maps: the label map is signed 32-bit with two negative
/// sentinels in it — uncovered and pole-filled — and every lossless image format
/// would need those encoded into an offset the reader then has to undo.
///
/// For the panorama, when `tools/replay` asks for one: the pinned OpenCV build
/// has **JPEG and nothing else** (Spike A's `config.sh` — PNG is off, which also
/// keeps zlib out of the device binary). S6's `pristine` target is 42 dB and
/// JPEG at quality 92 lands close enough to that to be indistinguishable from a
/// stitching error, so the harness needs something lossless; adding a codec just
/// for the harness would break PHASE_02 §2's requirement that replay runs the
/// same library, module list included. Three bytes per pixel and no encoder at
/// all settles it — and it is faster than PNG besides.
///
/// The harness reads this with one `ByteData` view.
bool writeMapFile(const std::string& path, const cv::Mat& map, std::string& error) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) {
    error = "could not write the debug map " + path;
    return false;
  }
  const char magic[4] = {'S', 'V', 'M', 'P'};
  const int32_t header[3] = {map.cols, map.rows, static_cast<int32_t>(map.elemSize())};
  out.write(magic, 4);
  out.write(reinterpret_cast<const char*>(header), sizeof(header));
  const std::streamsize rowBytes = static_cast<std::streamsize>(map.cols) * map.elemSize();
  for (int y = 0; y < map.rows; ++y) {
    out.write(reinterpret_cast<const char*>(map.ptr(y)), rowBytes);
  }
  out.close();
  if (out) return true;
  error = "could not finish writing the debug map " + path;
  return false;
}

}  // namespace

/// Runs [finder] one overlapping pair at a time instead of in a single call.
///
/// **This is not an optimisation; it is what makes stage 12 cancellable at
/// all.** `GraphCutSeamFinder::find` is one call with no poll point inside it,
/// and it measures 542 ms on `nominal` at `high` tier on the desktop host —
/// against a pipeline that runs in 17.5 s there and is budgeted at 60 s on the
/// device (S8). Scaled, the device figure is a couple of seconds, which is four
/// times Phase 10 §3's 500 ms bound, from the one stage a user is most likely
/// to be staring at.
///
/// The decomposition is exact rather than approximate, and the reason is worth
/// stating because "we split the algorithm up" normally means "we changed the
/// answer". `GraphCutSeamFinder::Impl` derives from `PairwiseSeamFinder`, whose
/// `run()` is exactly this double loop over overlapping pairs, calling
/// `findInPair(i, j)`. `findInPair` reads only images `i` and `j`, their
/// gradients, their corners, and the *current* masks `i` and `j`, and writes
/// only those two masks. So iterating the same pairs in the same order, over
/// masks carried forward, performs the identical sequence of operations on the
/// identical inputs. `testPairwiseSeamMatchesSingleCall` asserts that
/// bit-for-bit rather than taking the argument's word for it.
///
/// It costs something: each image's Sobel gradients are recomputed once per
/// pair it takes part in, rather than once. How much is not resolvable on this
/// host at this sample size — `seam_find` on the same bundle measured 542 ms
/// before the change and 371 ms and 682 ms on two runs after it, so run-to-run
/// noise is larger than the overhead. It is reported per run rather than
/// asserted, and `seam_pair_max_ms` is the number that matters: 25 ms, against
/// the 542 ms it replaced.
int32_t findSeamsPairwise(cv::detail::SeamFinder& finder,
                          const std::vector<cv::UMat>& images,
                          const std::vector<cv::Point>& corners,
                          std::vector<cv::UMat>& masks,
                          SvProgress* progress,
                          std::string& error,
                          int* slowestPairMs) {
  const size_t n = images.size();
  if (n < 2) return SV_OK;
  if (slowestPairMs) *slowestPairMs = 0;

  // Counted first so the progress bar moves smoothly through a stage whose
  // work is quadratic in frames but sparse in practice — most pairs of a 34
  // frame sphere do not overlap at all.
  size_t total = 0;
  for (size_t i = 0; i + 1 < n; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
      cv::Rect roi;
      if (cv::detail::overlapRoi(corners[i], corners[j], images[i].size(),
                                 images[j].size(), roi)) {
        ++total;
      }
    }
  }

  size_t done = 0;
  for (size_t i = 0; i + 1 < n; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
      cv::Rect roi;
      if (!cv::detail::overlapRoi(corners[i], corners[j], images[i].size(),
                                  images[j].size(), roi)) {
        continue;
      }
      if (cancelled(progress)) {
        error = "cancelled during seam finding";
        return SV_ERR_CANCELLED;
      }
      // The masks are passed by header, so `findInPair` writes through to the
      // caller's buffers and the next pair sees the previous pair's cut —
      // which is precisely the carry-forward `run()` relies on. Assigned back
      // anyway, so the dependency on UMat's shallow-copy semantics is stated
      // rather than assumed.
      std::vector<cv::UMat> pairImages{images[i], images[j]};
      std::vector<cv::Point> pairCorners{corners[i], corners[j]};
      std::vector<cv::UMat> pairMasks{masks[i], masks[j]};
      const auto pairStart = Clock::now();
      finder.find(pairImages, pairCorners, pairMasks);
      if (slowestPairMs) {
        *slowestPairMs = std::max(*slowestPairMs, elapsedMs(pairStart));
      }
      masks[i] = pairMasks[0];
      masks[j] = pairMasks[1];

      ++done;
      if (total > 0) {
        setStage(progress, SV_STAGE_SEAMING,
                 static_cast<int32_t>(1000 * done / total));
      }
    }
  }
  return SV_OK;
}

cv::Rect sphericalWarpRoi(double warpScale, const cv::Mat& k, const cv::Mat& rotation,
                          cv::Size srcSize, int canvasWidth, int canvasHeight) {
  cv::Ptr<cv::detail::RotationWarper> warper =
      cv::makePtr<cv::detail::SphericalWarper>(static_cast<float>(warpScale));
  cv::Rect roi = warper->warpRoi(srcSize, k, rotation);

  // Pano −Y is v = 0 and pano +Y is v = H: `mapForward` puts
  // v = scale·(π − acos(y/r)), so y = −r gives 0 and y = +r gives π·scale.
  const bool hasZenith = poleIsInsideFrame(cv::Vec3f(0, -1, 0), k, rotation, srcSize);
  const bool hasNadir = poleIsInsideFrame(cv::Vec3f(0, 1, 0), k, rotation, srcSize);

  if (hasZenith || hasNadir) {
    // Every meridian passes through a pole, so a frame containing one spans the
    // whole u range — pitfall §9.5, and a geometric necessity rather than a
    // heuristic. The v range reaches the pole itself.
    roi.x = -canvasWidth / 2;
    roi.width = canvasWidth;
    const int top = hasZenith ? 0 : roi.y;
    const int bottom = hasNadir ? canvasHeight : roi.y + roi.height;
    roi.y = top;
    roi.height = bottom - top;
  }

  // Nothing outside v ∈ [0, H] is on the sphere.
  roi.y = std::max(roi.y, 0);
  roi.height = std::min(roi.height, canvasHeight - roi.y);
  return roi;
}

int stripPadForBands(int numBands) { return (1 << numBands) * 4; }

int bandsForWidth(int outputWidth) {
  // 5 bands at 8192, one fewer per halving, floored at 1. `high` keeps 5, `mid`
  // and `low` land on 5 and 4, and the 2048-wide replay canvas on 3.
  const int reference = 8192;
  const int bands =
      outputWidth >= reference
          ? 5
          : 5 - static_cast<int>(std::lround(std::log2(static_cast<double>(reference) /
                                                       std::max(1, outputWidth))));
  return std::max(1, std::min(5, bands));
}

int alignedStripHeight(int canvasHeight, int stripCount, int numBands) {
  const int strips = std::max(1, stripCount);
  const int lattice = 1 << std::max(0, numBands);
  const int nominal = (canvasHeight + strips - 1) / strips;
  const int aligned = ((nominal + lattice - 1) / lattice) * lattice;
  return std::max(lattice, std::min(aligned, canvasHeight));
}

int blendTilesInStrips(const std::vector<BlendTile>& tiles,
                       cv::Size canvasSize,
                       cv::Rect crop,
                       int numBands,
                       int stripCount,
                       int stripPad,
                       BlendMode mode,
                       SvProgress* progress,
                       cv::Mat& canvas,
                       cv::Mat* blendedMask,
                       std::string& error) {
  const cv::Rect canvasRect(0, 0, canvasSize.width, canvasSize.height);
  if (crop.empty()) crop = canvasRect;
  crop &= canvasRect;

  canvas.create(crop.size(), CV_8UC3);
  canvas.setTo(cv::Scalar::all(0));
  if (blendedMask) {
    blendedMask->create(crop.size(), CV_8U);
    blendedMask->setTo(0);
  }
  // A `FeatherBlender` weights each frame by the distance to its own mask edge,
  // computed over whatever it was fed — so a strip-clipped mask gets small
  // distances at the strip boundary and the seam between strips becomes visible.
  // Multi-band has no such dependence, which is why §5's strip trick is stated
  // for it and not as a general one. Feather is only the control in §8's
  // parallax comparison, so the honest thing is to blend it whole rather than to
  // hand the comparison a banded control and call the difference a result.
  const int strips = mode == BlendMode::kMultiBand
                         ? std::max(1, stripCount)
                         : 1;
  const int stripHeight = alignedStripHeight(canvasSize.height, strips, numBands);
  const int stripsNeeded = (canvasSize.height + stripHeight - 1) / stripHeight;

  for (int s = 0; s < stripsNeeded; ++s) {
    if (cancelled(progress)) {
      error = "cancelled during blending";
      return SV_ERR_CANCELLED;
    }

    cv::Rect keep(0, s * stripHeight, canvasSize.width,
                  std::min(stripHeight, canvasSize.height - s * stripHeight));
    if (keep.height <= 0) break;
    const cv::Rect work =
        cv::Rect(0, keep.y - stripPad, canvasSize.width, keep.height + 2 * stripPad) &
        canvasRect;

    cv::Ptr<cv::detail::Blender> blender;
    if (mode == BlendMode::kMultiBand) {
      blender = cv::makePtr<cv::detail::MultiBandBlender>(/*try_gpu=*/false, numBands);
    } else {
      blender = cv::makePtr<cv::detail::FeatherBlender>();
    }

    try {
      blender->prepare(work);
    } catch (const cv::Exception& e) {
      error = std::string("blender preparation failed: ") + e.what();
      return SV_ERR_INTERNAL;
    }

    int fed = 0;
    for (const BlendTile& tile : tiles) {
      // Phase 10 §3 sets a 500 ms cancellation bound and names one blend strip
      // as the longest uninterruptible unit — which holds only while a strip is
      // under 500 ms, and it is not. Measured on `nominal` at `high` tier: 2724
      // ms of blending over 8 strips, i.e. ~340 ms per strip on this desktop
      // host, where the whole pipeline runs in 15.6 s against the 60 s S8
      // budgets for the device. That is roughly a 4x factor, which puts a
      // device strip near 1.4 s — over the bound. So the flag is polled per
      // tile as well, taking the uninterruptible unit down to one `feed` of one
      // frame.
      //
      // Polled before the intersection test rather than after, so a strip whose
      // tiles mostly miss it still yields promptly instead of spinning through
      // thirty `continue`s without a check.
      if (cancelled(progress)) {
        error = "cancelled during blending";
        return SV_ERR_CANCELLED;
      }
      // Most frames miss most strips. With 29 frames and 8 strips each strip
      // touches only a handful, and this line is what keeps per-strip work far
      // below n (§5).
      const cv::Rect intersection = tile.rect & work;
      if (intersection.empty()) continue;

      cv::Mat bgr, mask;
      tile.fetch(intersection - tile.rect.tl(), bgr, mask);
      if (bgr.empty() || mask.empty()) continue;
      if (cv::countNonZero(mask) == 0) continue;

      cv::Mat signed16;
      bgr.convertTo(signed16, CV_16S);  // pitfall §9.2
      try {
        blender->feed(signed16, mask, intersection.tl());
      } catch (const cv::Exception& e) {
        error = std::string("blender feed failed: ") + e.what();
        return SV_ERR_INTERNAL;
      }
      ++fed;
    }

    if (fed > 0) {
      cv::Mat blended, blendedMaskPart;
      try {
        blender->blend(blended, blendedMaskPart);
      } catch (const cv::Exception& e) {
        error = std::string("blend failed: ") + e.what();
        return SV_ERR_INTERNAL;
      }
      // The kept rows of the strip, and only the kept columns of those. Both
      // discards happen here: the vertical pad that made the strip exact, and
      // §2's horizontal wrap pad that made the meridian continuous.
      const cv::Rect keptInStrip = keep & crop;
      if (!keptInStrip.empty()) {
        const cv::Rect local(keptInStrip.x - work.x, keptInStrip.y - work.y,
                             keptInStrip.width, keptInStrip.height);
        const cv::Rect inCanvas(keptInStrip.x - crop.x, keptInStrip.y - crop.y,
                                keptInStrip.width, keptInStrip.height);
        cv::Mat destination = canvas(inCanvas);
        blended(local).convertTo(destination, CV_8U);
        if (blendedMask && !blendedMaskPart.empty()) {
          cv::Mat target = (*blendedMask)(inCanvas);
          cv::max(target, blendedMaskPart(local), target);
        }
      }
    }

    setStage(progress, SV_STAGE_BLENDING, 1000 * (s + 1) / stripsNeeded);
  }
  return SV_OK;
}

int compositePanorama(const std::vector<FrameInput>& frames,
                      const Intrinsics& intrinsics,
                      const RegistrationResult& registration,
                      const CompositingOptions& options,
                      SvProgress* progress,
                      CompositingResult& result,
                      std::string& error) {
  const size_t n = frames.size();
  if (n == 0) {
    error = "nothing to composite";
    return SV_ERR_NO_FRAMES;
  }
  if (registration.rotations.size() != n) {
    error = "registration produced a different number of rotations than frames";
    return SV_ERR_INTERNAL;
  }

  const int width = options.outputWidth;
  const int height = width / 2;
  const int pad = options.wrapPadPx;
  const int paddedWidth = width + 2 * pad;
  const int numBands =
      options.numBands > 0 ? options.numBands : bandsForWidth(width);
  const int stripPad =
      options.stripPadPx > 0 ? options.stripPadPx : stripPadForBands(numBands);

  result.canvasWidth = width;
  result.canvasHeight = height;
  result.paddedCanvasWidth = paddedWidth;
  result.stripPadPx = stripPad;
  result.bandsUsed = numBands;
  // The count the blender will actually use, which is the requested one rounded
  // to the pyramid lattice — and 1 for feather, which cannot be striped.
  {
    const int requested =
        options.blendMode == BlendMode::kMultiBand ? std::max(1, options.stripCount) : 1;
    const int stripHeight = alignedStripHeight(height, requested, numBands);
    result.stripsUsed = (height + stripHeight - 1) / stripHeight;
  }

  const cv::Rect canvasRect(0, 0, paddedWidth, height);
  const cv::Rect cropRect(pad, 0, width, height);

  // Seam scale (§4). Seam paths do not need full resolution, and a graph cut on a
  // full 8192×4096 canvas with 29 overlapping frames would dominate the runtime.
  // Resolved here rather than after the warp because the warp loop now builds the
  // seam-scale copies itself, while each frame is still in RAM.
  const double seamScale =
      std::min(1.0, std::sqrt(options.seamTargetPixels /
                              (static_cast<double>(paddedWidth) * height)));
  result.seamScale = seamScale;

  // ------------------------------------------------------------ stage 10 ----
  auto stageStart = Clock::now();
  setStage(progress, SV_STAGE_WARPING, 0);

  // §1: scale = W/(2π), and the focal comes back from BA in registration-scale
  // pixels (Phase 03 §8.3), so it has to be scaled to full resolution before it
  // is put in K. Forgetting this is invisible until the warp is 40% too small.
  const double warpScale = width / (2.0 * CV_PI);
  const double registrationScale =
      registration.registrationScale > 0 ? registration.registrationScale : 1.0;

  std::vector<SvWarning> undistortNotes;
  // A solved lens takes precedence over "no lens", and is rectified differently —
  // see `buildEstimatedUndistortPlan`. The two are mutually exclusive by
  // construction: the estimator only runs when the device published nothing.
  const bool solvedLens =
      registration.estimatedK1 != 0.0 || registration.estimatedK2 != 0.0;
  const UndistortPlan undistort =
      solvedLens ? buildEstimatedUndistortPlan(intrinsics, registration.estimatedK1,
                                               registration.estimatedK2)
                 : buildUndistortPlan(intrinsics, undistortNotes);

  const std::string workDirectory =
      options.workDir.empty()
          ? directoryOf(options.outputPath) + "/.sv_warp_" + std::to_string(::getpid())
          : options.workDir;
  WarpStore store(workDirectory);

  std::vector<FrameTiles> tiles(n);
  cv::Mat counts = cv::Mat::zeros(height, width, CV_8U);

  for (size_t i = 0; i < n; ++i) {
    if (cancelled(progress)) { error = "cancelled during warping"; return SV_ERR_CANCELLED; }

    cv::Mat source = readCaptureFrame(frames[i].imagePath);
    if (source.empty()) {
      error = "could not read frame for compositing: " + frames[i].imagePath;
      return SV_ERR_IO;
    }
    // The warp below uses `undistort.cx`/`cy` as the principal point — numbers
    // that describe the capture frame — against whatever size this decode
    // happened to return. A rotated or rescaled frame warps through the wrong
    // centre and lands somewhere it was never taken, which is a hole here and a
    // grey patch after the fill. Registration checks this too; both check because
    // either stage can be reached first by a caller and neither should trust the
    // other to have looked.
    if (!frameSizeMatchesIntrinsics(source.size(), intrinsics.width,
                                    intrinsics.height)) {
      error = "frame " + frames[i].imagePath + " decoded as " +
              std::to_string(source.cols) + "x" + std::to_string(source.rows) +
              " but the bundle's intrinsics describe " +
              std::to_string(static_cast<int>(std::lround(intrinsics.width))) +
              "x" +
              std::to_string(static_cast<int>(std::lround(intrinsics.height))) +
              " (a rotated frame, an EXIF orientation applied on decode, or a "
              "capture size that changed under the intrinsics)";
      return SV_ERR_SCHEMA;
    }
    if (undistort.active) {
      cv::Mat rectified;
      cv::remap(source, rectified, undistort.map1, undistort.map2, cv::INTER_LINEAR);
      source = rectified;
    }

    // §1: feather the frame borders. Undistortion and the pinhole model both
    // misbehave at the extreme edge and vignetting is worst there, so the mask
    // is eroded before warping — by a fraction of the frame's smaller
    // dimension, which is exactly what `coverage_validator` shrinks the frame
    // rectangle by before it certifies coverage (Math §8).
    const int inset = static_cast<int>(std::lround(
        std::min(source.cols, source.rows) * options.borderErosionFraction));
    cv::Mat sourceMask = cv::Mat::zeros(source.size(), CV_8U);
    const cv::Rect interior(inset, inset, std::max(1, source.cols - 2 * inset),
                            std::max(1, source.rows - 2 * inset));
    sourceMask(interior & cv::Rect(0, 0, source.cols, source.rows)).setTo(255);

    const double focalRegPx = i < registration.frameFocalRegPx.size()
                                  ? registration.frameFocalRegPx[i]
                                  : registration.refinedFocalRegPx;
    const double focal = focalRegPx / registrationScale;

    cv::Mat k = cv::Mat::eye(3, 3, CV_32F);
    k.at<float>(0, 0) = static_cast<float>(focal);
    k.at<float>(1, 1) = static_cast<float>(focal);
    k.at<float>(0, 2) = static_cast<float>(undistort.cx);
    k.at<float>(1, 2) = static_cast<float>(undistort.cy);

    cv::Mat rotation(3, 3, CV_32F);  // pitfall §8.1: CV_32F, or silent garbage
    for (int a = 0; a < 3; ++a) {
      for (int b = 0; b < 3; ++b) {
        rotation.at<float>(a, b) = static_cast<float>(registration.rotations[i](a, b));
      }
    }

    WarpedFrame warped;
    try {
      warped = warpFrameToEquirect(warpScale, k, rotation, source, sourceMask, width, height);
    } catch (const cv::Exception& e) {
      error = std::string("spherical warp failed: ") + e.what();
      return SV_ERR_INTERNAL;
    }
    const cv::Rect roi = warped.roi;
    cv::Mat warpedImage = warped.image;
    cv::Mat warpedMask = warped.mask;
    source.release();
    sourceMask.release();

    FrameTiles& tile = tiles[i];
    tile.frameIndex = static_cast<int>(i);
    tile.positionIndex = frames[i].positionIndex;
    tile.warpedSize = warpedImage.size();

    // Pitfall §9.4: warpRoi corners are negative. The canvas origin is
    // u = −W/2 (Math §3), and the wrap padding shifts everything right by
    // `pad`.
    const cv::Rect placed(roi.x + width / 2 + pad, roi.y, tile.warpedSize.width,
                          tile.warpedSize.height);
    tile.primary = placed & canvasRect;
    if (tile.primary.empty()) {
      addWarning(result.warnings, SvWarningCode::kFrameWarpedOffCanvas,
                 "A frame warped entirely outside the canvas and contributed "
                 "nothing. That should be impossible for a rotation-only model, so "
                 "treat it as a registration failure rather than a compositing one.");
      continue;
    }
    tile.copies.push_back({tile.primary, tile.primary.tl() - placed.tl()});

    // §2: a frame whose warped ROI reaches a pad is emitted a second time at
    // x ± W, with the same rotation, so both copies carry identical pixels and
    // the gain compensator, the seam finder and the blender all see continuous
    // content across the meridian.
    for (const int shift : {width, -width}) {
      const cv::Rect duplicate = (placed + cv::Point(shift, 0)) & canvasRect;
      if (duplicate.empty()) continue;
      tile.copies.push_back(
          {duplicate, duplicate.tl() - (placed.tl() + cv::Point(shift, 0))});
      ++result.wrapDuplicateTiles;
    }

    // Coverage (S5), counted by folding *every* copy of this frame back into the
    // crop window rather than by reading the primary copy alone.
    //
    // Counting the primary alone leaves a one-pixel column at the meridian
    // reading as uncovered, and that is not a cosmetic reporting error. `u =
    // scale·atan2(x, z)` reaches exactly −W/2 only in the limit, so no frame's
    // ROI quite starts there and crop column 0 gets a count of zero — while the
    // blender, which does see the pad duplicates, has filled it with perfectly
    // good pixels. Stage 14 then reads the zero, decides the column is a hole,
    // and *overwrites real photography with an extrapolation* down the exact
    // meridian the wrap padding exists to make seamless. Measured on `pristine`:
    // 667 pixels, a black-looking scar at x = 0, and the single largest
    // contributor to a failing wrap-seam score.
    //
    // The fold takes the union across copies, not the sum: the copies are the
    // same photograph at the same rotation, so a direction covered by two of them
    // was still photographed once. They do overlap, by a column, whenever a pole
    // frame's ROI comes out W+1 wide.
    {
      int firstRow = height, lastRow = -1;
      for (const FrameTiles::Copy& copy : tile.copies) {
        firstRow = std::min(firstRow, copy.rect.y);
        lastRow = std::max(lastRow, copy.rect.y + copy.rect.height - 1);
      }
      if (lastRow >= firstRow) {
        cv::Mat folded = cv::Mat::zeros(lastRow - firstRow + 1, width, CV_8U);
        for (const FrameTiles::Copy& copy : tile.copies) {
          for (int y = 0; y < copy.rect.height; ++y) {
            const uchar* source = warpedMask.ptr<uchar>(copy.local.y + y) + copy.local.x;
            uchar* target = folded.ptr<uchar>(copy.rect.y + y - firstRow);
            for (int x = 0; x < copy.rect.width; ++x) {
              if (!source[x]) continue;
              int column = (copy.rect.x + x - pad) % width;
              if (column < 0) column += width;
              target[column] = 1;
            }
          }
        }
        cv::Mat band = counts.rowRange(firstRow, lastRow + 1);
        cv::add(band, folded, band);
      }
    }

    // The seam-scale copies, built here from the frame that is already in RAM.
    //
    // The obvious place for this is after the warp loop, reading each frame back
    // out of the store — and that quietly undoes the whole point of the store.
    // §5 keeps the warped frames on disk so that only the rows a strip touches
    // are ever resident; a `cv::resize` over each frame's *full* rectangle
    // touches every page of all of them at once, and the mapping goes fully
    // resident. Measured at `high` tier on `nominal`, that one pass moved peak
    // RSS from 1425 MB to 1973 MB. Doing it here costs nothing, because
    // `warpedImage` has not been released yet.
    const cv::Size smallSize(
        std::max(1, static_cast<int>(std::lround(tile.warpedSize.width * seamScale))),
        std::max(1, static_cast<int>(std::lround(tile.warpedSize.height * seamScale))));
    cv::resize(warpedImage, tile.small, smallSize, 0, 0, cv::INTER_AREA);
    cv::resize(warpedMask, tile.smallMask, smallSize, 0, 0, cv::INTER_NEAREST);

    if (!store.add(static_cast<int>(i), warpedImage, warpedMask, error)) {
      return SV_ERR_IO;
    }
    ++result.framesWarped;

    setStage(progress, SV_STAGE_WARPING, static_cast<int32_t>(1000 * (i + 1) / n));
  }

  if (result.wrapDuplicateTiles == 0) {
    addWarning(result.warnings, SvWarningCode::kWrapPadUnreached,
               "No frame reached either wrap pad, so the ±180° meridian was "
               "composited as an ordinary image border. On a full sphere this cannot "
               "happen; on a partial one it means the panorama simply does not cross "
               "the meridian.");
  }
  result.stageMilliseconds["warp"] = elapsedMs(stageStart);
  result.stagePeakRssMb["warp"] = peakRssMb();

  coverageFractions(counts, result.coverageFraction, result.doubleCoverageFraction);

  auto seamRect = [seamScale](const cv::Rect& r) {
    const int x = static_cast<int>(std::lround(r.x * seamScale));
    const int y = static_cast<int>(std::lround(r.y * seamScale));
    return cv::Rect(x, y, std::max(1, static_cast<int>(std::lround(r.width * seamScale))),
                    std::max(1, static_cast<int>(std::lround(r.height * seamScale))));
  };

  // ------------------------------------------------------------ stage 11 ----
  stageStart = Clock::now();
  if (cancelled(progress)) { error = "cancelled before gain compensation"; return SV_ERR_CANCELLED; }
  setStage(progress, SV_STAGE_COMPENSATING, 0);

  {
    // Blocks, not a single gain per frame. AE is hard-locked at capture, so the
    // residual is vignetting — a smooth radial falloff — which one number per
    // frame cannot model (§3).
    //
    // Fed with the primary copies only, one entry per frame. Feeding the wrap
    // duplicates as well would give one frame two independent gain maps, and
    // the two copies of the meridian would then be corrected differently — the
    // exact discontinuity the padding exists to prevent. The cross-meridian
    // overlap constraints are not lost: a frame straddling the meridian warps
    // to a full-canvas-width ROI (pitfall §9.5) and so overlaps the frames on
    // both sides of it directly.
    std::vector<cv::Point> corners;
    std::vector<cv::UMat> images;
    // The pair form, because BlocksCompensator overrides `feed` and so hides
    // the base-class overload that would have wrapped these for us.
    std::vector<std::pair<cv::UMat, uchar>> masks;
    std::vector<size_t> owner;
    for (size_t i = 0; i < n; ++i) {
      if (tiles[i].copies.empty()) continue;
      cv::UMat image, mask;
      tiles[i].small.copyTo(image);
      tiles[i].smallMask.copyTo(mask);
      corners.push_back(seamRect(tiles[i].primary).tl());
      images.push_back(image);
      masks.emplace_back(mask, 255);
      owner.push_back(i);
    }

    if (images.size() >= 2 && options.compensateExposure) {
      cv::Ptr<cv::detail::BlocksGainCompensator> compensator =
          cv::makePtr<cv::detail::BlocksGainCompensator>(/*bl_width=*/32, /*bl_height=*/32);
      bool compensated = true;
      try {
        compensator->feed(corners, images, masks);
      } catch (const cv::Exception& e) {
        compensated = false;
        addWarning(result.warnings, SvWarningCode::kGainCompensationFailed,
                   std::string("Exposure compensation failed (") + e.what() +
                       "); the panorama is blended without it and any per-frame "
                       "brightness difference will show as banding.");
      }

      std::vector<cv::Mat> gains;
      if (compensated) compensator->getMatGains(gains);
      double lowest = 1e30, highest = 0, widestWithin = 1.0;
      for (size_t g = 0; g < gains.size() && g < owner.size(); ++g) {
        if (gains[g].empty()) continue;
        cv::Mat gain;
        gains[g].convertTo(gain, CV_32F);
        tiles[owner[g]].gain = gain;

        std::vector<float> values(gain.begin<float>(), gain.end<float>());
        std::sort(values.begin(), values.end());
        // The median gain is this frame's exposure correction; the spread
        // inside the map is its vignetting. Conflating the two would blame the
        // camera's AE for the lens's falloff.
        const double median = values[values.size() / 2];
        if (median > 0) {
          lowest = std::min(lowest, median);
          highest = std::max(highest, median);
        }
        if (values.front() > 0) {
          widestWithin = std::max(widestWithin,
                                  static_cast<double>(values.back()) / values.front());
        }
      }
      if (highest > 0 && lowest < 1e29) result.maxGainRatio = highest / lowest;
      result.maxIntraFrameGainRatio = widestWithin;

      // Apply to the seam-scale copies now, so the seam finder cuts through
      // photometrically consistent content; the full-resolution application
      // happens per strip, inside the tile fetch.
      for (size_t i = 0; i < n; ++i) {
        if (tiles[i].gain.empty() || tiles[i].small.empty()) continue;
        applyGainMap(tiles[i].small, tiles[i].gain,
                     cv::Size(tiles[i].small.cols, tiles[i].small.rows), cv::Point(0, 0));
      }
    }
  }

  if (result.maxGainRatio > 1.15) {
    char message[512];
    std::snprintf(message, sizeof(message),
                  "Exposure compensation had to move frames by up to %.2fx "
                  "relative to each other. Above about 1.15 this is not "
                  "vignetting, it is the auto-exposure lock not actually "
                  "holding during capture — a camera problem (Phase 06), not a "
                  "stitching one. The panorama is compensated and should look "
                  "even, but the underlying frames disagree.",
                  result.maxGainRatio);
    Json data = Json::object();
    data.set("max_gain_ratio", Json::number(result.maxGainRatio));
    addWarning(result.warnings, SvWarningCode::kGainRatioTooLarge, message, data);
  }
  result.stageMilliseconds["compensate"] = elapsedMs(stageStart);
  result.stagePeakRssMb["compensate"] = peakRssMb();

  // ------------------------------------------------------------ stage 12 ----
  stageStart = Clock::now();
  if (cancelled(progress)) { error = "cancelled before seam finding"; return SV_ERR_CANCELLED; }
  setStage(progress, SV_STAGE_SEAMING, 0);

  for (size_t i = 0; i < n; ++i) {
    if (!tiles[i].smallMask.empty()) tiles[i].seamMask = tiles[i].smallMask.clone();
  }

  if (options.seamMode == SeamMode::kGraphCut) {
    // Every copy is handed to the finder, including the wrap duplicates, so the
    // cut near the meridian is decided against real neighbours instead of
    // terminating at an image border. Only the PRIMARY copy's mask is kept
    // afterwards, and every duplicate re-reads it at the same local
    // coordinates — which makes the final label field exactly periodic with
    // period W, so column `pad` and column `pad + W` cannot disagree.
    std::vector<cv::UMat> seamImages;
    std::vector<cv::UMat> seamMasks;
    std::vector<cv::Point> seamCorners;
    struct Provenance { size_t frame; bool primary; cv::Rect local; };
    std::vector<Provenance> provenance;

    for (size_t i = 0; i < n; ++i) {
      FrameTiles& tile = tiles[i];
      if (tile.small.empty()) continue;
      const cv::Rect smallBounds(0, 0, tile.small.cols, tile.small.rows);
      for (size_t c = 0; c < tile.copies.size(); ++c) {
        const FrameTiles::Copy& copy = tile.copies[c];
        cv::Rect local(
            static_cast<int>(std::lround(copy.local.x * seamScale)),
            static_cast<int>(std::lround(copy.local.y * seamScale)),
            std::max(1, static_cast<int>(std::lround(copy.rect.width * seamScale))),
            std::max(1, static_cast<int>(std::lround(copy.rect.height * seamScale))));
        local &= smallBounds;
        if (local.empty() || cv::countNonZero(tile.smallMask(local)) == 0) continue;

        cv::Mat asFloat;
        tile.small(local).convertTo(asFloat, CV_32F);  // pitfall §9.1
        cv::UMat image, mask;
        asFloat.copyTo(image);
        tile.smallMask(local).copyTo(mask);
        seamImages.push_back(image);
        seamMasks.push_back(mask);
        seamCorners.push_back(seamRect(copy.rect).tl());
        provenance.push_back({i, c == 0, local});
      }
    }

    if (seamImages.size() >= 2) {
      try {
        cv::Ptr<cv::detail::SeamFinder> finder =
            cv::makePtr<cv::detail::GraphCutSeamFinder>(
                cv::detail::GraphCutSeamFinderBase::COST_COLOR_GRAD);
        // Timed on its own because it is by far the largest part of stage 12,
        // and because the *pairwise* decomposition below trades a little of it
        // for a cancellation bound — a trade that is only defensible while the
        // number it costs is visible in the report.
        const auto findStart = Clock::now();
        const int32_t seamStatus =
            findSeamsPairwise(*finder, seamImages, seamCorners, seamMasks, progress,
                              error, &result.seamPairMaxMs);
        result.stageMilliseconds["seam_find"] = elapsedMs(findStart);
        if (seamStatus != SV_OK) return seamStatus;

        for (size_t t = 0; t < provenance.size(); ++t) {
          if (!provenance[t].primary) continue;  // duplicates inherit, see above
          const size_t frame = provenance[t].frame;
          // The primary copy can be clipped by a row at the bottom of the
          // canvas, so the found mask is pasted back at its own offset rather
          // than assumed to be the whole frame.
          cv::Mat found = cv::Mat::zeros(tiles[frame].smallMask.size(), CV_8U);
          seamMasks[t].getMat(cv::ACCESS_READ).copyTo(found(provenance[t].local));
          // §4: dilate before upscaling, so the blender is given a band to
          // feather across rather than a hard boundary.
          //
          // One seam-scale pixel, and widening it was tried and reverted. The
          // reasoning for widening was sound — a graph cut partitions the overlap
          // exactly, `MultiBandBlender` cross-fades by blurring the *mask* down
          // its pyramid, and one seam-scale pixel is about five full-resolution
          // ones against a coarsest band of eight, so the coarse bands have almost
          // nothing to fade across. Sizing the kernel from `2^numBands` instead
          // moved `pristine`'s seam score from 3.33 to 3.32 and took its wrap seam
          // the wrong way. So the seam score is not being set by how much overlap
          // the blender is given; the changelog's other suspect — the 16-bit
          // pyramid itself — is where to look next.
          cv::dilate(found, tiles[frame].seamMask, cv::Mat());
        }
      } catch (const cv::Exception& e) {
        addWarning(result.warnings, SvWarningCode::kSeamFindingFailed,
                   std::string("Graph-cut seam finding failed (") + e.what() +
                       "); every frame kept its full warped mask and the blender "
                       "feathered across the whole overlap instead. Parallax that the "
                       "seam finder would have routed around will show as ghosting.");
        for (size_t i = 0; i < n; ++i) {
          if (!tiles[i].smallMask.empty()) tiles[i].seamMask = tiles[i].smallMask.clone();
        }
      }
    }
  }
  result.stageMilliseconds["seam"] = elapsedMs(stageStart);
  result.stagePeakRssMb["seam"] = peakRssMb();

  // ------------------------------------------------------------ stage 13 ----
  stageStart = Clock::now();
  setStage(progress, SV_STAGE_BLENDING, 0);

  std::vector<BlendTile> blendTiles;
  for (size_t i = 0; i < n; ++i) {
    FrameTiles& tile = tiles[i];
    for (const FrameTiles::Copy& copy : tile.copies) {
      BlendTile blend;
      blend.rect = copy.rect;
      const int index = static_cast<int>(i);
      const cv::Point local = copy.local;
      const cv::Size warpedSize = tile.warpedSize;
      const cv::Mat gain = tile.gain;
      const cv::Mat seamMask = tile.seamMask;
      blend.fetch = [&store, index, local, warpedSize, gain, seamMask](
                        const cv::Rect& sub, cv::Mat& bgr, cv::Mat& mask) {
        const cv::Rect inFrame(local + sub.tl(), sub.size());
        bgr = store.image(index, inFrame).clone();
        applyGainMap(bgr, gain, warpedSize, inFrame.tl());

        cv::Mat warped = store.mask(index, inFrame);
        if (seamMask.empty()) {
          mask = warped.clone();
        } else {
          upscaleMaskNearest(seamMask, warpedSize, inFrame, mask);
          cv::bitwise_and(mask, warped, mask);
        }
      };
      blendTiles.push_back(blend);
    }
  }

  // §2 step 3 happens *inside* the blend now, not after it. Every strip is
  // blended over the whole padded width — that is what makes the meridian
  // continuous — and then only the kept columns are copied out, so the padded
  // canvas is never materialised. At `high` tier it would be 107 MB, and cropping
  // it afterwards needed the clone as well: 207 MB against a 700 MB budget, for a
  // rectangle whose edges are thrown away.
  //
  // The two copies were identical and blended identically, so the first and last
  // columns of what comes back agree and the wrap is invisible.
  cv::Mat canvas;
  cv::Mat blendedMask;
  const int status = blendTilesInStrips(blendTiles, cv::Size(paddedWidth, height),
                                        cropRect, numBands, options.stripCount, stripPad,
                                        options.blendMode, progress, canvas, &blendedMask,
                                        error);
  if (status != SV_OK) return status;

  if (options.verifyStripEquivalence) {
    // §5 is explicit: assert this, do not just look at it. One integer differs
    // between the two calls; if the outputs differ by more than a rounding
    // step, `stripPad` is too small.
    cv::Mat whole;
    const int wholeStatus =
        blendTilesInStrips(blendTiles, cv::Size(paddedWidth, height), cropRect, numBands,
                           /*stripCount=*/1, stripPad, options.blendMode, progress, whole,
                           nullptr, error);
    if (wholeStatus != SV_OK) return wholeStatus;
    cv::Mat difference;
    cv::absdiff(canvas, whole, difference);
    double maximum = 0;
    cv::minMaxLoc(difference.reshape(1), nullptr, &maximum);
    result.stripVsFullMaxAbsDiff = static_cast<int>(maximum);
    if (maximum > 1) {
      char message[512];
      std::snprintf(message, sizeof(message),
                    "Strip blending differs from a full-canvas blend by up to %d "
                    "levels, which means the %d px strip padding is too small for "
                    "%d bands. The output is not the one a full-canvas blend "
                    "would have produced.",
                    static_cast<int>(maximum), stripPad, numBands);
      Json data = Json::object();
      data.set("levels", Json::integer(static_cast<int64_t>(maximum)));
      data.set("strip_pad_px", Json::integer(stripPad));
      data.set("bands", Json::integer(numBands));
      addWarning(result.warnings, SvWarningCode::kStripBlendMismatch, message, data);
    }
  }
  result.stageMilliseconds["blend"] = elapsedMs(stageStart);
  result.stagePeakRssMb["blend"] = peakRssMb();

  // ------------------------------------------------------------ stage 14 ----
  stageStart = Clock::now();
  if (cancelled(progress)) { error = "cancelled before pole filling"; return SV_ERR_CANCELLED; }
  setStage(progress, SV_STAGE_FILLING_POLES, 0);

  // What stage 14 must not overwrite is *pixels the blender produced*, which is
  // not quite the same set as "pixels a frame covered". The two differ in thin
  // slivers where a seam-scale cut, upscaled with nearest-neighbour, leaves a
  // pixel assigned to no frame: the coverage map calls it covered, the blender
  // gives it no weight and `Blender::blend` writes black. Filling against
  // coverage leaves those black — 0.002% of the sphere, and `partial`'s exit
  // criterion is that there are none.
  //
  // S5 is still measured from `counts`, above and before this: coverage is a
  // statement about how much of the sphere was photographed, and a sliver the
  // blender fumbled was still photographed. The label map marks these -2 along
  // with the poles, so S6 does not score invented pixels either way.
  cv::Mat covered;
  cv::threshold(counts, covered, 0, 255, cv::THRESH_BINARY);
  if (!blendedMask.empty() && blendedMask.size() == covered.size()) {
    cv::bitwise_and(covered, blendedMask, covered);
  }

  // And a third condition the two above still let through: the pixel has to
  // actually have a value.
  //
  // `blendedMask` means "this pixel is in the blend", not "this pixel came out
  // with something in it". MultiBandBlender reconstructs from a Laplacian
  // pyramid, and where the contributing weights are vanishingly thin the
  // reconstruction lands on exactly zero while the mask still claims it — so
  // `covered` certifies a black pixel, stage 14 skips it, and it ships black.
  // That is the ~0.005% the `holes` metric reports, and it is present on
  // `nominal` at 1.000 coverage, so it is not a coverage problem and no amount
  // of shooting fixes it.
  //
  // Treating exact black as uncovered is safe in the direction that matters. A
  // genuinely black *scene* pixel is surrounded by near-black neighbours, so the
  // push-pull fill reproduces near-black and nothing visible changes; a sliver
  // against real content gets the content around it. The metric already draws
  // this exact distinction — it only counts black where the truth has tens of
  // levels to show — which is what says the two cases can be treated alike here.
  //
  // Cleared into `covered` in place, allocating nothing. Both obvious spellings
  // cost a full-canvas temporary: `cv::split` wants three planes (100 MB at
  // 8192x4096, against a 700 MB budget `sparse_plan` already exceeds), and a
  // separate CV_8U mask ANDed in afterwards measured 96 MB of peak RSS on
  // `low_texture` for a buffer whose only job was to be read once. This clears
  // the bit where it already lives.
  for (int y = 0; y < canvas.rows; ++y) {
    const cv::Vec3b* source = canvas.ptr<cv::Vec3b>(y);
    uchar* mask = covered.ptr<uchar>(y);
    for (int x = 0; x < canvas.cols; ++x) {
      if ((source[x][0] | source[x][1] | source[x][2]) == 0) mask[x] = 0;
    }
  }

  cv::Mat labels;
  if (options.emitDebugMaps) {
    labels = cv::Mat(height, width, CV_32S, cv::Scalar::all(-1));
    cv::Mat best = cv::Mat::zeros(height, width, CV_32F);
    for (size_t i = 0; i < n; ++i) {
      // Polled per frame, because this loop runs a `distanceTransform` for each
      // one and there was no poll between "before pole filling" and "before
      // encoding" — a stretch of roughly a second that a cancel could land at
      // the start of and then sit through. §3's budget is 500 ms, and the worst
      // of 50 cancels measured 918-995 ms against a healthy 39-66 ms median:
      // one unlucky arrival time, not a slow pipeline.
      if (cancelled(progress)) { error = "cancelled during label mapping"; return SV_ERR_CANCELLED; }
      FrameTiles& tile = tiles[i];
      if (tile.copies.empty()) continue;
      const cv::Rect inCrop = tile.primary & cropRect;
      if (inCrop.empty()) continue;
      const cv::Rect local(inCrop.tl() - tile.primary.tl() + tile.copies[0].local,
                           inCrop.size());

      cv::Mat mask;
      if (tile.seamMask.empty()) {
        mask = store.mask(static_cast<int>(i), local).clone();
      } else {
        upscaleMaskNearest(tile.seamMask, tile.warpedSize, local, mask);
        cv::bitwise_and(mask, store.mask(static_cast<int>(i), local), mask);
      }

      // Distance to the mask's own edge is the notion of "won this pixel" that
      // works for both modes: with a graph cut the masks barely overlap and it
      // just picks the owner, with a feather it picks the frame whose weight
      // is highest, which is what a feather actually does.
      cv::Mat distance;
      cv::distanceTransform(mask, distance, cv::DIST_L2, 3);
      const cv::Rect target(inCrop.x - pad, inCrop.y, inCrop.width, inCrop.height);
      cv::Mat bestPart = best(target);
      cv::Mat labelPart = labels(target);
      for (int y = 0; y < target.height; ++y) {
        const float* d = distance.ptr<float>(y);
        float* b = bestPart.ptr<float>(y);
        int32_t* l = labelPart.ptr<int32_t>(y);
        for (int x = 0; x < target.width; ++x) {
          if (d[x] > b[x]) {
            b[x] = d[x];
            l[x] = tile.positionIndex;
          }
        }
      }
    }
  }

  // The last poll before the fill, which is the other long unpolled stretch in
  // this stage. After it the panorama is one push-pull pyramid from being
  // finished, and abandoning it there would throw away every stage above.
  if (cancelled(progress)) { error = "cancelled before the gap fill"; return SV_ERR_CANCELLED; }

  if (options.fillPoles) {
    result.poleFilledFraction = fillUncovered(canvas, covered, /*baseWidthLimit=*/2048,
                                              result.warnings);
    if (!labels.empty()) {
      // §4 of the Phase 02 doc: pole-filled pixels are excluded from SSIM, or
      // the fill's smooth blur inflates it. The sentinel is what the harness
      // reads to do that.
      labels.setTo(-2, covered == 0);
    }
  }
  result.stageMilliseconds["poles"] = elapsedMs(stageStart);
  result.stagePeakRssMb["poles"] = peakRssMb();

  // ------------------------------------------------------------ stage 15 ----
  stageStart = Clock::now();
  // The last poll before the pipeline commits. Past this point a cancel is
  // ignored on purpose: the panorama is finished and writing it costs a fraction
  // of a second, so throwing it away to honour a flag would lose 60 seconds of
  // work to save 150 ms.
  if (cancelled(progress)) { error = "cancelled before encoding"; return SV_ERR_CANCELLED; }
  setStage(progress, SV_STAGE_ENCODING, 0);

  const std::string extension = lowerExtension(options.outputPath);
  if (extension == ".svraw") {
    // The harness's lossless path: raw BGR, no encoder. See writeMapFile.
    if (!writeMapFile(options.outputPath, canvas, error)) return SV_ERR_IO;
  } else {
    std::vector<int> params;
    if (extension == ".jpg" || extension == ".jpeg") {
      params = {cv::IMWRITE_JPEG_QUALITY, options.jpegQuality, cv::IMWRITE_JPEG_OPTIMIZE, 1};
    }
    // imwrite *throws* for an extension the build has no encoder for rather than
    // returning false, and this build has JPEG only. Letting that escape kills
    // the host process — which is what it did — so the refusal is caught and
    // turned into the error that says which of the two things went wrong.
    bool written = false;
    try {
      written = cv::imwrite(options.outputPath, canvas, params);
    } catch (const cv::Exception& e) {
      error = "this build cannot encode " +
              (extension.empty() ? std::string("a file with no extension")
                                 : extension) +
              " — it is built with JPEG support only, so ask for .jpg, or for "
              ".svraw to get raw BGR back (" + e.what() + ")";
      return SV_ERR_IO;
    }
    if (!written) {
      error = "could not write the panorama to " + options.outputPath;
      return SV_ERR_IO;
    }
  }
  result.outputPath = options.outputPath;

  if (options.emitPreview && width > options.previewWidth) {
    cv::Mat preview;
    cv::resize(canvas, preview,
               cv::Size(options.previewWidth, options.previewWidth / 2), 0, 0,
               cv::INTER_AREA);
    const std::string previewPath =
        directoryOf(options.outputPath) + "/" + stemOf(options.outputPath) + "_preview.jpg";
    const std::vector<int> previewParams = {cv::IMWRITE_JPEG_QUALITY, 88};
    if (cv::imwrite(previewPath, preview, previewParams)) {
      result.previewPath = previewPath;
    } else {
      addWarning(result.warnings, SvWarningCode::kPreviewNotWritten,
                 "The full panorama was written but the preview could not be; the UI "
                 "will have to wait for the full file.");
    }
  }

  if (options.emitDebugMaps) {
    const std::string base = directoryOf(options.outputPath) + "/" + stemOf(options.outputPath);
    std::string mapError;
    if (writeMapFile(base + "_labels.bin", labels, mapError) &&
        writeMapFile(base + "_counts.bin", counts, mapError)) {
      result.labelMapPath = base + "_labels.bin";
      result.countMapPath = base + "_counts.bin";
    } else {
      addWarning(result.warnings, SvWarningCode::kDebugMapNotWritten, mapError);
    }
  }
  result.stageMilliseconds["encode"] = elapsedMs(stageStart);
  result.stagePeakRssMb["encode"] = peakRssMb();
  setStage(progress, SV_STAGE_ENCODING, 1000);

  return SV_OK;
}

}  // namespace sv
