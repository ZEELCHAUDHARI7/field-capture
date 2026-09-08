import '../api/models/sphere_capture_config.dart';
import '../api/models/stitch_warning.dart';
import '../camera/camera_platform.dart';
import '../camera/pigeon_camera_platform.dart';

/// The tier that will be used, and everything that decided it.
///
/// A record rather than a bare [QualityTier] because architecture §8's rule is
/// that no compromise happens quietly: if the pre-flight check pushed the
/// device down a tier, the panorama is smaller than the hardware suggests, and
/// the reason has to travel with it into `StitchReport.warnings` instead of
/// being inferred later from a suspiciously small file.
class MemoryTierProbe {
  /// Creates a probe result.
  const MemoryTierProbe({
    required this.tier,
    required this.totalPhysicalMemoryMb,
    required this.availableProcessMemoryMb,
    required this.tierFromTotalMemory,
    this.warning,
  });

  /// The tier to stitch at.
  final QualityTier tier;

  /// What the device reported as total RAM.
  final int totalPhysicalMemoryMb;

  /// What the process reported as headroom, or `-1` where unavailable.
  final int availableProcessMemoryMb;

  /// The tier [totalPhysicalMemoryMb] alone would have chosen.
  final QualityTier tierFromTotalMemory;

  /// Why [tier] is below [tierFromTotalMemory], or `null` when it is not.
  ///
  /// A coded [StitchWarning] rather than a sentence, so the reason travels into
  /// `StitchReport.warnings` with the numbers attached and gets its wording from
  /// the one place Phase 12 §2's copy lives.
  final StitchWarning? warning;

  /// Whether the pre-flight check moved the tier down.
  bool get wasDowngraded => tier != tierFromTotalMemory;

  @override
  String toString() =>
      'MemoryTierProbe(${tier.name}, ${totalPhysicalMemoryMb}MB total, '
      '${availableProcessMemoryMb < 0 ? 'headroom unknown' : '$availableProcessMemoryMb MB free'})';
}

/// Picks the output resolution from the device's RAM.
///
/// Exists because output size is the one "quality setting" that is not a taste
/// question. Multi-band blending at 8192×4096 holds a 201 MB level-0
/// accumulator, 134 MB of weight maps, their pyramids, and a 100 MB output —
/// 550–650 MB peak before the OS, Flutter and the camera take theirs
/// (architecture §7). On a 3 GB tablet, offering that as a checkbox is offering
/// the user an OOM kill. Probing instead makes the choice deterministic per
/// device and keeps the tier reportable in `StitchReport`.
class MemoryTier {
  const MemoryTier._();

  /// Below this many MB of physical RAM, use [QualityTier.low].
  static const int lowTierCeilingMb = 3072;

  /// Below this many MB of physical RAM, use [QualityTier.mid].
  static const int midTierCeilingMb = 6144;

  /// The tier assumed when the platform cannot be reached at all.
  ///
  /// [QualityTier.low] rather than [QualityTier.mid], because the cost of the
  /// two mistakes is not symmetric: guessing low on a big tablet gives a
  /// smaller panorama, and guessing mid on a small one gives an OOM kill
  /// halfway through a 60-second job the user already waited for.
  static const QualityTier fallbackTier = QualityTier.low;

  /// Reads total physical memory and returns the tier it supports.
  ///
  /// **Total, not available**, and this is the whole of Phase 10 §4. Available
  /// memory moves with whatever else the device is doing, so a tier derived
  /// from it would give two runs of the same bundle on the same tablet two
  /// different output resolutions — at which point "the panorama came out at
  /// 4096 wide" stops being evidence about anything and a bug report cannot be
  /// acted on. Total memory is a property of the device and gives the same
  /// answer every time.
  ///
  /// Available memory is still consulted, but only as a **pre-flight veto**:
  /// see [probeDetailed].
  static Future<QualityTier> probe({SphereCameraPlatform? platform}) async =>
      (await probeDetailed(platform: platform)).tier;

