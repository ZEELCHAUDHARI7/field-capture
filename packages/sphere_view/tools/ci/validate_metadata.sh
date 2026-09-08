#!/usr/bin/env bash
#
# tools/ci/validate_metadata.sh — check the output's metadata with a reader
# that is not ours.
#
# This is criterion S10's automated half. The exit criterion is that the file
# opens as an interactive sphere in Google Photos and Facebook, which no CI
# system can check; `exiftool` is the cheap proxy for it, and it is a good one
# because it is a genuinely independent implementation — the round-trip test in
# `test/metadata_test.dart` proves our writer agrees with our reader, and this
# proves our writer agrees with the rest of the world.
#
# The distinction matters more than it sounds. Every way this can fail — a
# segment length off by two, an IFD offset relative to the wrong origin, an
# XMP packet after the tables where readers stop looking — produces a file our
# own parser reads back perfectly.
#
# Usage:
#   tools/ci/validate_metadata.sh              write a sample and validate it
#   tools/ci/validate_metadata.sh path.jpg     validate an existing panorama
#
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v exiftool >/dev/null 2>&1; then
  echo "exiftool is not installed."
  echo "  macOS:  brew install exiftool"
  echo "  Debian: apt-get install libimage-exiftool-perl"
  exit 127
fi

# Sample mode writes a file whose every field is known, so it can be checked
# against exact values. Given an existing panorama, the exact values are not
# knowable — the tier decides the size, and GPS is only present when the host
# app supplied a fix — so those checks become consistency checks instead.
TARGET="${1:-}"
SAMPLE_MODE=0
if [[ -z "$TARGET" ]]; then
  TARGET="build/metadata/sample_pano.jpg"
  SAMPLE_MODE=1
  echo "== writing a sample panorama through the shipping writer =="
  dart run tools/ci/write_sample_panorama.dart "$TARGET"
fi

if [[ ! -f "$TARGET" ]]; then
  echo "FAIL: $TARGET does not exist"
  exit 1
fi

echo
echo "== exiftool sees =="
exiftool -s -G "$TARGET"
echo

failures=0

# Reads one tag. Deliberately `-s3` (value only) so the comparison is exact
# rather than a substring of exiftool's own labelling.
tag() { exiftool -s3 -"$1" "$TARGET" 2>/dev/null || true; }

expect() {
  local name="$1" want="$2" got
  got="$(tag "$name")"
  if [[ "$got" == "$want" ]]; then
    printf '  ok    %-28s %s\n' "$name" "$got"
  else
    printf '  FAIL  %-28s expected %-24s got %s\n' "$name" "$want" "${got:-<missing>}"
    failures=$((failures + 1))
  fi
}

expect_present() {
  local name="$1" got
  got="$(tag "$name")"
  if [[ -n "$got" ]]; then
    printf '  ok    %-28s %s\n' "$name" "$got"
  else
    printf '  FAIL  %-28s missing\n' "$name"
    failures=$((failures + 1))
  fi
}

# A field the capture may honestly not carry: a bundle rendered by the
# synthetic rig has no manufacturer and no wall clock, and a capture with
# neither a plan nor a magnetometer has no heading — §2's third option is to
# omit it rather than write a bearing nobody measured. Required of the sample,
# whose every field we control; reported for anything else.
optional() {
  local name="$1" got
  got="$(tag "$name")"
  if [[ -n "$got" ]]; then
    printf '  ok    %-28s %s\n' "$name" "$got"
  elif [[ $SAMPLE_MODE -eq 1 ]]; then
    printf '  FAIL  %-28s missing\n' "$name"
    failures=$((failures + 1))
  else
    printf '  --    %-28s absent (the capture did not record it)\n' "$name"
  fi
}

# Reports a computed condition rather than a tag lookup.
check() {
  local label="$1" ok="$2" detail="$3"
  if [[ "$ok" == "1" ]]; then
    printf '  ok    %-28s %s\n' "$label" "$detail"
  else
    printf '  FAIL  %-28s %s\n' "$label" "$detail"
    failures=$((failures + 1))
  fi
}

echo "== GPano (Math §5) =="
# The property a viewer keys off before anything else. Without it the file is a
# wide JPEG whatever else is present.
expect ProjectionType     equirectangular
expect UsePanoramaViewer  True

