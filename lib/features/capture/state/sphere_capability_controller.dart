import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sphere_view/sphere_view.dart';

import '../../../shared/demo/demo_controls.dart';

/// Whether Mobile Capture may be offered on this device, and the sentence to
/// show if it may not.
@immutable
class SphereCaptureGate {
  const SphereCaptureGate({this.report, this.blockingReason});

  /// What the probe found. Null only when the probe itself failed.
  final SphereCapabilityReport? report;

  /// Why the feature is refused, in plain language. Null when it is available.
  final String? blockingReason;

  bool get isAllowed => blockingReason == null && report != null;

  /// The one-liner worth showing when the feature *is* available but the device
  /// cannot do all of it — "no hardware exposure bracket", say. Already coded
  /// and already a sentence, which is how "this tablet has no HDR" stops being
  /// mistaken for "this app is broken" three weeks later.
  List<String> get warnings => <String>[
        for (final StitchWarning w in report?.warnings ?? const <StitchWarning>[])
          w.message,
      ];
}

/// The probe itself, behind a seam.
///
/// Same reason every repository in this app is behind an interface: the real
/// one reads platform channels, and a unit test has none. Overriding this is
/// how the gate's own logic — the demo override, the refusal sentences — is
/// tested without a device.
final sphereCapabilityProbeProvider =
    Provider<Future<SphereCapabilityReport> Function()>(
  (ref) => SphereCapabilityProbe.probe,
);

/// The capability probe, at the feature entry point.
///
/// `docs/INTEGRATION.md` §5: check before you offer, not mid-flow. Discovering
/// on site that a tablet cannot do this is acceptable; discovering it after 25
/// captures is not, and neither is discovering it at the stitch, an hour later,
/// back in the office.
///
/// Cheap by construction — motion capabilities, camera *descriptors* and total
/// RAM, with no camera opened — precisely so it can run before a button is
/// drawn. It never throws for an unsupported device, so there is no `catch`
/// here beyond the probe itself failing.
///
/// The demo console can still force a refusal, because otherwise the
/// unsupported state needs a second device to reach. It layers on top of the
/// real answer rather than replacing it, so what the console produces is the
/// state the app would show, not a different one.
final sphereCaptureGateProvider = FutureProvider<SphereCaptureGate>((ref) async {
  final bool allowedByDemo = ref.watch(
    demoControlsProvider
        .select((DemoControls demo) => demo.mobileCaptureSupported),
  );

  final SphereCapabilityReport report;
  try {
    report = await ref.watch(sphereCapabilityProbeProvider)();
  } on Object catch (error) {
    return SphereCaptureGate(
      blockingReason: 'Could not check this device for Mobile Capture: $error',
    );
  }

  if (!allowedByDemo) {
    return SphereCaptureGate(
      report: report,
      blockingReason: 'Mobile Capture is switched off for this device in the '
          'demo console.',
    );
  }

  return SphereCaptureGate(
    report: report,
    blockingReason:
        report.isSupported ? null : (report.blockingReason ?? report.headline),
  );
});

/// The CAMERA runtime grant.
///
/// `sphere_view` requests nothing itself — a library that pops a system dialog
/// decides on the app's behalf when the user is interrupted — so this is the
/// app's job. Camera2 throws a bare `SecurityException` from deep inside the
/// framework when the permission is missing, which reaches Dart as an untyped
/// failure, so asking first is also what lets the app tell "no permission" from
/// "no camera".
class CameraPermission {
  const CameraPermission();

  /// Requests the grant if it is not already held. Returns null when it is
  /// held, or the sentence to show when it is not.
  Future<String?> ensure() async {
    PermissionStatus status = await Permission.camera.status;
    if (status.isGranted) return null;

    status = await Permission.camera.request();
    if (status.isGranted) return null;

    if (status.isPermanentlyDenied) {
      return 'Camera access is blocked for this app. Turn it on in Settings to '
          'use Mobile Capture.';
    }
    return 'Mobile Capture needs the camera.';
  }
}

/// Overridden in tests, which have no platform channel to ask.
final cameraPermissionProvider =
    Provider<CameraPermission>((ref) => const CameraPermission());
