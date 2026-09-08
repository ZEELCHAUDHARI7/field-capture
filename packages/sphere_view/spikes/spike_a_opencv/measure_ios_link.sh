#!/usr/bin/env bash
# Spike A, R1 open item 5: the correct iOS size-delta measurement.
#
# A static framework's on-disk size tells you nothing — the linker only pulls in
# object code that is actually referenced, and then dead-strips. R1's stated
# method is an App Thinning Size Report diff, which needs a signed archive and
# therefore a developer account.
#
# This script measures the same quantity WITHOUT signing, by linking the probe
# twice against the real static libs and diffing the stripped Mach-O binaries:
#
#   baseline: a trivial .dylib exporting the same C ABI, no OpenCV
#   loaded:   the real probe, which references every class Phases 03/04/05 use
#
# The difference is the object code OpenCV actually contributes at our call
# sites. It is a lower bound on the IPA delta (the IPA also carries the Swift
# runtime, assets and signatures), and it is the number that actually moves when
# we add or drop a module — which is what the budget decision needs.

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

BUILD_DIR="$WORK/ios-arm64"
INSTALL_OVERRIDE="$WORK/install-ios-arm64"
INSTALL="$INSTALL_OVERRIDE"
[ -n "$INSTALL" ] || die "no iOS install dir; run ./build_ios.sh first"

LIBDIR="$INSTALL/lib"
THIRD="$INSTALL/share/OpenCV/3rdparty/lib"
[ -d "$THIRD" ] || THIRD="$INSTALL/lib/opencv4/3rdparty"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos --find clang++)
STRIP=$(xcrun --sdk iphoneos --find strip)
TMP="$WORK/ios-linkmeasure"
rm -rf "$TMP" && mkdir -p "$TMP"

log "sdk=$SDK"
log "opencv static libs in $LIBDIR"

COMMON=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0
        -std=c++17 -Os -ffunction-sections -fdata-sections
        -dynamiclib -Wl,-dead_strip)

# ---- baseline: same exported ABI, no OpenCV ---------------------------------
cat > "$TMP/baseline.cpp" <<'CPP'
#include <string>
extern "C" const char* sv_spike_opencv_probe() {
  static std::string s = "{}"; return s.c_str();
}
extern "C" const char* sv_spike_opencv_version() {
  static std::string s = "none"; return s.c_str();
}
CPP
"$CLANG" "${COMMON[@]}" "$TMP/baseline.cpp" -o "$TMP/baseline.dylib" \
  || die "baseline link failed"
"$STRIP" -x -S "$TMP/baseline.dylib"

# ---- loaded: the real probe against real OpenCV ------------------------------
# -lz is required: cv::FileStorage's gzip path (gzopen/gzgets/...) is compiled
# into libopencv_core.a even with BUILD_ZLIB=OFF, because BUILD_ZLIB only
# controls whether OpenCV vendors its own copy. Android picked the system
# libz.so up implicitly; on iOS it must be named.
LIBS=()
for m in stitching photo video calib3d features2d flann imgcodecs imgproc core; do
  [ -f "$LIBDIR/libopencv_$m.a" ] && LIBS+=("$LIBDIR/libopencv_$m.a")
done
for extra in "$THIRD"/*.a; do [ -f "$extra" ] && LIBS+=("$extra"); done

"$CLANG" "${COMMON[@]}" \
  -I"$INSTALL/include/opencv4" -I"$INSTALL/include" \
  "$SPIKE_DIR/probe/sv_spike_probe.cpp" \
  "${LIBS[@]}" \
  -framework Foundation -framework Accelerate \
  -lz \
  -o "$TMP/loaded.dylib" > "$TMP/link.log" 2>&1 \
  || { tail -30 "$TMP/link.log"; die "probe link failed"; }
"$STRIP" -x -S "$TMP/loaded.dylib"

B=$(stat -f%z "$TMP/baseline.dylib")
L=$(stat -f%z "$TMP/loaded.dylib")

printf '\n=== iOS post-link, post-strip size delta (arm64) ===\n'
printf '  baseline (no OpenCV) : %8.2f MB\n' "$(echo "$B" | awk '{print $1/1048576}')"
printf '  with OpenCV linked   : %8.2f MB\n' "$(echo "$L" | awk '{print $1/1048576}')"
printf '  OPENCV DELTA         : %8.2f MB\n' \
  "$(echo "$L $B" | awk '{print ($1-$2)/1048576}')"
printf '\n  Lower bound on the installed delta. For the authoritative number,\n'
printf '  archive the app twice and diff App Thinning Size Report.txt.\n\n'

echo "ios_arm64_baseline_bytes=$B" >> "$OUT/ios/link-delta.txt"
echo "ios_arm64_loaded_bytes=$L" >> "$OUT/ios/link-delta.txt"
