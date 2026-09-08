import '../api/models/sphere_capture_config.dart';
import 'camera_platform.dart';

/// Runs the metering pre-sweep and holds exposure, white balance and focus
/// still for the whole session.
///
/// Exists to remove a whole failure mode rather than to compensate for one.
/// Architecture §2 defect 5 is that auto-exposure drifts between shots, which
/// shows up as brightness banding per frame even when the geometry is perfect;
/// §8 answers it with "not possible — AE hard-locked", leaving gain
/// compensation only the residual to absorb. That answer is only true if
/// something owns the lock across all ~29 positions, and this is it.
///
/// The pre-sweep exists because locking on the *first* frame would meter the
/// wall the user happens to be facing. A 2 s sweep of the sphere sees the
/// window and the dark corner both, so the single locked value is a compromise
/// the bracket can then work either side of.
///
/// The choice of *which* value to lock — the ~65th percentile of the observed
/// EV distribution, not the mean — is made on the native side, where the
/// per-frame AE results are, and reported back in
/// [MeteringResult.percentile65Ev] alongside [MeteringResult.meanEv] so the
/// decision is visible in the data.
class ExposureController {
  /// Creates a controller over [platform].
  ExposureController(this.platform);

  /// The platform channel that owns the actual camera controls.
  final SphereCameraPlatform platform;

  /// How long to sweep before locking. Long enough to see a window and a dark
  /// corner, short enough not to eat the 90 s capture budget (S7).
  static const Duration meteringSweepDuration = Duration(seconds: 2);

  /// Below this many observations the sweep did not see the sphere, and its
  /// percentile describes one wall rather than the room. At a typical 30 fps
  /// preview a 2 s sweep should deliver ~60 frames; 12 is a floor, not a
  /// target.
  static const int minimumUsefulSamples = 12;

  MeteringResult? _current;

  /// The metering result currently in force, or `null` before [meterAndLock].
  MeteringResult? get current => _current;

  /// Warnings this controller wants surfaced. Empty is the normal case; a
  /// non-empty list must reach the user rather than the log, because every
  /// entry here becomes photometric inconsistency the compositor then has to
  /// absorb (architecture §8).
  List<String> get warnings {
    final r = _current;
    if (r == null) return const [];
    return [
      if (r.lockQuality == ExposureLockQuality.unlocked)
        'exposure, white balance and focus could not be locked; frames will '
            'differ in brightness and colour and the panorama will band',
      if (r.lockQuality == ExposureLockQuality.bestEffort)
        'the platform granted only a best-effort lock and reserves the right '
            'to re-converge; gain compensation has more to absorb than the '
            'design assumes',
      if (!r.pinnedProcessingModes)
        'noise reduction, edge enhancement, tonemap or colour correction could '
            'not be pinned to a fixed mode, so the ISP will vary its own '
            'processing per frame — exactly the inconsistency the AE lock '
            'exists to remove',
      if (!r.aeConverged)
        'auto-exposure had not converged when the sweep ended, so the locked '
            'value is whatever it had reached',
      if (r.sampleCount < minimumUsefulSamples)
        'the metering sweep observed only ${r.sampleCount} frames, so its '
            'exposure distribution describes one direction rather than the '
            'sphere',
      if (r.note != null) r.note!,
    ];
  }

  /// Sweeps for [duration], then hard-locks AE, AWB and AF.
  ///
  /// Returns the lock the platform actually granted; anything short of
  /// [ExposureLockQuality.fullyLocked] shows up in [warnings] rather than
  /// being swallowed.
  Future<MeteringResult> meterAndLock({
    Duration duration = meteringSweepDuration,
  }) async {
    final result = await platform.meterAndLock(duration);
    _current = result;
    return result;
  }

  /// The EV biases to fire at each position under [config].
  ///
  /// Straight from the strategy, with one adjustment: a device whose bracket
  /// mode is [BracketMode.singleShot] cannot deliver more than one exposure,
  /// so asking for three would produce three identical frames and a fusion
  /// stage that fuses nothing. Per R3 and architecture §6.4 that degradation
  /// needs no structural change — `shots` becomes a one-element list — but it
  /// does need to be *decided* somewhere, and this is that place.
  List<double> bracketBiases(
    SphereCaptureConfig config, {
    BracketMode? mode,
    int? maxBracketCount,
  }) {
    final requested = config.exposure.evBiases;
    if (mode == BracketMode.singleShot) return const [0.0];

    final limit = maxBracketCount ?? requested.length;
    if (limit >= requested.length || requested.length <= 1) return requested;
    if (limit < 2) return const [0.0];

    // Trim to the widest pair rather than to the first N. R3 names the 2-shot
    // bracket as the intermediate fallback before abandoning HDR, and a
    // bracket's value is its *spread*: keeping −2 and +2 preserves the dynamic
    // range, keeping −2 and 0 halves it.
    return [requested.first, requested.last];
  }

  /// Releases the lock at the end of the session.
  Future<void> release() async {
    await platform.unlock();
    _current = null;
  }
}
