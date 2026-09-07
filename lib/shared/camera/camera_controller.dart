import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'camera_session.dart';

/// Single source of truth for the paired 360° camera, read by the status bar,
/// the capture dock and (from Phase 4) Settings.
///
/// PHASE 2 IS MOCK. No Ricoh SDK, no Wi-Fi discovery — the prototype gives no
/// pairing protocol, and a camera integration cannot be written without
/// hardware to test against. The real session replaces the body of this class;
/// no widget changes.
class CameraSessionController extends Notifier<CameraSession> {
  @override
  CameraSession build() => _paired;

  /// The camera the prototype shows on every capture screen.
  static const CameraConnected _paired = CameraConnected(
    model: 'THETA X',
    serial: 'R0110482',
    batteryPercent: 76,
    storageFreeBytes: 21 * 1000 * 1000 * 1000,
    storageTotalBytes: 46 * 1000 * 1000 * 1000,
    firmware: 'v2.30.1',
  );

  /// Drives the help card's "Reconnect camera" button.
  Future<void> reconnect() async {
    if (state is CameraReconnecting) return;
    state = const CameraReconnecting();
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    state = _paired;
  }

  /// QA hook — lets a tester drop the camera without unplugging one, so the
  /// camera-lost state on every capture screen is reachable. Removed when the
  /// real session lands.
  void simulateDisconnect() => state = const CameraDisconnected();

  void simulateToggle() {
    state = state.isConnected ? const CameraDisconnected() : _paired;
  }
}

final cameraSessionProvider =
    NotifierProvider<CameraSessionController, CameraSession>(
  CameraSessionController.new,
);
