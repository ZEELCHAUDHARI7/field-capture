import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/plan_repository.dart';
import '../models/workspace_data.dart';

/// The two tabs on the Level Workspace.
enum WorkspaceTab { capture, issues }

/// The coverage filter — "a two-state filter rather than a date picker, it is
/// a field decision" (stated).
enum HistoryFilter {
  today('Today'),
  all('All');

  const HistoryFilter(this.label);
  final String label;
}

/// View state for one open calibration.
///
/// Separate from the data controller because none of this touches the
/// repository: it is what the user has toggled, and it should survive a data
/// refresh untouched.
@immutable
class WorkspaceViewState {
  const WorkspaceViewState({
    this.tab = WorkspaceTab.capture,
    this.showCoverage = true,
    this.filter = HistoryFilter.today,
    this.cameraHelpDismissed = false,
  });

  final WorkspaceTab tab;

  /// Coverage is on in every state the prototype draws.
  final bool showCoverage;

  final HistoryFilter filter;

  /// "The help card is dismissible and does not block the plan" (stated).
  final bool cameraHelpDismissed;

  WorkspaceViewState copyWith({
    WorkspaceTab? tab,
    bool? showCoverage,
    HistoryFilter? filter,
    bool? cameraHelpDismissed,
  }) {
    return WorkspaceViewState(
      tab: tab ?? this.tab,
      showCoverage: showCoverage ?? this.showCoverage,
      filter: filter ?? this.filter,
      cameraHelpDismissed: cameraHelpDismissed ?? this.cameraHelpDismissed,
    );
  }
}

class WorkspaceViewController
    extends FamilyNotifier<WorkspaceViewState, String> {
  @override
  WorkspaceViewState build(String arg) => const WorkspaceViewState();

  void selectTab(WorkspaceTab tab) => state = state.copyWith(tab: tab);

  void toggleCoverage() =>
      state = state.copyWith(showCoverage: !state.showCoverage);

  void setFilter(HistoryFilter filter) => state = state.copyWith(filter: filter);

  void dismissCameraHelp() =>
      state = state.copyWith(cameraHelpDismissed: true);

  /// A fresh camera loss should surface the card again even if the last one
  /// was dismissed.
  void resetCameraHelp() =>
      state = state.copyWith(cameraHelpDismissed: false);
}

final workspaceViewProvider =
    NotifierProvider.family<WorkspaceViewController, WorkspaceViewState, String>(
  WorkspaceViewController.new,
);

/// The calibration's plan, pins and trajectories.
class WorkspaceDataController
    extends FamilyAsyncNotifier<LevelWorkspaceData, String> {
  @override
  Future<LevelWorkspaceData> build(String arg) {
    return ref.watch(planRepositoryProvider).fetchWorkspace(arg);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard<LevelWorkspaceData>(
      () => ref.read(planRepositoryProvider).fetchWorkspace(arg),
    );
  }
}

final workspaceDataProvider = AsyncNotifierProvider.family<
    WorkspaceDataController, LevelWorkspaceData, String>(
  WorkspaceDataController.new,
);
