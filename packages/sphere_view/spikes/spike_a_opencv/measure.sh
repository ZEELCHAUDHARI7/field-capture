#!/usr/bin/env bash
# Spike A measurement pass. Reads whatever build_android.sh / build_ios.sh
# produced in out/ and prints the table that goes into the R1 findings file.
#
# Every number here is measured from a real build artefact. Nothing is inferred
# from NDK version, CMake flags, or documentation.

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

OBJDUMP="$NDK_LLVM_BIN/llvm-objdump"
NM="$NDK_LLVM_BIN/llvm-nm"
READELF="$NDK_LLVM_BIN/llvm-readelf"

printf '\n=== Spike A measurements ===\n'
printf 'opencv %s, ndk %s, cmake %s\n\n' \
  "$OPENCV_VERSION" "$NDK_VERSION" "$("$CMAKE_BIN" --version | head -1)"

# ---------------------------------------------------------------- Android ----

if [ -d "$OUT/android" ]; then
  printf '%-10s %-14s %10s %10s %-10s %s\n' \
    VARIANT ABI STRIPPED UNSTRIPPED ALIGN "16KB?"
  printf '%s\n' "--------------------------------------------------------------------------"
  for so in $(find "$OUT/android" -name 'libsv_spike.so' | sort); do
    variant=$(basename "$(dirname "$(dirname "$so")")")
    abi=$(basename "$(dirname "$so")")
    stripped=$(stat -f%z "$so")
    un="$(dirname "$so")/libsv_spike.unstripped.so"
    unsz=$([ -f "$un" ] && stat -f%z "$un" || echo 0)

    # R1 open item 5: verify on the produced .so, do NOT trust the NDK version.
    # Every PT_LOAD segment must be 2**14 aligned, not just the first.
    aligns=$("$OBJDUMP" -p "$so" | grep -A1 '^    LOAD' \
             | grep -oE 'align 2\*\*[0-9]+' | sort -u | tr '\n' ' ')
    ok=$(echo "$aligns" | grep -qE '^align 2\*\*(1[4-9]|2[0-9]) $' && echo YES || echo "NO <-- BLOCKS PLAY")

    printf '%-10s %-14s %9.2fM %9.2fM %-10s %s\n' \
      "$variant" "$abi" \
      "$(echo "$stripped" | awk '{print $1/1048576}')" \
      "$(echo "$unsz" | awk '{print $1/1048576}')" \
      "$(echo "$aligns" | sed 's/align 2\*\*//;s/ $//')" "$ok"
  done

  printf '\n--- required cv::detail:: classes present (unstripped, post gc-sections) ---\n'
  for so in $(find "$OUT/android" -name 'libsv_spike.unstripped.so' | sort); do
    abi=$(basename "$(dirname "$so")")
    variant=$(basename "$(dirname "$(dirname "$so")")")
    printf '%s/%s: ' "$variant" "$abi"
    found=$("$NM" -C --defined-only "$so" 2>/dev/null | grep -oE \
      'cv::detail::(GraphCutSeamFinder|MultiBandBlender|BundleAdjusterRay|SphericalWarper|BlocksGainCompensator|BestOf2NearestMatcher)' \
      | sort -u | wc -l | tr -d ' ')
    gc=$("$NM" -C "$so" 2>/dev/null | grep -c 'GCGraph' | tr -d ' ')
    printf '%s/6 detail classes, GCGraph refs=%s\n' "$found" "$gc"
  done

  printf '\n--- runtime dependencies (must be system libs only) ---\n'
  for so in $(find "$OUT/android" -name 'libsv_spike.so' | sort | head -1); do
    "$READELF" -d "$so" | grep NEEDED | sed 's/^/  /'
  done

  [ -f "$OUT/android/build-times.txt" ] && {
    printf '\n--- build times ---\n'; sed 's/^/  /' "$OUT/android/build-times.txt"; }
fi

# -------------------------------------------------------------------- iOS ----

if [ -d "$OUT/ios" ]; then
  printf '\n--- iOS ---\n'
  for f in "$OUT"/ios/modules-*.txt; do
    [ -f "$f" ] || continue
    printf '\n%s:\n' "$(basename "$f")"; sed 's/^/  /' "$f"
  done
  for f in "$OUT"/ios/staticlibs-*.txt; do
    [ -f "$f" ] || continue
    printf '\n%s (static archive sizes — NOT the shipped size):\n' "$(basename "$f")"
    sed 's/^/  /' "$f"
  done
  printf '\nNOTE: a static framework'"'"'s on-disk size is meaningless. The shipped\n'
  printf 'number is the post-link, post-strip delta — see measure_ios_link.sh.\n'
fi

printf '\n'
