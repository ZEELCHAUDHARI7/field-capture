/// The state of the paired 360° camera.
///
/// Two states are drawn in the prototype — connected (green chip) and lost
/// (red chip with an inline help card). Reconnecting is a third, transient
/// state the deck never draws; it is ASSUMED so the button on the help card
/// has somewhere to go. See ASSUMPTIONS.md §F1.
sealed class CameraSession {
  const CameraSession();

  bool get isConnected => this is CameraConnected;
}

/// Paired and reachable. Everything on the chip is drawn in the prototype.
class CameraConnected extends CameraSession {
  const CameraConnected({
    required this.model,
    required this.serial,
    required this.batteryPercent,
    required this.storageFreeBytes,
    required this.storageTotalBytes,
    required this.firmware,
  });

  /// "THETA X" on the chip, "Ricoh Theta X" in Settings.
  final String model;

  /// "R0110482".
  final String serial;

  final int batteryPercent;
  final int storageFreeBytes;
  final int storageTotalBytes;

  /// "v2.30.1".
  final String firmware;
}

/// Dropped off Wi-Fi. Video and Image capture refuse; Mobile Capture does not.
class CameraDisconnected extends CameraSession {
  const CameraDisconnected();
}

/// Transient — the user tapped Reconnect.
class CameraReconnecting extends CameraSession {
  const CameraReconnecting();
}
