import '../api/models/capture_bundle.dart';
import '../api/models/stitch_result.dart';
import '../api/models/stitch_warning.dart';

/// Turns the numbers in a [CaptureBundle] and a [StitchReport] into sentences a
/// construction manager can act on.
///
/// Phase 09 §3.3 states the rule negatively, and it is the important half:
/// **never a generic "stitching may be imperfect"**. A message like that costs
/// the user everything and tells them nothing — they cannot tell whether to
/// re-shoot, stand further back, or ignore it. Architecture §8's "never silently
/// degrade" is only worth anything if the thing that reaches the user is
/// specific enough to be acted on.
///
/// Since Phase 12 the sentences themselves live in [StitchWarningMessages],
/// keyed by [StitchWarningCode]. This class is now the part that decides *which*
/// warnings a given bundle or report deserves — including the ones that are not
/// reported by a stage at all but are read off the report's own measurements, so
/// that "S1 missed its target" arrives as a coded warning with a sentence like
/// everything else rather than as prose written here.
abstract final class CaptureWarnings {
  /// What the capture itself has to say — before any stitching.
  ///
  /// A partial capture is not an error (Phase 08 `SphereCaptureSession.finish`
  /// is deliberately total), so this describes rather than complains.
  static List<StitchWarning> forBundle(CaptureBundle bundle) {
    final warnings = <StitchWarning>[];
    final missing = bundle.plan.length - bundle.positions.length;
    if (missing > 0) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.positionsNotCaptured,
          data: {'missing': missing, 'planned': bundle.plan.length},
          detail:
              '${bundle.positions.length} of ${bundle.plan.length} planned '
              'positions were captured',
        ),
      );
    }
    // The session's own warnings, recorded at capture time. They are strings in
    // `device_info` because that is what every bundle written before Phase 12
    // holds, and those bundles are fixtures — so they arrive as
    // `unrecognised` carrying their own sentence, which is honest about the fact
    // that their cause was never recorded in a form anything can act on.
    final recorded = bundle.deviceInfo['warnings'];
    if (recorded is List) {
      for (final entry in recorded) {
        // Never throws on a malformed entry. This runs on the review screen,
        // against a file that may have been written by an older build or copied
        // off a device by hand, and a `device_info` block with something
        // unexpected in it must not take the screen down — that would turn a
        // cosmetic problem into a lost capture.
        StitchWarning warning;
        if (entry is String) {
          warning = StitchWarning(
            StitchWarningCode.unrecognised,
            detail: entry,
          );
        } else {
          try {
            warning = StitchWarning.fromJson(entry);
          } on Object {
            warning = StitchWarning(
              StitchWarningCode.unrecognised,
              detail: 'A warning recorded with this capture could not be read: '
                  '$entry',
            );
          }
        }
        if (warning.message.isNotEmpty &&
            !warnings.any((w) => w.message == warning.message)) {
          warnings.add(warning);
        }
      }
    }
    return List.unmodifiable(warnings);
  }

  /// What the stitch has to say.
  ///
  /// The report's own [StitchReport.warnings] first — they name causes the
  /// measurements below can only describe symptoms of — then one warning per
  /// criterion that missed.
  ///
  /// The thresholds are the S1/S2/S4/S5 constants on [StitchReport] rather than
  /// numbers repeated here, so a review screen can never disagree with
  /// [StitchReport.meetsQualityTargets] about whether this stitch was good.
  static List<StitchWarning> forReport(StitchReport report) => List.unmodifiable([
    ...report.warnings,
    ...criteriaWarnings(report),
  ]);

  /// The warnings implied by the report's own measurements.
  ///
  /// Separate from [forReport] because these are derived rather than reported:
  /// no stage emitted them, they are what the numbers mean. Keeping them coded
  /// rather than phrasing them here is what puts them under the same exhaustive
  /// message test as everything else.
  static List<StitchWarning> criteriaWarnings(StitchReport report) {
    final warnings = <StitchWarning>[];

    final dropped = report.droppedPositionIndices.length;
    if (dropped > 0) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.positionsDropped,
          data: {
            'count': dropped,
            'indices': report.droppedPositionIndices,
          },
          detail: 'dropped position indices ${report.droppedPositionIndices}',
        ),
      );
    }

    if (report.coverageFraction < 1.0 - 1e-9) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.coverageIncomplete,
          data: {'fraction': report.coverageFraction},
          detail:
              'coverage_fraction ${report.coverageFraction.toStringAsFixed(3)}',
        ),
      );
    }

    if (report.rmsReprojectionErrorPx >=
        StitchReport.maxRmsReprojectionErrorPx) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.reprojectionAboveTarget,
          data: {
            'rms_px': report.rmsReprojectionErrorPx,
            'target_px': StitchReport.maxRmsReprojectionErrorPx,
          },
          detail:
              'S1 ${report.rmsReprojectionErrorPx.toStringAsFixed(2)} px '
              'against a ${StitchReport.maxRmsReprojectionErrorPx} px target',
        ),
      );
    }

    if (report.loopClosureErrorDegrees >=
        StitchReport.maxLoopClosureErrorDegrees) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.loopClosureAboveTarget,
          data: {
            'degrees': report.loopClosureErrorDegrees,
            'target_degrees': StitchReport.maxLoopClosureErrorDegrees,
          },
          detail:
              'S2 ${report.loopClosureErrorDegrees.toStringAsFixed(3)}° '
              'against a ${StitchReport.maxLoopClosureErrorDegrees}° target',
        ),
      );
    }

    if (report.maxGainRatio >= StitchReport.maxAcceptableGainRatio) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.gainRatioAboveTarget,
          data: {
            'max_gain_ratio': report.maxGainRatio,
            'target': StitchReport.maxAcceptableGainRatio,
          },
          detail:
              'S4 ${report.maxGainRatio.toStringAsFixed(3)} against a '
              '${StitchReport.maxAcceptableGainRatio} target',
        ),
      );
    }

    if (report.residualTiltDegrees >= StitchReport.maxResidualTiltDegrees) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.residualTiltAboveTarget,
          data: {
            'degrees': report.residualTiltDegrees,
            'target_degrees': StitchReport.maxResidualTiltDegrees,
          },
          detail:
              'residual tilt ${report.residualTiltDegrees.toStringAsFixed(3)}° '
              'against a ${StitchReport.maxResidualTiltDegrees}° acceptance',
        ),
      );
    }

    return warnings;
  }

  /// [forBundle] as sentences, for a widget that just wants text.
  static List<String> sentencesForBundle(CaptureBundle bundle) =>
      _sentences(forBundle(bundle));

  /// [forReport] as sentences, for a widget that just wants text.
  static List<String> sentencesForReport(StitchReport report) =>
      _sentences(forReport(report));

  /// Messages, deduplicated, order preserved.
  ///
  /// Deduplication is by sentence rather than by code, because two codes can
  /// legitimately describe the same thing to a user — a bracket that fell back
  /// and the aggregate count of brackets that fell back — and showing a manager
  /// the same sentence twice reads as a bug in the app rather than as two
  /// findings.
  static List<String> _sentences(List<StitchWarning> warnings) {
    final out = <String>[];
    for (final warning in warnings) {
      final message = warning.message;
      if (message.isNotEmpty && !out.contains(message)) out.add(message);
    }
    return List.unmodifiable(out);
  }
}
