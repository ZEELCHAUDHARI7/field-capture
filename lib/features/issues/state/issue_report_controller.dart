import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connectivity/connectivity_controller.dart';
import '../../../shared/connectivity/connectivity_status.dart';
import '../../plan/data/plan_repository.dart';
import '../../plan/models/plan_document.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/state/workspace_controller.dart';
import '../models/issue_draft.dart';

/// Owns the Report an issue flow.
///
/// Kept separate from CaptureFlowController rather than merged into it: the two
/// share a pin mode on screen but nothing else, and folding them together would
/// mean touching a state machine that Phase 3 has tests for.
class IssueReportController extends Notifier<IssueReportFlow> {
  @override
  IssueReportFlow build() => const IssueReportFlow.idle();

  /// The "Report an issue" button under the issue list.
  void begin(String calibrationId) {
    if (state.phase.isActive) return;
    state = IssueReportFlow(
      phase: IssueReportPhase.composing,
      draft: IssueDraft(calibrationId: calibrationId),
    );
  }

  void setTitle(String title) => _patch((IssueDraft d) => d.copyWith(title: title));

  void setCategory(IssueCategory category) =>
      _patch((IssueDraft d) => d.copyWith(category: category));

  void setSeverity(IssueSeverity severity) =>
      _patch((IssueDraft d) => d.copyWith(severity: severity));

  /// PHASE 4 MOCK. Both photo buttons record that a photo was attached without
  /// opening a camera — there is no camera integration, and the prototype
  /// draws no capture step for either button. ASSUMPTIONS.md §H2.
  void attachPhoto() => _patch((IssueDraft d) => d.copyWith(hasPhoto: true));

  /// "Next — pin location".
  void confirmCompose() {
    final IssueDraft? draft = state.draft;
    if (draft == null || state.phase != IssueReportPhase.composing) return;
    if (!draft.canAdvance) return;

    state = IssueReportFlow(
      phase: IssueReportPhase.pinning,
      draft: draft.copyWith(title: draft.title.trim()),
    );
  }

  void placePin(PlanPoint point) {
    final IssueDraft? draft = state.draft;
    if (draft == null || state.phase != IssueReportPhase.pinning) return;
    state = IssueReportFlow(phase: state.phase, draft: draft.copyWith(pin: point));
  }

  /// Saves the issue, pinning it where the user tapped — or at the centre of
  /// the plan if they never did, which is what the prototype's copy specifies.
  Future<void> save(PlanDocument document) async {
    final IssueDraft? draft = state.draft;
    if (draft == null || state.phase != IssueReportPhase.pinning) return;

    final PlanPoint at = draft.pin ??
        PlanPoint(document.widthMetres / 2, document.heightMetres / 2);

    state = IssueReportFlow(phase: IssueReportPhase.saving, draft: draft);

    // A new issue is local until the queue drains it. The two states the deck
    // never draws finally have a source — ASSUMPTIONS.md §B4.
    final ConnectivityStatus connectivity =
        ref.read(connectivityControllerProvider);
    final IssueSyncState syncState = connectivity.isOffline
        ? IssueSyncState.local
        : IssueSyncState.queued;

    await ref.read(planRepositoryProvider).saveIssue(
          draft.calibrationId,
          IssueMarker(
            id: 'iss-${DateTime.now().microsecondsSinceEpoch}',
            at: at,
            recordedAt: DateTime.now(),
            title: draft.title,
            category: draft.category,
            severity: draft.severity,
            syncState: syncState,
            hasPhoto: draft.hasPhoto,
          ),
        );

    ref.invalidate(workspaceDataProvider(draft.calibrationId));
    state = const IssueReportFlow.idle();
  }

  /// Back out of the pin step to fix the title or severity.
  void backToCompose() {
    final IssueDraft? draft = state.draft;
    if (draft == null || state.phase != IssueReportPhase.pinning) return;
    state = IssueReportFlow(phase: IssueReportPhase.composing, draft: draft);
  }

  void cancel() => state = const IssueReportFlow.idle();

  void _patch(IssueDraft Function(IssueDraft) update) {
    final IssueDraft? draft = state.draft;
    if (draft == null) return;
    state = IssueReportFlow(phase: state.phase, draft: update(draft));
  }
}

final issueReportProvider =
    NotifierProvider<IssueReportController, IssueReportFlow>(
  IssueReportController.new,
);
