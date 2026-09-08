#!/usr/bin/env bash
#
# tools/build_native_mobile.sh — build the native stitch pipeline for Android
# and iOS from a clean checkout.
#
# Phase 13 §2: the OpenCV step must be reproducible by somebody who is not the
# person who wrote it, from a clean checkout, **by scripted steps only**. So
# this is the whole procedure. There is no companion list of things to do by
# hand, and `docs/BUILDING_NATIVE.md` describes what this does rather than
# telling you to do it yourself.
#
#   tools/build_native_mobile.sh                both platforms
#   tools/build_native_mobile.sh --android      Android only
#   tools/build_native_mobile.sh --ios          iOS only
#   tools/build_native_mobile.sh --clean        drop the sphere_stitch builds
#   tools/build_native_mobile.sh --clean-all    drop the OpenCV builds too
#
# What it produces, and what consumes it:
#
#   build/opencv-android/<abi>/       OpenCV static libs   ← android/CMakeLists.txt
#   build/opencv-ios/<sdk>-<arch>/    OpenCV static libs   ← this script, step 2
#   ios/Frameworks/sphere_stitch.xcframework   ← ios/sphere_view.podspec
#
# Android is deliberately *not* linked here. Gradle's `externalNativeBuild`
# compiles `src/sphere_stitch` per ABI as part of `flutter build apk`, which
# means the .so in the APK is always built from the sources in the tree rather
# than from whatever this script last left in a directory. What Gradle cannot
# do in reasonable time is build OpenCV, so that is what this script leaves
# behind for it.
#
# The OpenCV builds are slow (~10–20 min per ABI on 10 cores) and cached: a
# rerun with the install tree present skips straight past them.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# The module list, the size flags and the exclusions live in ONE place — Spike
# A's config.sh, pinned against the R1 findings — so the device build cannot
# drift from the desktop build that every quality number was measured on.
# shellcheck source=/dev/null
source "$ROOT/spikes/spike_a_opencv/config.sh"

DO_ANDROID=1
DO_IOS=1
CLEAN=0
CLEAN_ALL=0
for arg in "$@"; do
  case "$arg" in
    --android)   DO_IOS=0 ;;
    --ios)       DO_ANDROID=0 ;;
    --clean)     CLEAN=1 ;;
    --clean-all) CLEAN=1; CLEAN_ALL=1 ;;
    --help|-h)   sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# arm64 only by default. R1's own recommendation, and armeabi-v7a is a 32-bit
# ABI on a package whose peak RSS budget is 700 MB.
MOBILE_ABIS="${MOBILE_ABIS:-arm64-v8a}"

# One entry per (SDK, architecture). Three of them, and each one is load-bearing:
#
#   * the device slice, which is the only one that ever ships;
#   * an **arm64 and x86_64** simulator slice, fat, in one library. Xcode builds
#     the simulator for both architectures unless told otherwise, and CocoaPods'
#     slice selection requires a slice carrying *every* architecture in `ARCHS`.
#     An arm64-only simulator slice therefore matches nothing, copies nothing,
#     and fails at link with `Library 'sphere_stitch_merged' not found` — which
#     reads as a missing file rather than as a missing architecture. Measured,
#     on an Apple Silicon machine, which is exactly where you would expect
#     arm64-only to be enough.
IOS_TARGETS="${IOS_TARGETS:-iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-14.0}"

OPENCV_ANDROID_ROOT="$ROOT/build/opencv-android"
OPENCV_IOS_ROOT="$ROOT/build/opencv-ios"
STITCH_IOS_ROOT="$ROOT/build/sphere-stitch-ios"
XCFRAMEWORK="$ROOT/ios/Frameworks/sphere_stitch.xcframework"

[ "$CLEAN_ALL" -eq 1 ] && { log "removing $OPENCV_ANDROID_ROOT $OPENCV_IOS_ROOT"; rm -rf "$OPENCV_ANDROID_ROOT" "$OPENCV_IOS_ROOT"; }
[ "$CLEAN" -eq 1 ] && { log "removing $STITCH_IOS_ROOT $XCFRAMEWORK"; rm -rf "$STITCH_IOS_ROOT" "$XCFRAMEWORK"; }

# ============================================================ Android =========

