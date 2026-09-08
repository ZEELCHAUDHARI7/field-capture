import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a mocked data source should do the next time it is asked for a list.
enum DataFault {
  none('Normal'),
  empty('Empty'),
  error('Error');

  const DataFault(this.label);

  final String label;
}

/// The faults a demo operator can switch on, and the reset generation.
///
/// The prototype draws no loading, empty or error states, so the mocks were
/// built with flags for them — but those flags were only reachable by editing
/// `main.dart` and restarting. Eight states the app can already render were
/// therefore invisible in a live demo. This moves the flags to runtime.
///
/// It lives in `shared/` for the same reason connectivity and the camera
/// session do: the repositories in four different features read it, and none
/// of them should be reaching into another feature to do so.
@immutable
class DemoControls {
  const DemoControls({
    this.projects = DataFault.none,
    this.calibrations = DataFault.none,
    this.planFails = false,
    this.downloadsFail = false,
    this.mobileCaptureSupported = true,
    this.generation = 0,
  });

  final DataFault projects;
  final DataFault calibrations;

  /// The plan has no empty state — a calibration without a plan is not a
  /// calibration — so this one is a boolean.
  final bool planFails;

  /// Drop a calibration bundle download at 62%, which is where the prototype's
  /// own failed queue item drops.
  final bool downloadsFail;

  /// "Gated on device capability, with a clear message when unsupported"
  /// (stated). Nothing queries the device, so this is the gate.
  final bool mobileCaptureSupported;

  /// Bumped by [DemoControlsController.reset].
  ///
  /// Every repository provider reads this, so incrementing it rebuilds all of
  /// them — and because each mock holds its saved captures, issues and walks
  /// in its own fields, a fresh instance *is* the reset. No clear-down code
  /// has to exist, and none can drift out of date as more state is added.
  final int generation;

  /// Whether anything is switched away from the state a demo should open in.
  bool get isPristine =>
      projects == DataFault.none &&
      calibrations == DataFault.none &&
      !planFails &&
      !downloadsFail &&
      mobileCaptureSupported;

  /// How many faults are active, for the banner on the panel.
  int get activeFaults =>
      (projects == DataFault.none ? 0 : 1) +
      (calibrations == DataFault.none ? 0 : 1) +
      (planFails ? 1 : 0) +
      (downloadsFail ? 1 : 0) +
      (mobileCaptureSupported ? 0 : 1);

  DemoControls copyWith({
    DataFault? projects,
    DataFault? calibrations,
    bool? planFails,
    bool? downloadsFail,
    bool? mobileCaptureSupported,
    int? generation,
  }) {
    return DemoControls(
      projects: projects ?? this.projects,
      calibrations: calibrations ?? this.calibrations,
      planFails: planFails ?? this.planFails,
      downloadsFail: downloadsFail ?? this.downloadsFail,
      mobileCaptureSupported:
          mobileCaptureSupported ?? this.mobileCaptureSupported,
      generation: generation ?? this.generation,
    );
  }
}

class DemoControlsController extends Notifier<DemoControls> {
  @override
  DemoControls build() => const DemoControls();

  void setProjects(DataFault fault) =>
      state = state.copyWith(projects: fault);

  void setCalibrations(DataFault fault) =>
      state = state.copyWith(calibrations: fault);

  void setPlanFails(bool value) => state = state.copyWith(planFails: value);

  void setDownloadsFail(bool value) =>
      state = state.copyWith(downloadsFail: value);

  void setMobileCaptureSupported(bool value) =>
      state = state.copyWith(mobileCaptureSupported: value);

  /// Clears every fault and, via [DemoControls.generation], throws away every
  /// capture, issue and walk saved since launch.
  void reset() => state = DemoControls(generation: state.generation + 1);
}

final demoControlsProvider =
    NotifierProvider<DemoControlsController, DemoControls>(
  DemoControlsController.new,
);
