import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sphere_view/sphere_view.dart';

import 'preview_rotation_probe.dart';
import 'simulate_kill.dart';
import 'stations.dart';

/// Flows 1, 2 and 7: the guided capture, handing the bundle to the queue, and
/// picking a killed capture back up.
///
/// Everything here is three package calls and some navigation. That is the
/// claim `docs/INTEGRATION.md` makes, and this file is where it is either true
/// or it is not.
abstract final class CaptureFlow {
  /// The bearing this demo claims each station faces, in degrees clockwise from
  /// north.
  ///
  /// A stand-in for the number a real host reads off the plan the walking path
  /// was drawn on. It is a constant here rather than a guess dressed up as a
  /// measurement: the viewer prints the heading and its source, so what this
  /// demonstrates is that a supplied heading reaches GPano, not that 42° is true
  /// of anywhere.
  static const double _demoStationHeadingDegrees = 42;

  /// Captures one new station.
  ///
  /// Returns as soon as the bundle is in the queue. It does **not** wait for
  /// the stitch — the manager is walking to the next station, and this is the
  /// behaviour flow 2 exists to keep working.
  static Future<void> start(BuildContext context, StationStore store) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Phase 12 §1's gate, at the feature entry point: before a row is created,
    // before a camera is opened, before the operator has invested anything.
    // `SphereCaptureSession.create` runs the same probe itself, so this is
    // belt and braces — but a host app that only relied on the exception would
    // be showing the button first and apologising second.
    final SphereCapabilityReport capability;
    try {
      capability = await SphereCapabilityProbe.probe();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Probe failed: $error')));
      return;
    }
    if (!capability.isSupported) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(capability.blockingReason ?? capability.headline),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    // The row exists before the first shutter, so that a kill during capture
    // leaves something in the list to resume from rather than an orphaned
    // folder nobody will ever find.
    final station = await store.begin();

    final SphereCaptureSession session;
    try {
      session = await SphereCaptureSession.create(
        // The device's own answer, not ours: on a tablet that cannot bracket,
        // asking for three exposures returns one frame per position and the
        // frame gate rejects every one of them.
        config: capability.configFrom(const SphereCaptureConfig()),
        capability: capability,
        sessionId: station.sessionId,
        directory: Directory(station.bundleDirectory),
      );
    } on InsufficientCoverageException catch (error) {
      await store.discard(station);
      messenger.showSnackBar(
        SnackBar(
          content: Text('$error'),
          duration: const Duration(seconds: 10),
        ),
      );
      return;
    } on Object catch (error) {
      await store.discard(station);
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      return;
    }

    // Which way the panorama faces, so it opens pointing north in Google Photos
    // rather than at whichever wall the operator happened to start on.
    //
    // **The host supplies this and only the host can.** Both pose sources this
    // package uses are deliberately magnetometer-free — Android's
    // `GAME_ROTATION_VECTOR` and iOS's `.xArbitraryCorrectedZVertical` — because a
    // magnetometer indoors is dragged around by every steel column and every
    // motor, and a heading that is confidently wrong is worse than one that is
    // absent. So yaw 0 is wherever the session started, and turning that into a
    // compass bearing needs something outside the sensor stack.
    //
    // On a real site walk that something is the plan: the manager drew the path,
    // so the app knows which way the station faces. This demo has no plan, so it
    // uses a fixed bearing and says so — the point is to show *where the call
    // goes*, since without it every panorama ships with no GPano
    // `PoseHeadingDegrees` at all, which is what was happening.
    session.setPlanHeading(_demoStationHeadingDegrees);

