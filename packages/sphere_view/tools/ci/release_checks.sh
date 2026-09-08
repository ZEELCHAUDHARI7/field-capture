#!/usr/bin/env bash
#
# tools/ci/release_checks.sh — Phase 13 §4's test list, as one command.
#
# Separate from `quality_gate.sh`, which judges the *stitcher* against measured
# baselines and takes a couple of minutes of native work. This one judges the
# *package*: does it analyse, does it document, does anything private leak into
# the public API, do the docs still compile. All of it is fast and none of it
# needs a device or the native library.
#
#   tools/ci/release_checks.sh
#
# Exits non-zero on the first failure, and says which one.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"

log()  { printf '\033[36m[release]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[release] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------- platform threads ----

# First, because it is the fastest and because it is the only check here that
# guards a *runtime* crash rather than a compile-time or documentation defect.
# Two shipped bugs — the camera texture and the pose stream — reached Flutter
# from a worker thread with the entire suite green. Nothing else in this file,
# or in the 520 Dart tests, can see that.
log "platform-thread affinity in native code"
"$ROOT/tools/ci/platform_thread_check.sh" || fail "native code reaches Flutter off the platform thread"

# --------------------------------------------------------------- analyze -----

log "flutter analyze (package)"
flutter analyze > "$ROOT/build/release-analyze.log" 2>&1 \
  || { tail -30 "$ROOT/build/release-analyze.log"; fail "the package does not analyze clean"; }

log "flutter analyze (example)"
(cd example && flutter analyze) > "$ROOT/build/release-analyze-example.log" 2>&1 \
  || { tail -30 "$ROOT/build/release-analyze-example.log"; fail "the example does not analyze clean"; }

# ------------------------------------------------------------------ docs -----

# `dart doc` is checked by grepping its own summary rather than by its exit
# code, because it exits 0 with warnings. Phase 13 §2 asks for *zero* warnings,
# and "the command succeeded" is not that.
log "dart doc"
DOC_LOG="$ROOT/build/release-dartdoc.log"
dart doc --output "$ROOT/build/doc" > "$DOC_LOG" 2>&1 || { tail -30 "$DOC_LOG"; fail "dart doc errored"; }
grep -q "Found 0 warnings and 0 errors" "$DOC_LOG" \
  || { grep -E "warning|error" "$DOC_LOG" | head -30; fail "dart doc is not clean"; }

# ------------------------------------------------------------------ tests ----

# The three suites that are statements about the *package* rather than about
# the pipeline: no `src/` type in a public signature, the README's snippets
# still compile, and `docs/INTEGRATION.md`'s do too. A snippet in the
# integration guide that no longer compiles is worse than a missing one — the
# reader copies it, it fails, and the natural conclusion is that the package is
# broken rather than that the document is stale.
log "public API audit, README and INTEGRATION snippets"
flutter test \
  test/public_api_test.dart \
  test/readme_snippet_test.dart \
  test/integration_doc_test.dart \
  > "$ROOT/build/release-tests.log" 2>&1 \
  || { tail -40 "$ROOT/build/release-tests.log"; fail "the package-surface tests did not pass"; }

# ----------------------------------------------------------------- demo ------

log "the example demo's own tests"
(cd example && flutter test) > "$ROOT/build/release-example-tests.log" 2>&1 \
  || { tail -40 "$ROOT/build/release-example-tests.log"; fail "the demo's tests did not pass"; }

log "all release checks passed"
