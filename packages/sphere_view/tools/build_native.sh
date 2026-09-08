#!/usr/bin/env bash
#
# tools/build_native.sh — build src/sphere_stitch for the HOST (desktop), so
# tools/replay can run the same pipeline the device runs.
#
# PHASE_02 §2 is emphatic that replay must run "the exact same native library"
# as the device: same C++ sources, same OpenCV version, same module list. Only
# the target triple differs. That is why this script builds OpenCV 4.13.0 from
# the source tree Spike A already pinned and downloaded, instead of taking
# Homebrew's — Homebrew currently ships OpenCV 5.0.0, which is a different
# stitching `detail::` API, and it would drag in ~100 formulae (Qt, FFmpeg,
# VTK, Tesseract) that R1 deliberately excluded.
#
# The OpenCV build is slow (~10-20 min on 10 cores) and cached: it is skipped
# entirely once the install tree exists. The sphere_stitch build itself is a
# few seconds, which is the loop that actually matters while iterating.
#
# Usage:
#   tools/build_native.sh              build (OpenCV cached, sphere_stitch fresh)
#   tools/build_native.sh --clean      drop the sphere_stitch build dir first
#   tools/build_native.sh --clean-all  drop the OpenCV install tree too (slow!)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# The module list and the size/correctness flags live in ONE place — Spike A's
# config.sh — so the host build cannot silently drift from what ships.
# shellcheck source=/dev/null
source "$ROOT/spikes/spike_a_opencv/config.sh"

HOST_WORK="$ROOT/build/opencv-host"
HOST_INSTALL="$HOST_WORK/install"
NATIVE_BUILD="$ROOT/build/native"

CLEAN=0
CLEAN_ALL=0
for arg in "$@"; do
  case "$arg" in
    --clean)     CLEAN=1 ;;
    --clean-all) CLEAN=1; CLEAN_ALL=1 ;;
    --help|-h)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[ -n "$CMAKE_BIN" ] && [ -x "$CMAKE_BIN" ] || die "no cmake found (looked in \$ANDROID_SDK/cmake/*/bin)"

log "cmake:  $CMAKE_BIN"
log "jobs:   $JOBS"

[ "$CLEAN_ALL" -eq 1 ] && { log "removing $HOST_WORK"; rm -rf "$HOST_WORK"; }
[ "$CLEAN" -eq 1 ]     && { log "removing $NATIVE_BUILD"; rm -rf "$NATIVE_BUILD"; }

# ------------------------------------------------------------ OpenCV, host ---

if [ -f "$HOST_INSTALL/lib/libopencv_stitching.a" ]; then
  log "OpenCV $OPENCV_VERSION host build already installed — skipping"
else
  fetch_source
  log "configuring OpenCV $OPENCV_VERSION for the host (modules: $MODULES)"
  mkdir -p "$HOST_WORK/build"

  # COMMON_CMAKE_ARGS carries the pinned module list and the exclusions R1
  # settled. The overrides after it are host-specific and win, because for
  # duplicate -D flags cmake takes the last occurrence:
  #   * INSTALL_CREATE_DISTRIB=OFF  — we want a plain prefix layout, not the
  #     per-ABI distrib layout the Android build wants.
  #   * -O2 rather than the shipped -Os: on the desktop this is a measurement
  #     tool, and we would rather it run fast than be small.
  "$CMAKE_BIN" -S "$SRC" -B "$HOST_WORK/build" \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DINSTALL_CREATE_DISTRIB=OFF \
    -DCMAKE_INSTALL_PREFIX="$HOST_INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DCMAKE_C_FLAGS="-O2" \
    -DCMAKE_CXX_FLAGS="-O2" \
    -DOPENCV_GENERATE_PKGCONFIG=ON \
    > "$HOST_WORK/configure.log" 2>&1 \
    || { tail -40 "$HOST_WORK/configure.log"; die "OpenCV configure failed (see $HOST_WORK/configure.log)"; }

  log "building OpenCV (this is the slow part; ~10-20 min)"
  "$CMAKE_BIN" --build "$HOST_WORK/build" --parallel "$JOBS" --target install \
    > "$HOST_WORK/build.log" 2>&1 \
    || { tail -60 "$HOST_WORK/build.log"; die "OpenCV build failed (see $HOST_WORK/build.log)"; }

  log "OpenCV installed to $HOST_INSTALL"
fi

# ------------------------------------------------------- sphere_stitch ------

log "configuring sphere_stitch"
mkdir -p "$NATIVE_BUILD"
CONFIGURE_LOG="$ROOT/build/native-configure.log"
"$CMAKE_BIN" -S "$ROOT/src/sphere_stitch" -B "$NATIVE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOpenCV_DIR="$HOST_INSTALL/lib/cmake/opencv4" \
  -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  > "$CONFIGURE_LOG" 2>&1 \
  || { tail -40 "$CONFIGURE_LOG"; die "sphere_stitch configure failed"; }

log "building sphere_stitch"
"$CMAKE_BIN" --build "$NATIVE_BUILD" --parallel "$JOBS"

log "running the unit tests"
"$NATIVE_BUILD/sphere_stitch_test" || die "sphere_stitch unit tests failed"

lib="$(ls "$NATIVE_BUILD"/libsphere_stitch.* 2>/dev/null | head -1 || true)"
[ -n "$lib" ] || die "build produced no library in $NATIVE_BUILD"
log "built $lib"
