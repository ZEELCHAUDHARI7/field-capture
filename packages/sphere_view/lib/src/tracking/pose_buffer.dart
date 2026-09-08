import 'package:vector_math/vector_math_64.dart';

import '../api/models/device_pose.dart';
import '../utils/quaternion_utils.dart';

/// A short history of poses that can be interpolated to an arbitrary instant.
///
/// This tiny class is the reason the whole pose path is worth building. The
/// sensor samples at ~100 Hz on its own schedule and the shutter fires on the
/// camera's; pairing a frame with the *nearest* pose is therefore wrong by up
/// to 5 ms even in the best case, and by far more once the burst pipeline adds
/// its own latency. At a realistic 60°/s pan that is 1–2° of error — larger
/// than everything bundle adjustment is trying to fix. Buffering and SLERPing
/// to the exact shutter timestamp removes the error instead of budgeting for
/// it.
///
/// Two rules make it safe rather than merely convenient:
///
/// * **[at] returns `null` outside the buffered window.** Extrapolating past
///   the ends is exactly the guess this class exists to avoid, and a stale pose
///   is worse than no pose because it looks like a good one. A caller that gets
///   `null` rejects the frame.
/// * **SLERP, never Euler.** Euler interpolation is wrong near the poles, which
///   is exactly where the zenith shots live (§3). [QuaternionUtils.slerp]
///   negates one input when the dot product is negative, which is the fix for
///   §6 pitfall 4 — `q` and `−q` are the same rotation, and interpolating the
///   long way round is a 360° spin between two samples 10 ms apart.
class PoseBuffer {
  /// Creates a buffer holding [capacity] samples — about 4 s at 100 Hz, which
  /// comfortably covers the worst observed shutter latency.
  PoseBuffer({this.capacity = 400})
    : assert(capacity >= 2, 'interpolation needs at least two samples');

  /// Maximum number of samples retained.
  final int capacity;

  /// The ring. `_samples[_start]` is the oldest, and indices advance modulo
  /// [capacity]. A ring rather than a `List` with `removeAt(0)`, because this
  /// runs 100 times a second for the length of a site walk and `removeAt(0)`
  /// is `O(n)` every time.
  late final List<DevicePose?> _samples = List<DevicePose?>.filled(
    capacity,
    null,
  );
  int _start = 0;
  int _length = 0;

  /// How many samples arrived out of order and were dropped.
  ///
  /// Counted rather than tolerated. A single sensor delivers monotonically, so
  /// a non-zero count here means the samples are being merged from more than
  /// one source or a clock has stepped — either of which makes every
  /// interpolation in the session suspect, and neither of which should be
  /// discovered by squinting at a panorama.
  int get outOfOrderCount => _outOfOrder;
  int _outOfOrder = 0;

  /// Number of samples currently buffered.
  int get length => _length;

  /// Whether anything has been buffered.
  bool get isEmpty => _length == 0;

  /// The oldest buffered sample, or `null` when empty.
  DevicePose? get oldest => _length == 0 ? null : _samples[_start];

  /// The most recent sample, or `null` if nothing has been added.
  DevicePose? get latest =>
      _length == 0 ? null : _samples[(_start + _length - 1) % capacity];

  /// The interval [at] can answer for, or `null` when fewer than one sample is
  /// buffered.
  ({int fromUs, int toUs})? get window =>
      _length == 0 ? null : (fromUs: oldest!.timestampUs, toUs: latest!.timestampUs);

  /// Appends [pose], evicting the oldest sample when full.
  ///
  /// A sample whose timestamp is not strictly newer than the last is dropped
  /// and counted in [outOfOrderCount]: admitting it would break the ordering
  /// [at]'s binary search depends on, and silently sorting it in would hide a
  /// clock fault that matters far more than the one sample.
  void add(DevicePose pose) {
    final last = latest;
    if (last != null && pose.timestampUs <= last.timestampUs) {
      _outOfOrder++;
      return;
    }
    if (_length < capacity) {
      _samples[(_start + _length) % capacity] = pose;
      _length++;
    } else {
      _samples[_start] = pose;
      _start = (_start + 1) % capacity;
    }
  }

  /// SLERPs between the two samples bracketing [timestampUs].
  ///
  /// Returns `null` when the timestamp falls outside the buffered window,
  /// because extrapolating past the ends is exactly the guess this class exists
  /// to avoid — a caller that gets `null` must reject the frame, not carry on.
  ///
  /// The returned pose carries [timestampUs] itself, not the timestamp of
  /// either neighbour: it describes the requested instant, and Phase 08 writes
  /// it into the bundle as the pose *of that shutter*.
  DevicePose? at(int timestampUs) {
    if (_length == 0) return null;
    final first = _samples[_start]!;
    final last = _samples[(_start + _length - 1) % capacity]!;
    if (timestampUs < first.timestampUs || timestampUs > last.timestampUs) {
      return null;
    }
    if (_length == 1) return first;

    // Largest index whose timestamp is <= the request. The window is bounded
    // above, so `lo` always lands on a real left neighbour.
    var lo = 0;
    var hi = _length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_get(mid).timestampUs <= timestampUs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final before = _get(lo);
    if (before.timestampUs == timestampUs || lo == _length - 1) return before;
    final after = _get(lo + 1);

    final span = after.timestampUs - before.timestampUs;
    final t = (timestampUs - before.timestampUs) / span;
    return interpolate(before, after, t, timestampUs);
  }

  /// Interpolates the whole pose — not only the rotation — between [before] and
  /// [after] at fraction [t], stamping the result [timestampUs].
  ///
  /// Exposed so the interpolation itself can be tested against hand-computed
  /// values without going through the ring (§5).
  ///
  /// `gravityWorld` is interpolated and **renormalised**. It is a direction, and
  /// Math §7 solves for the levelling rotation by comparing it against bundle
  /// adjustment's estimate of up; a vector that drifted off unit length would
  /// weight one frame more than another in that comparison for no physical
  /// reason. In practice the two endpoints are ~0.01° apart, so a linear blend
  /// is indistinguishable from a spherical one and far cheaper.
  static DevicePose interpolate(
    DevicePose before,
    DevicePose after,
    double t,
    int timestampUs,
  ) {
    final up = before.gravityWorld * (1 - t) + after.gravityWorld * t;
    return DevicePose(
      deviceToWorld: QuaternionUtils.slerp(
        before.deviceToWorld,
        after.deviceToWorld,
        t,
      ),
      gravityWorld: up.length2 < 1e-12 ? Vector3(0, 1, 0) : (up..normalize()),
      timestampUs: timestampUs,
      angularSpeedRadPerSec:
          before.angularSpeedRadPerSec * (1 - t) +
          after.angularSpeedRadPerSec * t,
    );
  }

  /// Drops every buffered sample.
  ///
  /// Note §6 pitfall 5: this must **not** be called between capture targets.
  /// Continuous history is what both the interpolation and the steadiness gate
  /// run on, and clearing it mid-session means the first shutter after every
  /// target has nothing to interpolate against. It exists for starting a new
  /// session.
  void clear() {
    _samples.fillRange(0, capacity, null);
    _start = 0;
    _length = 0;
    _outOfOrder = 0;
  }

  DevicePose _get(int index) => _samples[(_start + index) % capacity]!;

  @override
  String toString() {
    final w = window;
    return w == null
        ? 'PoseBuffer(empty, capacity $capacity)'
        : 'PoseBuffer($_length/$capacity, '
              '${((w.toUs - w.fromUs) / 1e6).toStringAsFixed(2)} s)';
  }
}