  /// [probe], with the reasoning attached.
  ///
  /// The iOS pre-flight is the part worth reading. iOS kills a process under
  /// memory pressure with **no recoverable signal** — there is no exception to
  /// catch, no callback, no chance to drop a tier and retry; the app simply
  /// stops existing, which the user experiences as it vanishing mid-stitch. So
  /// on iOS the only defence is to ask `os_proc_available_memory()` *before*
  /// starting and refuse a tier that will not fit. Android returns `-1` here
  /// and is covered by the retry path instead, which works there because a
  /// failed allocation is catchable.
  static Future<MemoryTierProbe> probeDetailed({
    SphereCameraPlatform? platform,
  }) async {
    final camera = platform ?? PigeonCameraPlatform();
    int totalMb;
    int availableMb;
    try {
      totalMb = await camera.totalPhysicalMemoryMb();
      availableMb = await camera.availableProcessMemoryMb();
    } catch (_) {
      // A probe that throws must not take the stitch with it. The conservative
      // tier still produces a panorama; a rethrown platform error produces
      // nothing at all, which is a worse answer to "how much RAM is there".
      return MemoryTierProbe(
        tier: fallbackTier,
        totalPhysicalMemoryMb: 0,
        availableProcessMemoryMb: -1,
        tierFromTotalMemory: fallbackTier,
        warning: StitchWarning(
          StitchWarningCode.memoryProbeUnavailable,
          detail:
              'totalPhysicalMemoryMb() or availableProcessMemoryMb() threw; '
              'fell back to the ${fallbackTier.name} tier',
        ),
      );
    }
    return resolve(totalMb: totalMb, availableMb: availableMb);
  }

  /// The tier for a given pair of measurements. Pure, so every branch is
  /// testable without a device — including the ones our fleet will never take.
  static MemoryTierProbe resolve({
    required int totalMb,
    required int availableMb,
  }) {
    final fromTotal = forTotalMemoryMb(totalMb);
    if (availableMb < 0) {
      // The platform declined to answer. Not a downgrade: `-1` is Android
      // saying it has no honest per-process figure, not a device saying it is
      // short of memory, and treating silence as bad news would put every
      // Android tablet a tier below the one it can actually run.
      return MemoryTierProbe(
        tier: fromTotal,
        totalPhysicalMemoryMb: totalMb,
        availableProcessMemoryMb: availableMb,
        tierFromTotalMemory: fromTotal,
      );
    }

    var tier = fromTotal;
    while (availableMb < estimatedPeakMb(tier)) {
      final lower = degrade(tier);
      if (lower == null) break;
      tier = lower;
    }
    return MemoryTierProbe(
      tier: tier,
      totalPhysicalMemoryMb: totalMb,
      availableProcessMemoryMb: availableMb,
      tierFromTotalMemory: fromTotal,
      warning: tier == fromTotal
          ? null
          : StitchWarning(
              StitchWarningCode.tierDowngradedBeforeStart,
              data: {
                'width': tier.outputWidth,
                'height': tier.outputHeight,
                'requested_width': fromTotal.outputWidth,
                'requested_height': fromTotal.outputHeight,
                'total_mb': totalMb,
                'available_mb': availableMb,
                'estimated_peak_mb': estimatedPeakMb(fromTotal),
              },
              detail:
                  'the pre-flight check saw $availableMb MB free of $totalMb MB '
                  'total against an estimated ${estimatedPeakMb(fromTotal)} MB '
                  'peak for ${fromTotal.name}',
            ),
    );
  }

  /// Roughly how much memory a stitch at [tier] peaks at, in MB.
  ///
  /// Architecture §7 works the number for `high`: a 201 MB level-0 accumulator,
  /// 67 MB of pyramid above it, 134 MB of weight maps with 45 MB of pyramid,
  /// the warped frame and mask per input and a 100 MB output — 550–650 MB —
  /// and then §5's strip blending divides the blender's share by the strip
  /// count while leaving the output and the warped frames alone.
  ///
  /// Deliberately an over-estimate. It is used to *refuse* a tier, and the two
  /// errors are not equal: an estimate that is too high costs a smaller
  /// panorama, and one that is too low costs the whole stitch on the device
  /// that could least afford the time.
  static int estimatedPeakMb(QualityTier tier) => switch (tier) {
    QualityTier.low => 220,
    QualityTier.mid => 400,
    QualityTier.high => 700,
  };

  /// The tier [totalMb] of RAM supports. Pure, so the thresholds are testable
  /// without a device.
  static QualityTier forTotalMemoryMb(int totalMb) {
    if (totalMb < lowTierCeilingMb) return QualityTier.low;
    if (totalMb < midTierCeilingMb) return QualityTier.mid;
    return QualityTier.high;
  }

  /// The tier one step below [tier], or `null` at the bottom.
  ///
  /// Used for the single OOM retry: degrade once, finish, and put the downgrade
  /// in the report rather than failing outright or pretending nothing happened
  /// (architecture §8).
  static QualityTier? degrade(QualityTier tier) => switch (tier) {
    QualityTier.high => QualityTier.mid,
    QualityTier.mid => QualityTier.low,
    QualityTier.low => null,
  };
}
