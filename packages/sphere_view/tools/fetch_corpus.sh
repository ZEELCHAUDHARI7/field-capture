#!/usr/bin/env bash
#
# tools/fetch_corpus.sh — download the real-site capture corpus (Phase 12 §4).
#
# The seven scenes are ~200 MB of JPEG each, so they live outside git and are
# fetched. What IS committed is everything needed to verify and use them: the
# manifest with a SHA-256 per bundle, the per-scene thresholds
# (tools/harness/field_metrics.dart), and the measured baselines
# (phases/baselines/field/). That is the same split Phase 02 made for the
# synthetic fixtures, for the same reason — nobody wants to clone a 2 GB repo —
# with one difference that matters: a synthetic bundle can be regenerated from
# its seed, and a real one cannot. If these files are lost, the only way back is
# another site visit.
#
# Usage:
#   tools/fetch_corpus.sh                 fetch anything missing, verify all
#   tools/fetch_corpus.sh --verify        verify what is present, download nothing
#   tools/fetch_corpus.sh --scene NAME    just one
#
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="phases/corpus/manifest.json"
TARGET="corpus"
VERIFY_ONLY=0
ONLY_SCENE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY_ONLY=1; shift ;;
    --scene)  ONLY_SCENE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 2; }

if [[ ! -f "$MANIFEST" ]]; then
  echo "no manifest at $MANIFEST" >&2
  exit 2
fi

# The base URL is deliberately NOT in the committed manifest: it is
# organisation-specific, and a URL in a public repo is either wrong or a leak.
# Set SPHERE_VIEW_CORPUS_URL, or point it at a local directory or an S3/GCS path
# that `curl` can reach.
BASE="${SPHERE_VIEW_CORPUS_URL:-}"

mkdir -p "$TARGET"
missing=0
verified=0
failed=0

# One line per scene: name, sha256, bytes. Parsed with the JSON tool that is
# always available here rather than jq, which is not.
while IFS=$'\t' read -r name sha bytes; do
  [[ -n "$name" ]] || continue
  if [[ -n "$ONLY_SCENE" && "$name" != "$ONLY_SCENE" ]]; then continue; fi

  archive="$TARGET/$name.tar.gz"
  directory="$TARGET/$name"

  if [[ ! -d "$directory" && ! -f "$archive" ]]; then
    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
      echo "  $name  MISSING"
      missing=$((missing + 1))
      continue
    fi
    if [[ -z "$BASE" ]]; then
      echo "  $name  MISSING — set SPHERE_VIEW_CORPUS_URL to fetch it"
      missing=$((missing + 1))
      continue
    fi
    echo "  $name  fetching ($((bytes / 1048576)) MB)…"
    curl -fSL --retry 3 -o "$archive" "$BASE/$name.tar.gz" || {
      echo "  $name  DOWNLOAD FAILED"
      failed=$((failed + 1))
      continue
    }
  fi

  if [[ -f "$archive" ]]; then
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    if [[ "$actual" != "$sha" ]]; then
      echo "  $name  CHECKSUM MISMATCH"
      echo "      expected $sha"
      echo "      actual   $actual"
      echo "      A corpus bundle that does not match its manifest is not the"
      echo "      capture the baselines were recorded against, so every field"
      echo "      number would be measured on different pixels. Refusing it."
      failed=$((failed + 1))
      continue
    fi
    if [[ ! -d "$directory" ]]; then
      tar -xzf "$archive" -C "$TARGET"
    fi
  fi

  if [[ -d "$directory" ]]; then
    # A bundle is a self-describing directory (architecture §6.6). The one file
    # that must NOT be there is ground_truth.json: a field capture has no
    # answers, and a stray one would put the run on the synthetic metrics path
    # and score it against a reference that does not describe this building.
    if [[ ! -f "$directory/bundle.json" ]]; then
      echo "  $name  INVALID — no bundle.json"
      failed=$((failed + 1))
      continue
    fi
    if [[ -f "$directory/ground_truth.json" ]]; then
      echo "  $name  INVALID — has ground_truth.json; a real capture has none"
      failed=$((failed + 1))
      continue
    fi
    echo "  $name  ok"
    verified=$((verified + 1))
  fi
# `grep` on the tab, not a bare read of the output. `dart run` prints "Running
# build hooks..." to STDOUT on a cold cache, with no newline after it, so the
# first line of a naive read is "Running build hooks...daylight_shell<tab>…" —
# which parses as a scene called "Running build hooks...daylight_shell", reports
# it missing, and would have sent somebody looking for a corrupt manifest. Only
# lines with the expected shape are events.
done < <(dart run tools/corpus_manifest.dart --list < /dev/null 2>/dev/null |
           grep -oE '[a-z0-9_]+'$'\t''[0-9a-f]{64}'$'\t''[0-9]+')

echo
echo "$verified verified, $missing missing, $failed failed"
if [[ "$failed" -gt 0 ]]; then exit 1; fi
if [[ "$missing" -gt 0 ]]; then
  echo "The quality gate reports an absent corpus rather than passing without it."
  echo "docs/FIELD_CORPUS.md says how to capture the missing scenes."
fi
exit 0
