#!/usr/bin/env bash
#
# tools/ci/quality_gate.sh — render every synthetic profile, stitch each one,
# print the metrics table, and fail the build on a regression.
#
# This is what makes "perfect" hold over time rather than being true once
# (PHASE_02 §5). Two things about it are deliberate and easy to get wrong:
#
#   * A profile can report FAIL and the gate still exit 0. The gate compares
#     against phases/baselines/<profile>.json, not against the targets. Several
#     targets are not met yet, so the baselines record where the pipeline
#     actually is; the gate's job is to notice when that moves, not to be red
#     every day about a number we already know.
#
#   * The backend defaults to `native` — the pipeline that ships.
#     It defaulted to `legacy-dart` while Phases 03-05 were being written, which
#     was right then and wrong the moment they landed: the gate went on
#     comparing the control group against itself, so it stayed green while the
#     native registration regressed from 0.30 px to 4.65 px between Phase 03 and
#     Phase 04. A regression detector pointed at code nobody is changing is not
#     a regression detector. Use --backend legacy-dart to re-measure the
#     control group deliberately.
#
#   * Baselines are never updated automatically. Moving one is a deliberate
#     act, in its own commit, with the reason in the commit message. That is
#     the only thing standing between "we improved the stitcher" and "we got
#     used to the number going up".
#
# Usage:
#   tools/ci/quality_gate.sh                       check against the baselines
#   tools/ci/quality_gate.sh --record --note "..."  (re-)record them
#   tools/ci/quality_gate.sh --skip-synth           reuse the bundles on disk
#   tools/ci/quality_gate.sh --backend legacy-dart   the control group
#
set -euo pipefail

cd "$(dirname "$0")/../.."

BUNDLES="build/bundles"
BACKEND="native"
SKIP_SYNTH=0
GATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-synth) SKIP_SYNTH=1; shift ;;
    --bundles)    BUNDLES="$2"; GATE_ARGS+=("--bundles" "$2"); shift 2 ;;
    --backend)    BACKEND="$2"; GATE_ARGS+=("--backend" "$2"); shift 2 ;;
    --help|-h)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)            GATE_ARGS+=("$1"); shift ;;
  esac
done

started=$(date +%s)

if [[ "$SKIP_SYNTH" -eq 0 ]]; then
  echo "== rendering the synthetic capture sets =="
  dart run tools/synth.dart --all --out "$BUNDLES"
else
  echo "== reusing the bundles in $BUNDLES =="
fi

echo
echo "== replaying with backend '$BACKEND' =="
set +e
dart run tools/ci/quality_gate.dart --backend "$BACKEND" ${GATE_ARGS[@]+"${GATE_ARGS[@]}"}
status=$?
set -e

# S10 — the output has to be a photo sphere, not just a good one. Checked with
# a reader that is not ours, because every way the metadata can be wrong
# produces a file our own parser reads back perfectly. Skipped rather than
# failed when exiftool is absent: it is a developer-machine dependency, and a
# gate that cannot run on a laptop is a gate people stop running.
echo
echo "== S10: output metadata =="
if command -v exiftool >/dev/null 2>&1; then
  set +e
  tools/ci/validate_metadata.sh >/tmp/sphere_view_metadata.log 2>&1
  metadata_status=$?
  set -e
  if [[ "$metadata_status" -ne 0 ]]; then
    cat /tmp/sphere_view_metadata.log
    status=1
  else
    grep -E '^(PASS|  --)' /tmp/sphere_view_metadata.log || true
    echo "  (the manual half — Google Photos and Facebook — is still owed"
    echo "   after any change to the packet; exiftool proves the file is"
    echo "   well-formed, only a real viewer proves it is accepted.)"
  fi
else
  echo "  SKIPPED — exiftool is not installed (brew install exiftool)"
fi

elapsed=$(( $(date +%s) - started ))
echo
echo "quality gate finished in ${elapsed}s (budget: 300s)"
if [[ "$elapsed" -gt 300 ]]; then
  echo "WARNING: over the five-minute budget the Phase 02 exit criteria set."
fi

exit "$status"
