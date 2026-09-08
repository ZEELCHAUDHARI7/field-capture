#!/usr/bin/env bash
# Spike A, iOS: build minimal static OpenCV libs for device arm64.
#
#   ./build_ios.sh
#
# ---------------------------------------------------------------------------
# WHY THIS DRIVES CMAKE DIRECTLY (R1 open item 4, now measured)
#
# PHASE_00 asks us to try three approaches in increasing order of effort and
# record which worked. Measured against OpenCV 4.13.0:
#
#   Option 1 — `--without <module>` for each excluded module.
#     Works for module selection, but build_framework.py DISCARDS every extra
#     -D argument. Observed verbatim on stdout:
#       "The following args are not recognized and will not be used:
#        ['-DBUILD_JPEG=ON', '-DWITH_PNG=OFF', '-DCMAKE_CXX_FLAGS=-Os ...', ...]"
#     So option 1 cannot set the codec selection or the -Os/gc-sections flags
#     that the whole size argument rests on. Insufficient on its own.
#
#   Option 2 — patch getCMakeArgs() to pass BUILD_LIST through.
#     Fixes module selection only. The dropped -D problem above is a separate
#     defect in the same script, so option 2 does not fix it either. Also
#     checked: 4.13.0's build_framework.py has NO --cmake_option escape hatch;
#     its entire surface is --without / --disable / a fixed set of flags.
#
#   Option 3 — bypass the script, drive cmake + the shipped iOS toolchain.
#     Chosen. Full control over BUILD_LIST and every flag, and it mirrors
#     build_android.sh exactly, so the two platforms share one mental model
#     instead of two.
#
# The cost of option 3 is that we produce static .a files plus headers rather
# than a packaged .framework. For an FFI plugin that is what we want anyway —
# the .a files get linked into our own shim, exactly as on Android.
# ---------------------------------------------------------------------------

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# build_framework.py needs `cmake` on PATH; so does the Xcode generator. The
# Android SDK's cmake is a stock build and serves for iOS too, so the spike has
# no extra install step.
export PATH="$(dirname "$CMAKE_BIN"):$PATH"

fetch_source
mkdir -p "$OUT/ios"

TOOLCHAIN="$SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneOS_Xcode.cmake"
[ -f "$TOOLCHAIN" ] || die "iOS toolchain not found at $TOOLCHAIN"

# Must be an ENVIRONMENT variable, not just -D. common-ios-toolchain.cmake is
# re-included inside CMake's try_compile sub-project, which does not inherit
# our -D cache entries, and it hard-errors with "IPHONEOS_DEPLOYMENT_TARGET is
# not specified" unless it can fall back to the environment. This is why
# build_framework.py exports it rather than passing it through.
export IPHONEOS_DEPLOYMENT_TARGET=16.0

BUILD="$WORK/ios-arm64"
INSTALL="$WORK/install-ios-arm64"
rm -rf "$BUILD" "$INSTALL" && mkdir -p "$BUILD"

log "opencv=$OPENCV_VERSION toolchain=$(basename "$TOOLCHAIN") jobs=$JOBS"

T0=$(date +%s)
(
  cd "$BUILD"
  cmake "$SRC" \
    -GXcode \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DIOS_ARCH=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DIPHONEOS_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DAPPLE_FRAMEWORK=OFF \
    -DCMAKE_C_FLAGS="$SIZE_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$SIZE_CFLAGS" \
    -DWITH_AVFOUNDATION=OFF \
    -DWITH_CAP_IOS=OFF \
    "${COMMON_CMAKE_ARGS[@]}" \
    > "$BUILD/cmake-configure.log" 2>&1 \
    || { tail -50 "$BUILD/cmake-configure.log"; die "iOS configure failed"; }

  grep -m1 -A4 "To be built" "$BUILD/cmake-configure.log" \
    | tee "$OUT/ios/modules-built.txt" || true

  cmake --build . --config Release --target install -- -jobs "$JOBS" \
    > "$BUILD/build.log" 2>&1 \
    || { tail -60 "$BUILD/build.log"; die "iOS build failed"; }
)
SECS=$(( $(date +%s) - T0 ))
log "iOS static libs built in ${SECS}s"

find "$INSTALL" -name "libopencv_*.a" -exec ls -l {} \; 2>/dev/null \
  | awk '{printf "%-56s %8.2f MB\n", $NF, $5/1048576}' \
  | sort | tee "$OUT/ios/staticlibs.txt"

echo "ios_arm64 build_secs=$SECS" >> "$OUT/ios/build-times.txt"
log "done. run ./measure_ios_link.sh for the post-link, post-strip delta"
