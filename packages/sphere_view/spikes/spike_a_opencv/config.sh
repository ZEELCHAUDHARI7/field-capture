#!/usr/bin/env bash
# Shared configuration for Spike A. Sourced by every build/measure script.
#
# Everything here is pinned deliberately. If you change a pin, re-run
# ./measure.sh and update phases/findings/R1_opencv_distribution.md — the
# numbers in that file are only meaningful against a stated configuration.

set -euo pipefail

# ---------------------------------------------------------------- versions ---

# Pinned to 4.13.0, NOT the newest 4.x (4.14.0 exists as of 2026-08-06).
# Reason: nihui/opencv-mobile only ships patches for 4.13.0, so pinning here
# keeps the "fork opencv-mobile" variant buildable and makes the vanilla-vs-
# mobile size comparison apples-to-apples. Revisit once opencv-mobile tracks
# a newer release.
OPENCV_VERSION="${OPENCV_VERSION:-4.13.0}"

# NDK 28.2 (stable) compiles 16 KB-page-aligned by default. 29.0.13599879 is
# also installed; we pin the older stable one so the alignment check in
# measure.sh is testing the configuration we would actually ship.
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"

# ---------------------------------------------------------------- toolchain --

ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
NDK_ROOT="${NDK_ROOT:-$ANDROID_SDK/ndk/$NDK_VERSION}"
CMAKE_BIN="${CMAKE_BIN:-$(ls -d "$ANDROID_SDK"/cmake/*/bin/cmake 2>/dev/null | tail -1)}"
NDK_HOST_TAG="${NDK_HOST_TAG:-darwin-x86_64}"
NDK_LLVM_BIN="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST_TAG/bin"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# ---------------------------------------------------------------- layout -----

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$SPIKE_DIR/work"
SRC="$WORK/opencv-$OPENCV_VERSION"
OUT="$SPIKE_DIR/out"

# ---------------------------------------------------------------- modules ----

# The target module list from R1 / PHASE_00 Spike A. OpenCV's BUILD_LIST
# resolves hard dependencies transitively, so calib3d/flann would be pulled in
# even if omitted — they are listed explicitly so the intent is readable.
#
#   core        base
#   imgproc     base
#   imgcodecs   JPEG read/write for CaptureBundle frames + the output pano
#   flann       hard dep of features2d matching + calib3d
#   features2d  cv::SIFT
#   calib3d     hard dep of stitching; undistort
#   photo       cv::createMergeMertens, cv::createAlignMTB   (Phase 05)
#   video       cv::findTransformECC                          (Phase 05)
#   stitching   the whole cv::detail:: pipeline               (Phases 03/04)
MODULES="core,imgproc,imgcodecs,flann,features2d,calib3d,photo,video,stitching"

# Android ABIs. armeabi-v7a is measured to answer R1's per-ABI size question,
# but see the findings file: shipping arm64-v8a only is the recommendation.
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"
API_LEVEL="${API_LEVEL:-24}"

# ---------------------------------------------------------------- flags ------

# Size-reduction flags from R1 §4. LTO is OFF by default so the first build
# gives a clean baseline; ./build_android.sh --lto measures the delta.
SIZE_CFLAGS="-Os -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables"

# Deliberately NOT copied from opencv-mobile:
#   ENABLE_FAST_MATH=ON  -- opencv-mobile sets this. We do not. BundleAdjusterRay
#                           runs Levenberg-Marquardt; -ffast-math relaxes IEEE
#                           semantics (NaN/Inf handling, reassociation) in
#                           exactly the code whose convergence S1 (<1.0 px RMS)
#                           depends on. Not worth the few hundred KB.
#   BUILD_WITH_RTTI=OFF  -- opencv-mobile applies a no-rtti patch. See
#                           check_rtti.sh; OpenCV's own Algorithm/Ptr machinery
#                           uses dynamic_cast.
COMMON_CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_LIST="$MODULES"
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTS=OFF
  -DBUILD_PERF_TESTS=OFF
  -DBUILD_EXAMPLES=OFF
  -DBUILD_DOCS=OFF
  -DBUILD_opencv_apps=OFF
  -DBUILD_JAVA=OFF
  -DBUILD_opencv_python2=OFF
  -DBUILD_opencv_python3=OFF
  -DBUILD_opencv_js=OFF
  -DBUILD_opencv_ts=OFF
  -DBUILD_opencv_gapi=OFF
  -DBUILD_opencv_objc=OFF

  # Codecs: JPEG only. We read JPEG frames and write a JPEG pano; nothing in
  # the pipeline touches PNG/TIFF/WEBP/EXR/JP2. PNG is kept off, which also
  # keeps zlib out. BUILD_JPEG=ON vendors libjpeg-turbo rather than depending
  # on a system copy that does not exist on Android/iOS.
  -DBUILD_JPEG=ON
  -DWITH_JPEG=ON
  -DBUILD_PNG=OFF   -DWITH_PNG=OFF
  -DBUILD_ZLIB=OFF
  -DBUILD_TIFF=OFF  -DWITH_TIFF=OFF
  -DBUILD_WEBP=OFF  -DWITH_WEBP=OFF
  -DBUILD_OPENEXR=OFF -DWITH_OPENEXR=OFF
  -DBUILD_OPENJPEG=OFF -DWITH_OPENJPEG=OFF
  -DBUILD_JASPER=OFF -DWITH_JASPER=OFF
  -DWITH_IMGCODEC_HDR=OFF
  -DWITH_IMGCODEC_SUNRASTER=OFF
  -DWITH_IMGCODEC_PXM=OFF
  -DWITH_IMGCODEC_PFM=OFF
  -DWITH_GIF=OFF
  -DWITH_SPNG=OFF
  -DWITH_AVIF=OFF

  # Everything we confirmed excludable in R1 §3.
  -DWITH_PROTOBUF=OFF
  -DWITH_FFMPEG=OFF
  -DWITH_GSTREAMER=OFF
  -DWITH_QUIRC=OFF
  -DWITH_ADE=OFF
  -DWITH_EIGEN=OFF
  -DWITH_CUDA=OFF
  -DWITH_OPENCL=OFF
  -DWITH_IPP=OFF
  -DBUILD_IPP_IW=OFF
  -DWITH_ITT=OFF
  -DBUILD_ITT=OFF
  -DWITH_TBB=OFF
  -DBUILD_TBB=OFF
  -DWITH_HALIDE=OFF
  -DWITH_VULKAN=OFF
  -DWITH_FLATBUFFERS=OFF
  -DWITH_OBSENSOR=OFF
  -DWITH_CAROTENE=OFF
  -DWITH_CPUFEATURES=OFF
  -DCV_TRACE=OFF
  -DENABLE_PRECOMPILED_HEADERS=OFF
  -DOPENCV_GENERATE_PKGCONFIG=OFF
  -DINSTALL_CREATE_DISTRIB=ON
)

# ---------------------------------------------------------------- helpers ----

log() { printf '\033[36m[spike-a]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[spike-a] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

fetch_source() {
  mkdir -p "$WORK"
  if [ ! -d "$SRC" ]; then
    log "downloading opencv $OPENCV_VERSION"
    curl -fL "https://github.com/opencv/opencv/archive/$OPENCV_VERSION.tar.gz" \
      | tar xz -C "$WORK"
  fi
  [ -d "$SRC" ] || die "source not found at $SRC"
}