    await _run(
      navigator: navigator,
      messenger: messenger,
      store: store,
      station: station,
      session: session,
      capability: capability,
      // A fresh capture starts on the coaching screen: "pivot, don't walk" is
      // the parallax mitigation from architecture §3, and parallax is the one
      // error in this pipeline that no amount of algorithm removes.
      showPreCapture: true,
    );
  }

  /// Flow 7: continues a capture the app was killed in the middle of.
  ///
  /// The stored plan is authoritative and is not rebuilt — the frames already
  /// on disk were shot against it. If the camera re-opens with a materially
  /// different field of view the package refuses rather than mixing two
  /// geometries into one bundle, and that refusal is worth showing.
  static Future<void> resume(
    BuildContext context,
    StationStore store,
    Station station,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final SphereCaptureSession session;
    try {
      session = await SphereCaptureSession.resume(
        Directory(station.bundleDirectory),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('$error'),
          duration: const Duration(seconds: 12),
        ),
      );
      return;
    }

    await _run(
      navigator: navigator,
      messenger: messenger,
      store: store,
      station: station,
      session: session,
      capability: null,
      // The operator has already been told to pivot rather than walk, minutes
      // ago, and is standing in the middle of a half-finished sphere. Sending
      // them back to the coaching screen would be the app forgetting what it
      // was doing.
      showPreCapture: false,
    );
  }

  static Future<void> _run({
    required NavigatorState navigator,
    required ScaffoldMessengerState messenger,
    required StationStore store,
    required Station station,
    required SphereCaptureSession session,
    required SphereCapabilityReport? capability,
    required bool showPreCapture,
  }) async {
    try {
      if (showPreCapture) {
        final start = await navigator.push<bool>(
          MaterialPageRoute(
            builder: (context) => SpherePreCaptureScreen(
              plan: session.plan,
              capability: capability,
              onStart: () => Navigator.pop(context, true),
              onCancel: () => Navigator.pop(context, false),
            ),
          ),
        );
        if (start != true) {
          await session.abort();
          await store.discard(station);
          return;
        }
      }

      // Null means "use whatever the package derived", which is what a real app
      // ships. The probe below overrides it so a device whose preview comes up
      // sideways can be diagnosed in place rather than over three rebuilds.
      var previewTurns = <int?>[null];

      final bundle = await navigator.push<CaptureBundle>(
        MaterialPageRoute(
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => Stack(
              children: [
                SphereCaptureView(
                  session: session,
                  previewQuarterTurns: previewTurns.first,
                  onCompleted: (bundle) => Navigator.pop(context, bundle),
                  onCancelled: () => Navigator.pop(context),
                  onError: (error, _) => messenger.showSnackBar(
                    SnackBar(content: Text('$error')),
                  ),
                ),
                // Flow 7's trigger. It sits on top of the capture screen because
                // that is where the interesting kill happens: half a sphere on
                // disk, a plan half worked through, and a `bundle.json` written
                // after the last accepted position.
                const Positioned(
                  top: 48,
                  left: 16,
                  child: SafeArea(child: SimulateKillButton()),
                ),
                Positioned(
                  top: 104,
                  left: 16,
                  child: SafeArea(
                    child: PreviewRotationProbe(
                      session: session,
                      quarterTurns:
                          previewTurns.first ?? session.previewQuarterTurns,
                      onChanged: (turns) =>
                          setState(() => previewTurns = <int?>[turns]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (bundle == null) {
        // `SphereCaptureView` already called `abort()`, which deletes what was
        // written. The row goes with it.
        await store.discard(station);
        return;
      }

      final save = await navigator.push<bool>(
        MaterialPageRoute(
          builder: (context) => SphereReviewScreen(
            bundle: bundle,
            saveLabel: 'Queue the stitch',
            onSave: () => Navigator.pop(context, true),
            onDiscard: () => Navigator.pop(context, false),
          ),
        ),
      );
      if (save != true) {
        await store.discard(station);
        return;
      }

      // The one line the whole demo is about. `record` enqueues and returns;
      // nothing here awaits a stitch.
      await store.record(station, bundle);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${station.label} queued. Capture the next one — the stitch runs '
            'behind you.',
          ),
        ),
      );
    } finally {
      // The session owns the camera and the wakelock. A flow that ends anywhere
      // other than `finish()` still has to give both back.
      await session.dispose();
    }
  }
}
