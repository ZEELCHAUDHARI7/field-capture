#!/usr/bin/env bash
#
# tools/ci/platform_thread_check.sh — every Flutter call in native code is on
# the platform thread.
#
# This guards the one bug class in this package that no Dart test can see.
# Flutter's `TextureRegistry` and its platform channels are platform-thread-only
# on both platforms, and this plugin runs almost everything on its own workers:
# `sphere-camera-ops`, `sphere-pose-ops`, `sphere-motion`, Core Motion's queue,
# and AVFoundation's session queue. Calling Flutter from any of them is a
# runtime crash on Android and a silent engine race on iOS.
#
# It has already happened twice, and both times the whole suite was green:
#
#   * `createSurfaceTexture()` from `sphere-camera-ops` — "Can't create handler
#     inside thread Thread[sphere-camera-ops,5,main] that has not called
#     Looper.prepare()", surfaced to the user as `open_failed`.
#   * `onPoseSample` from `sphere-motion` — "Methods marked with @UiThread must
#     be executed on the main thread", which killed the process on the first
#     sensor sample after Start. Both platforms carried the same wrong comment
#     claiming the send was thread-safe.
#
# 520 Dart tests, 154 native checks and a green quality gate said nothing about
# either, because thread affinity is invisible to everything that does not run
# on a device. This check runs on a laptop in under a second.
#
#   tools/ci/platform_thread_check.sh
#
# WHAT IT IS AND IS NOT. It is a lexical guard: it finds the call sites and
# requires a hop token on the call line or within the three lines above it. It
# cannot prove the hop is *correct* — only that someone thought about it. That
# is enough to catch the failure that actually occurs, which is a bare call with
# no hop anywhere near it. Keep the sites one-liners or short blocks and it
# stays accurate; if a site grows past that, hoist the hop rather than widening
# the window here.

set -euo pipefail

cd "$(dirname "$0")/../.."

log()  { printf '\033[36m[threads]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[threads] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# Generated Pigeon files are excluded: they are the transport, they are
# rewritten by `pigeon`, and they are not where the decision is made.
FILES=$(find android/src/main/kotlin ios/Classes \
          \( -name '*.kt' -o -name '*.swift' \) \
          ! -name 'Messages.g.kt' ! -name 'Messages.g.swift')

[ -n "$FILES" ] || fail "found no native sources to check — has the layout moved?"

REPORT=$(awk '
  function is_comment(s) { return s ~ /^[[:space:]]*(\/\/|\*|\/\*)/ }
  function has_hop(s) {
    return s ~ /main\.post/ ||
           s ~ /DispatchQueue\.main\.(async|sync)/ ||
           s ~ /onMainThread/ ||
           s ~ /onPlatformThread/
  }
  FNR == 1 { delete w }
  {
    line = $0
    # `textureFrameAvailable` is the documented exception on both platforms —
    # Flutter own camera plugin calls it from the sample-buffer queue, and it
    # is the one texture method specified as safe off the platform thread.
    stripped = line
    gsub(/textureFrameAvailable/, "", stripped)

    is_send    = stripped ~ /[Ff]lutterApi\.on[A-Z]/
    is_texture = stripped ~ /textures\.(register|unregisterTexture|createSurfaceTexture)/

    if ((is_send || is_texture) && !is_comment(line)) {
      ok = has_hop(line)
      for (i = 1; i <= 3 && !ok; i++) if (has_hop(w[FNR - i])) ok = 1
      # `sub` on a copy, not `gensub`: the latter is GNU-only and macOS ships
      # BWK awk, where it is a fatal "calling undefined function" — on the
      # offender path only, so the check would have died exactly when it first
      # had something to say.
      if (!ok) { disp = line; sub(/^[[:space:]]+/, "", disp)
                 printf "%s:%d: %s\n", FILENAME, FNR, disp }
      checked++
    }
    w[FNR] = line
  }
  END { printf "CHECKED %d\n", checked }
' $FILES)

COUNT=$(printf '%s\n' "$REPORT" | awk '/^CHECKED /{print $2}')
OFFENDERS=$(printf '%s\n' "$REPORT" | grep -v '^CHECKED ' || true)

if [ -n "$OFFENDERS" ]; then
  printf '%s\n' "$OFFENDERS" >&2
  fail "the call sites above reach Flutter from a worker thread with no platform-thread hop"
fi

# A guard that silently matches nothing is indistinguishable from a guard that
# found nothing wrong. These are the call sites that exist today; if a refactor
# drops the count, the check has stopped watching the code and says so.
MINIMUM=10
[ "${COUNT:-0}" -ge "$MINIMUM" ] \
  || fail "only $COUNT call sites matched, expected at least $MINIMUM — the patterns have gone stale"

log "$COUNT Flutter call sites in native code, all on the platform thread"
