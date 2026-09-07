import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Capture resolution, sourced from the paired camera's capabilities.
enum CaptureResolution {
  k55('5.5K'),
  k8('8K'),
  k11('11K');

  const CaptureResolution(this.label);
  final String label;
}

/// Frame rate for 360° video, same source.
enum CaptureFrameRate {
  fps24('24 fps'),
  fps30('30 fps'),
  fps60('60 fps');

  const CaptureFrameRate(this.label);
  final String label;
}

/// Everything on Settings, plus the upload policy the queue screen shares.
@immutable
class AppSettings {
  const AppSettings({
    this.resolution = CaptureResolution.k8,
    this.frameRate = CaptureFrameRate.fps30,
    this.uploadOnWifiOnly = true,
    this.autoDeleteAfterUpload = false,
  });

  /// 8K and 30 fps are the values the prototype shows selected.
  final CaptureResolution resolution;
  final CaptureFrameRate frameRate;

  /// "Wi-Fi-only is the default; cellular upload is an explicit opt-in."
  final bool uploadOnWifiOnly;

  /// "Auto-delete after upload is off by default — destructive settings opt in."
  final bool autoDeleteAfterUpload;

  AppSettings copyWith({
    CaptureResolution? resolution,
    CaptureFrameRate? frameRate,
    bool? uploadOnWifiOnly,
    bool? autoDeleteAfterUpload,
  }) {
    return AppSettings(
      resolution: resolution ?? this.resolution,
      frameRate: frameRate ?? this.frameRate,
      uploadOnWifiOnly: uploadOnWifiOnly ?? this.uploadOnWifiOnly,
      autoDeleteAfterUpload:
          autoDeleteAfterUpload ?? this.autoDeleteAfterUpload,
    );
  }
}

/// One source for settings, read by Settings and by the upload queue — the
/// prototype draws the Wi-Fi-only switch on both screens, and they must agree.
///
/// PHASE 4 MOCK: in memory only. Persistence is deferred with everything else
/// (ASSUMPTIONS.md §B8), so settings reset on restart.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();

  void setResolution(CaptureResolution value) =>
      state = state.copyWith(resolution: value);

  void setFrameRate(CaptureFrameRate value) =>
      state = state.copyWith(frameRate: value);

  void setUploadOnWifiOnly(bool value) =>
      state = state.copyWith(uploadOnWifiOnly: value);

  void setAutoDeleteAfterUpload(bool value) =>
      state = state.copyWith(autoDeleteAfterUpload: value);
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
