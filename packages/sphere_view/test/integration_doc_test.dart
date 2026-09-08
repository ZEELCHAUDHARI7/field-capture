import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// Compiles the code in `docs/INTEGRATION.md`.
///
/// That document is the whole of the integration story — Phase 13 puts host-app
/// integration out of scope as *code*, so this is the only place the knowledge
/// exists. A snippet in it that no longer compiles is worse than a missing
/// snippet: the reader copies it, it fails, and the natural conclusion is that
/// the package is broken rather than that the doc is stale.
///
/// The functions are never *called*. Type-checking them is the assertion, the
/// same trick `readme_snippet_test.dart` uses on the README, and for the same
/// reason: reading a snippet and nodding is not a check, making the compiler
/// read it is.
void main() {
  test('the §1 three-call quickstart type-checks', () {
    expect(quickstart, isA<Function>());
  });

  test('the §2 background-queue snippets type-check', () {
    expect(watchTheQueue, isA<Function>());
    expect(retryAFailedOne, isA<Function>());
  });

  test('the §3 heading and viewer snippets type-check', () {
    expect(recordTheHeading, isA<Function>());
    expect(view, isA<Function>());
    expect(openFacingNorth, isA<Function>());
  });

  test('the §4 storage-policy snippet type-checks', () {
    expect(applyStoragePolicy, isA<Function>());
  });

  test('the §5 capability-gate snippet type-checks', () {
    expect(gateTheFeature, isA<Function>());
    expect(createWithTheProbesAnswer, isA<Function>());
  });

  test('§5 claims about SphereCapability hold', () {
    // The doc's table lists five values, worst first, and tells a host app to
    // hide the feature on exactly two of them. Both claims are load-bearing —
    // an app that treated `noBracketing` as a refusal would hide the feature
    // on the whole of the fleet's low end, and one that treated
    // `unsupportedNoNativeLibrary` as merely degraded would let an operator
    // capture 29 positions that can never be stitched on that device.
    expect(SphereCapability.values, hasLength(5));
    expect(
      SphereCapability.values.first,
      SphereCapability.unsupportedNoNativeLibrary,
    );
    expect(SphereCapability.unsupportedNoNativeLibrary.isSupported, isFalse);
    expect(SphereCapability.unsupportedNoGyro.isSupported, isFalse);
    expect(SphereCapability.noBracketing.isSupported, isTrue);
    expect(SphereCapability.noDistortionModel.isSupported, isTrue);
    expect(SphereCapability.full.isSupported, isTrue);
  });

  test('§2 claims about the queue hold', () {
    // "maxAttempts (3 by default)".
    final queue = StitchQueue(directory: Directory.systemTemp);
    expect(queue.maxAttempts, 3);
  });

  test('§3 claims about the heading hold', () {
    // "An unknown heading is written as absent, not as zero" — the claim the
    // whole §3 argument rests on.
    expect(PanoramaHeading.unknown.isKnown, isFalse);
    expect(PanoramaHeading.unknown.degrees, isNull);
    // "A plan heading is good to a degree or two, the magnetometer to tens" is
    // prose, but which of the two is trusted is not.
    expect(PanoramaHeading.fromPlan(0).isTrustworthy, isTrue);
    expect(PanoramaHeading.fromMagnetometer(0).isTrustworthy, isFalse);
  });
}

// ── §1 The three-call quickstart ────────────────────────────────────────────

/// Verbatim from `docs/INTEGRATION.md`.
Future<StitchResult?> quickstart(BuildContext context) async {
  final session = await SphereCaptureSession.create(
    config: const SphereCaptureConfig(),
  );

  final bundle = await Navigator.push<CaptureBundle>(
    context,
    MaterialPageRoute(
      builder: (_) => SphereCaptureView(
        session: session,
        onCompleted: (bundle) => Navigator.pop(context, bundle),
      ),
    ),
  );
  if (bundle == null) return null;

  final result = await SphereStitcher().stitch(bundle);
  return result;
}

// ── §2 The background queue ─────────────────────────────────────────────────

/// Verbatim from `docs/INTEGRATION.md`.
Future<void> watchTheQueue(CaptureBundle bundle, String whereYouWantIt) async {
  final queue = StitchQueue(directory: await getApplicationSupportDirectory());
  await queue.load();
  await queue.start();

  queue.events.listen((event) {
    final id = event.entry.sessionId;
    if (event.progress != null) updateRow(id, event.progress!.fraction);
    if (event.result != null) markReady(id, event.result!);
    if (event.error != null) markFailed(id, '${event.error}');
    if (event.paused) showBanner(event.pauseReason);
  });

  await queue.enqueue(bundle, outputPath: whereYouWantIt);
}

/// Verbatim from `docs/INTEGRATION.md`.
Future<bool> retryAFailedOne(StitchQueue queue, String sessionId) =>
    queue.retry(sessionId);

// ── §3 What to persist ──────────────────────────────────────────────────────

/// Verbatim from `docs/INTEGRATION.md`.
void recordTheHeading(SphereCaptureSession session) {
  session.setPlanHeading(127.5);
  session.setMagnetometerHeading(310.0);
}

/// Verbatim from `docs/INTEGRATION.md`.
Widget view(String path) =>
    SphereViewer(image: File(path), showControls: true, gyroscopeEnabled: true);

/// Verbatim from `docs/INTEGRATION.md`.
Widget openFacingNorth(File file, PanoramaMetadata metadata) => SphereViewer(
  image: file,
  controller: SphereViewerController.forPanorama(
    metadata,
    lookAtCompassDegrees: 0,
  ),
);

// ── §4 Storage policy ───────────────────────────────────────────────────────

/// Verbatim from `docs/INTEGRATION.md`.
Future<void> applyStoragePolicy(
  CaptureBundle bundle,
  StitchResult result,
) async {
  if (result.report.meetsQualityTargets) {
    await bundle.directory.delete(recursive: true);
  }
}

// ── §5 The capability gate ──────────────────────────────────────────────────

/// Verbatim from `docs/INTEGRATION.md`.
Future<Widget> gateTheFeature() async {
  final report = await SphereCapabilityProbe.probe();
  if (!report.isSupported) {
    return DisabledTile(reason: report.blockingReason!);
  }
  return showCaptureButton(subtitle: report.headline);
}

/// Verbatim from `docs/INTEGRATION.md`.
Future<SphereCaptureSession> createWithTheProbesAnswer(
  SphereCapabilityReport report,
) => SphereCaptureSession.create(
  config: report.configFrom(const SphereCaptureConfig()),
  capability: report,
);

// ── The host app's half, which the doc leaves to the reader ─────────────────

/// Stand-in for the host app's row update.
void updateRow(String id, double fraction) {}

/// Stand-in for the host app's completion handler.
void markReady(String id, StitchResult result) {}

/// Stand-in for the host app's failure handler.
void markFailed(String id, String error) {}

/// Stand-in for the host app's thermal banner.
void showBanner(String? reason) {}

/// Stand-in for the host app's disabled entry point.
class DisabledTile extends StatelessWidget {
  /// Creates the tile.
  const DisabledTile({super.key, required this.reason});

  /// Why the feature is unavailable.
  final String reason;

  @override
  Widget build(BuildContext context) => Text(reason);
}

/// Stand-in for the host app's entry point.
Widget showCaptureButton({required String subtitle}) => Text(subtitle);