build_opencv_android() {
  local abi="$1"
  local install="$OPENCV_ANDROID_ROOT/$abi"
  local work="$ROOT/build/opencv-android-work/$abi"

  if [ -d "$install/sdk/native/jni" ]; then
    log "OpenCV $OPENCV_VERSION for $abi already installed — skipping"
    return
  fi

  fetch_source
  log "configuring OpenCV $OPENCV_VERSION for $abi (modules: $MODULES)"
  mkdir -p "$work"
  "$CMAKE_BIN" -S "$SRC" -B "$work" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_STL=c++_static \
    -DCMAKE_C_FLAGS="$SIZE_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$SIZE_CFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$install" \
    -DBUILD_ANDROID_PROJECTS=OFF \
    -DBUILD_ANDROID_EXAMPLES=OFF \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    > "$work/configure.log" 2>&1 \
    || { tail -40 "$work/configure.log"; die "OpenCV configure failed for $abi (see $work/configure.log)"; }

  log "building OpenCV for $abi (this is the slow part; ~10-20 min)"
  "$CMAKE_BIN" --build "$work" --parallel "$JOBS" --target install \
    > "$work/build.log" 2>&1 \
    || { tail -60 "$work/build.log"; die "OpenCV build failed for $abi (see $work/build.log)"; }

  [ -d "$install/sdk/native/jni" ] || die "OpenCV installed to an unexpected layout in $install"
  log "OpenCV for $abi installed to $install"
}

if [ "$DO_ANDROID" -eq 1 ]; then
  [ -d "$NDK_ROOT" ] || die "NDK not found at $NDK_ROOT. Install it with: sdkmanager 'ndk;$NDK_VERSION'"
  [ -n "$CMAKE_BIN" ] && [ -x "$CMAKE_BIN" ] || die "no cmake found under $ANDROID_SDK/cmake"
  log "android: ndk=$NDK_VERSION abis='$MOBILE_ABIS'"
  for abi in $MOBILE_ABIS; do
    build_opencv_android "$abi"
  done
  log "android done — 'flutter build apk' now compiles src/sphere_stitch for each ABI"
fi

# ============================================================ iOS =============

build_opencv_ios() {
  local sdk="$1" arch="$2"
  local install="$OPENCV_IOS_ROOT/$sdk-$arch"
  local work="$ROOT/build/opencv-ios-work/$sdk-$arch"

  if [ -f "$install/lib/libopencv_stitching.a" ]; then
    log "OpenCV $OPENCV_VERSION for $sdk/$arch already installed — skipping"
    return
  fi

  fetch_source
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  log "configuring OpenCV $OPENCV_VERSION for $sdk/$arch"
  mkdir -p "$work"
  # Plain cross-compilation rather than OpenCV's own `platforms/ios` build
  # script. That script insists on producing a framework, builds every ABI it
  # knows about, and applies its own module list — all three of which are
  # things this project has already decided differently, and the last one would
  # quietly undo R1's exclusions.
  "$CMAKE_BIN" -S "$SRC" -B "$work" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_C_FLAGS="$SIZE_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$SIZE_CFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$install" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DINSTALL_CREATE_DISTRIB=OFF \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    > "$work/configure.log" 2>&1 \
    || { tail -40 "$work/configure.log"; die "OpenCV configure failed for $sdk/$arch (see $work/configure.log)"; }

  log "building OpenCV for $sdk/$arch (this is the slow part; ~10-20 min)"
  "$CMAKE_BIN" --build "$work" --parallel "$JOBS" --target install \
    > "$work/build.log" 2>&1 \
    || { tail -60 "$work/build.log"; die "OpenCV build failed for $sdk/$arch (see $work/build.log)"; }
  log "OpenCV for $sdk/$arch installed to $install"
}