# The dimensions are checked for *consistency* rather than against literals.
# The output size is a device tier (architecture §6.5), so 4096, 6144 and 8192
# are all correct answers; what is never correct is a Full that disagrees with
# a Cropped, or a panorama that is not 2:1.
full_w="$(tag FullPanoWidthPixels)"
full_h="$(tag FullPanoHeightPixels)"
crop_w="$(tag CroppedAreaImageWidthPixels)"
crop_h="$(tag CroppedAreaImageHeightPixels)"


if [[ -z "$full_w" || -z "$full_h" ]]; then
  check "FullPano dimensions" 0 "missing"
else
  check "FullPano dimensions" \
    "$([[ "$full_w" -gt 0 && "$full_h" -gt 0 && $((full_h * 2)) -eq "$full_w" ]] && echo 1 || echo 0)" \
    "${full_w}x${full_h} (must be 2:1 — Math §3)"
  # We always emit the whole sphere, so the cropped area is the full area.
  # A mismatch makes a viewer open showing a slice and pad the rest.
  check "CroppedArea covers it all" \
    "$([[ "$crop_w" == "$full_w" && "$crop_h" == "$full_h" ]] && echo 1 || echo 0)" \
    "${crop_w}x${crop_h}"
fi
expect CroppedAreaLeftPixels        0
expect CroppedAreaTopPixels         0
# Zero because Phase 03 §5 already levelled against measured gravity (Math §7).
# A non-zero value here is a levelling bug, not a metadata one.
expect PosePitchDegrees   0
expect PoseRollDegrees    0
optional PoseHeadingDegrees

echo
echo "== EXIF (Phase 11 §2) =="
# Always written, whatever produced the file.
expect_present Software
expect_present ImageDescription

optional DateTimeOriginal
optional Make
optional Model

# GPS is written "when a fix is available" (§2) — this package holds no
# location permission and the host app supplies it — so its absence is a fact
# about the capture rather than a defect. Required only of the sample, whose
# fix we control.
if [[ $SAMPLE_MODE -eq 1 ]]; then
  expect_present GPSLatitude
  expect_present GPSLongitude
fi

# The heading is likewise optional: §2's third option is to omit it rather than
# write a bearing nobody measured. But if it is there, its reference must be
# true north — both of our sources are already true bearings, so 'M' would tell
# a downstream tool to apply a declination correction that has already been
# applied.
if [[ -n "$(tag GPSImgDirection)" ]]; then
  expect GPSImgDirectionRef "True North"
  heading_xmp="$(tag PoseHeadingDegrees)"
  heading_exif="$(tag GPSImgDirection)"
  # Two representations of one fact in one file. If they can disagree they
  # eventually will, and a viewer reading one while a map tool reads the other
  # would place the same panorama two ways.
  check "heading agrees across XMP/EXIF" \
    "$([[ "${heading_xmp%.*}" == "${heading_exif%.*}" ]] && echo 1 || echo 0)" \
    "XMP $heading_xmp / EXIF $heading_exif"
else
  echo "  --    GPSImgDirection             omitted (no heading source)"
fi

echo
echo "== structure =="
# exiftool warns about anything it finds malformed. A JPEG that decodes but
# carries a bad IFD offset shows up here and nowhere else.
warnings="$(exiftool -warning -a -s3 "$TARGET" 2>/dev/null || true)"
if [[ -n "$warnings" ]]; then
  echo "  FAIL  exiftool reported warnings:"
  echo "$warnings" | sed 's/^/          /'
  failures=$((failures + 1))
else
  echo "  ok    no exiftool warnings"
fi

# The XMP has to come before the image data for readers that stop scanning
# early, and exactly one packet has to be present — duplicates make several
# readers ignore both. `test/metadata_test.dart` asserts the ordering against
# the byte layout; this catches the duplicate case with an outside reader.
xmp_count="$(exiftool -a -s3 -XMP:ProjectionType "$TARGET" 2>/dev/null | grep -c . || true)"
if [[ "$xmp_count" == "1" ]]; then
  echo "  ok    exactly one XMP packet"
else
  echo "  FAIL  found $xmp_count XMP packets; duplicates make readers ignore both"
  failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
  echo "PASS — $TARGET is a valid photo sphere as far as an independent reader is concerned."
  echo
  echo "The manual half of S10 remains: open it once in Google Photos and once"
  echo "in Facebook after any change to the packet. exiftool proves the file is"
  echo "well-formed; only a real viewer proves it is accepted."
  exit 0
fi

echo "FAIL — $failures metadata check(s) failed."
exit 1
