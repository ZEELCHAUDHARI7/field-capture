#!/usr/bin/env bash
# Spike A, Android: build a minimal static OpenCV, link the probe into one
# shared .so, strip it, and report the size that actually ships.
#
#   ./build_android.sh              # baseline, -Os + gc-sections, no LTO
#   ./build_android.sh --lto        # same plus LTO (R1 open item 6)
#   ABIS=arm64-v8a ./build_android.sh    # single ABI, faster
#
# Output: out/android/<abi>/libsv_spike.so  plus out/android/sizes.txt

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

USE_LTO=0
[ "${1:-}" = "--lto" ] && USE_LTO=1
TAG=$([ $USE_LTO -eq 1 ] && echo "lto" || echo "base")

[ -d "$NDK_ROOT" ] || die "NDK not found at $NDK_ROOT"
[ -x "$CMAKE_BIN" ] || die "cmake not found (looked in $ANDROID_SDK/cmake)"

fetch_source
mkdir -p "$OUT/android"

log "ndk=$NDK_VERSION cmake=$($CMAKE_BIN --version | head -1) jobs=$JOBS lto=$USE_LTO"

for ABI in $ABIS; do
  log "================ $ABI ($TAG) ================"

  BUILD="$WORK/android-$ABI-$TAG"
  INSTALL="$WORK/install-android-$ABI-$TAG"
  rm -rf "$BUILD" && mkdir -p "$BUILD"

  # LTO is driven by explicit flags, NOT by CMAKE_INTERPROCEDURAL_OPTIMIZATION.
  #
  # Measured here: with NDK r28 + CMake 3.22, setting IPO=ON makes CMake emit
  # `-fuse-ld=gold`, and r28 no longer ships the gold linker, so the link dies
  # with "invalid linker name in argument '-fuse-ld=gold'". Passing -flto=thin
  # by hand and pinning lld sidesteps CMake's stale linker assumption.
  #
  # Note: written as a non-empty array because `set -u` treats "${EMPTY[@]}"
  # as an unbound variable on bash 3.2, which is what ships with macOS.
  if [ $USE_LTO -eq 1 ]; then
    CFLAGS_THIS="$SIZE_CFLAGS -flto=thin"
    LTO_ARGS=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
              -DCMAKE_SHARED_LINKER_FLAGS="-flto=thin -fuse-ld=lld"
              -DCMAKE_EXE_LINKER_FLAGS="-flto=thin -fuse-ld=lld")
  else
    CFLAGS_THIS="$SIZE_CFLAGS"
    LTO_ARGS=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF)
  fi

  # ---- 1. OpenCV static libs ------------------------------------------------
  T0=$(date +%s)
  (
    cd "$BUILD"
    "$CMAKE_BIN" "$SRC" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$ABI" \
      -DANDROID_PLATFORM="android-$API_LEVEL" \
      -DANDROID_STL=c++_static \
      -DCMAKE_C_FLAGS="$CFLAGS_THIS" \
      -DCMAKE_CXX_FLAGS="$CFLAGS_THIS" \
      -DCMAKE_INSTALL_PREFIX="$INSTALL" \
      -DBUILD_ANDROID_PROJECTS=OFF \
      -DBUILD_ANDROID_EXAMPLES=OFF \
      "${COMMON_CMAKE_ARGS[@]}" \
      "${LTO_ARGS[@]}" \
      > "$BUILD/cmake-configure.log" 2>&1 \
      || { tail -40 "$BUILD/cmake-configure.log"; die "configure failed for $ABI"; }

    # Record which modules CMake actually decided to build — the authoritative
    # answer to "did BUILD_LIST pull in what we expected", including transitive
    # deps we did not name.
    grep -A4 "To be built" "$BUILD/cmake-configure.log" | head -8 \
      > "$BUILD/modules-built.txt" || true

    make -j"$JOBS" > "$BUILD/make.log" 2>&1 \
      || { tail -60 "$BUILD/make.log"; die "opencv build failed for $ABI"; }
    make install > "$BUILD/install.log" 2>&1 || die "opencv install failed for $ABI"
  )
  OPENCV_SECS=$(( $(date +%s) - T0 ))
  log "opencv built in ${OPENCV_SECS}s"
  cat "$BUILD/modules-built.txt" 2>/dev/null || true

  # ---- 2. link the probe into one .so ---------------------------------------
  # Mirrors how the real plugin will ship: OpenCV static, our shim shared, one
  # .so per ABI, --gc-sections to drop everything the probe does not reach.
  PBUILD="$WORK/probe-android-$ABI-$TAG"
  rm -rf "$PBUILD" && mkdir -p "$PBUILD"
  cat > "$PBUILD/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.18)
project(sv_spike CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(OpenCV REQUIRED)
add_library(sv_spike SHARED ${PROBE_SRC})
target_link_libraries(sv_spike PRIVATE ${OpenCV_LIBS} log)
target_link_options(sv_spike PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    # R1: mandatory for Google Play as of 2025. NDK r28 does this by default;
    # set it explicitly so the build is correct on r27 too, and so measure.sh
    # is verifying an intent rather than a happy accident.
    -Wl,-z,max-page-size=16384
    -Wl,-z,common-page-size=16384)
CMAKE

  (
    cd "$PBUILD"
    "$CMAKE_BIN" . \
      -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$ABI" \
      -DANDROID_PLATFORM="android-$API_LEVEL" \
      -DANDROID_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS="$CFLAGS_THIS" \
      -DOpenCV_DIR="$INSTALL/sdk/native/jni" \
      -DPROBE_SRC="$SPIKE_DIR/probe/sv_spike_probe.cpp" \
      "${LTO_ARGS[@]}" \
      > "$PBUILD/cmake.log" 2>&1 \
      || { tail -40 "$PBUILD/cmake.log"; die "probe configure failed for $ABI"; }
    make -j"$JOBS" > "$PBUILD/make.log" 2>&1 \
      || { tail -60 "$PBUILD/make.log"; die "probe link failed for $ABI"; }
  )

  DEST="$OUT/android/$TAG/$ABI"
  mkdir -p "$DEST"
  UNSTRIPPED="$PBUILD/libsv_spike.so"
  [ -f "$UNSTRIPPED" ] || UNSTRIPPED=$(find "$PBUILD" -name 'libsv_spike.so' | head -1)
  cp "$UNSTRIPPED" "$DEST/libsv_spike.unstripped.so"
  "$NDK_LLVM_BIN/llvm-strip" --strip-unneeded \
    -o "$DEST/libsv_spike.so" "$DEST/libsv_spike.unstripped.so"

  log "$ABI: $(du -h "$DEST/libsv_spike.so" | cut -f1) stripped"
  echo "$ABI $TAG opencv_build_secs=$OPENCV_SECS" >> "$OUT/android/build-times.txt"
done

log "done. now run ./measure.sh"