# One archive per (SDK, arch) holding sphere_stitch *and* every OpenCV module it
# uses.
#
# Merged rather than left as a pile of libraries because the podspec has to name
# what it links, and a `vendored_libraries` list that has to stay in step with
# OpenCV's module list is a second place for the module list to live. It also
# makes `-force_load` a single flag: without it the linker drops every one of
# `sv_stitch`'s exported symbols, because nothing in the Swift or Objective-C
# half of the plugin ever calls them — they are reached from Dart, through
# `DynamicLibrary.process()`, which the linker cannot see.
build_stitch_ios() {
  local sdk="$1" arch="$2"
  local opencv="$OPENCV_IOS_ROOT/$sdk-$arch"
  local work="$STITCH_IOS_ROOT/$sdk-$arch"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  log "building sphere_stitch for $sdk/$arch"
  mkdir -p "$work"
  "$CMAKE_BIN" -S "$ROOT/src/sphere_stitch" -B "$work" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSPHERE_STITCH_STATIC=ON \
    -DSPHERE_STITCH_BUILD_TESTS=OFF \
    -DOpenCV_DIR="$opencv/lib/cmake/opencv4" \
    > "$work/configure.log" 2>&1 \
    || { tail -40 "$work/configure.log"; die "sphere_stitch configure failed for $sdk/$arch"; }

  "$CMAKE_BIN" --build "$work" --parallel "$JOBS" \
    > "$work/build.log" 2>&1 \
    || { tail -60 "$work/build.log"; die "sphere_stitch build failed for $sdk/$arch"; }

  local merged="$work/libsphere_stitch_merged.a"
  rm -f "$merged"
  # `libtool -static` rather than `ar`: it is the only one of the two that
  # understands Apple archives with the same member name in two inputs, which
  # OpenCV's third-party libraries reliably contain.
  xcrun libtool -static -o "$merged" \
    "$work/libsphere_stitch.a" \
    "$opencv"/lib/*.a \
    "$opencv"/lib/opencv4/3rdparty/*.a \
    2> "$work/libtool.log" \
    || { cat "$work/libtool.log"; die "merging the archives failed for $sdk/$arch"; }
  log "$sdk/$arch: $(du -h "$merged" | cut -f1) merged archive"
}

if [ "$DO_IOS" -eq 1 ]; then
  command -v xcrun >/dev/null || die "xcrun not found; install Xcode and its command line tools"
  log "ios: targets='$IOS_TARGETS' deployment target=$IOS_DEPLOYMENT_TARGET"

  SIM_ARCHIVES=()
  DEVICE_ARCHIVE=""
  for target in $IOS_TARGETS; do
    sdk="${target%%:*}"
    arch="${target##*:}"
    build_opencv_ios "$sdk" "$arch"
    build_stitch_ios "$sdk" "$arch"
    archive="$STITCH_IOS_ROOT/$sdk-$arch/libsphere_stitch_merged.a"
    if [ "$sdk" = "iphonesimulator" ]; then
      SIM_ARCHIVES+=("$archive")
    else
      DEVICE_ARCHIVE="$archive"
    fi
  done

  # The simulator architectures go into ONE fat archive, not into two slices.
  # An xcframework may hold at most one library per (platform, variant), and
  # CocoaPods only selects a slice that carries every architecture in `ARCHS`.
  FAT_SIM="$STITCH_IOS_ROOT/simulator-fat/libsphere_stitch_merged.a"
  if [ "${#SIM_ARCHIVES[@]}" -gt 0 ]; then
    mkdir -p "$(dirname "$FAT_SIM")"
    rm -f "$FAT_SIM"
    xcrun lipo -create "${SIM_ARCHIVES[@]}" -output "$FAT_SIM"
    log "simulator: $(xcrun lipo -archs "$FAT_SIM") in one archive"
  fi

  # The header directory has to exist and hold only what the pod should see;
  # `sphere_stitch.h` is the whole C ABI.
  HEADERS="$ROOT/src/sphere_stitch/include"
  mkdir -p "$HEADERS"
  cp "$ROOT/src/sphere_stitch/sphere_stitch.h" "$HEADERS/"

  log "assembling $XCFRAMEWORK"
  rm -rf "$XCFRAMEWORK"
  mkdir -p "$(dirname "$XCFRAMEWORK")"
  XC_ARGS=()
  [ -n "$DEVICE_ARCHIVE" ] && XC_ARGS+=(-library "$DEVICE_ARCHIVE" -headers "$HEADERS")
  [ -f "$FAT_SIM" ] && XC_ARGS+=(-library "$FAT_SIM" -headers "$HEADERS")
  xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$XCFRAMEWORK" \
    > "$ROOT/build/xcframework.log" 2>&1 \
    || { tail -30 "$ROOT/build/xcframework.log"; die "xcodebuild -create-xcframework failed"; }
  log "ios done — $XCFRAMEWORK"
fi

log "all done"
