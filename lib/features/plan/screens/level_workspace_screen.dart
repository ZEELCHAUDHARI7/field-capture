import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/instruction_banner.dart';
import '../../../core/widgets/pill_toggle.dart';
import '../../../core/widgets/segmented_toggle.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../../capture/models/capture_draft.dart';
import '../../capture/state/capture_flow_controller.dart';
import '../../capture/widgets/name_capture_sheet.dart';
import '../../capture/widgets/pin_mode_action_bar.dart';
import '../../issues/models/issue_draft.dart';
import '../../issues/state/issue_report_controller.dart';
import '../../issues/widgets/issues_tab.dart';
import '../../issues/widgets/report_issue_sheet.dart';
import '../../uploads/widgets/upload_queue_button.dart';
import '../models/plan_marker.dart';
import '../models/trajectory.dart';
import '../models/workspace_data.dart';
import '../state/workspace_controller.dart';
import '../widgets/camera_lost_card.dart';
import '../widgets/camera_status_bar.dart';
import '../widgets/capture_dock.dart';
import '../widgets/level_rail.dart';
import '../widgets/map_controls.dart';
import '../widgets/plan_canvas.dart';
import '../widgets/plan_view_controller.dart';
import '../widgets/workspace_tabs.dart';

/// Prototype screens 04–05, 07, 09–10, 12, 16, 21 — the Level Workspace.
///
/// The hub. Eleven of the prototype's twenty-one drawn states are states, tabs,
/// modes or filters of this one screen, which is why it is a single route with
/// an explicit state machine rather than eleven routes.
///
/// Phase 3 adds the pin modes: the chrome collapses, the plan takes the frame,
/// a blue banner says what is being asked for, and the dock is replaced by a
/// cancel/confirm pair. The capture flow itself lives in CaptureFlowController;
/// this screen only renders it.
class LevelWorkspaceScreen extends ConsumerStatefulWidget {
  const LevelWorkspaceScreen({super.key, required this.calibrationId});

  final String calibrationId;

  @override
  ConsumerState<LevelWorkspaceScreen> createState() =>
      _LevelWorkspaceScreenState();
}

class _LevelWorkspaceScreenState extends ConsumerState<LevelWorkspaceScreen> {
  final PlanViewController _plan = PlanViewController();
  bool _sheetOpen = false;
  bool _reportSheetOpen = false;

  @override
  void dispose() {
    _plan.dispose();
    super.dispose();
  }

  /// Navigation and modals are side effects of the flow, never of a tap. This
  /// keeps every screen consistent with the machine even when the user arrives
  /// by an unexpected route.
  void _onFlowChanged(CaptureFlow? previous, CaptureFlow next) {
    if (previous?.phase == next.phase) return;
    if (!next.ownedBy(widget.calibrationId) &&
        next.phase != CapturePhase.idle) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (next.phase) {
        case CapturePhase.naming:
          _openNamingSheet(next.draft!);
        case CapturePhase.recording:
          context.push(Routes.captureWalk);
        case CapturePhase.mobileSweep:
          context.push(Routes.captureMobile);
        case CapturePhase.shooting:
          context.push(Routes.captureImage);
        case CapturePhase.idle:
          if (previous?.phase == CapturePhase.saving) {
            _announceSaved(previous?.draft);
          }
        case CapturePhase.pinningStart:
        case CapturePhase.pinningWaypoint:
        case CapturePhase.pinningEnd:
        case CapturePhase.saving:
          break;
      }
    });
  }

  /// Same rule as the capture flow: the sheet is a side effect of the phase.
  void _onReportChanged(IssueReportFlow? previous, IssueReportFlow next) {
    if (previous?.phase == next.phase) return;
    if (!next.ownedBy(widget.calibrationId) &&
        next.phase != IssueReportPhase.idle) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (next.phase == IssueReportPhase.composing) {
        _openReportSheet();
      } else if (next.phase == IssueReportPhase.idle &&
          previous?.phase == IssueReportPhase.saving) {
        _announceIssueRaised(previous?.draft);
      }
    });
  }

  Future<void> _openReportSheet() async {
    if (_reportSheetOpen) return;
    _reportSheetOpen = true;
    await ReportIssueSheet.show(context);
    _reportSheetOpen = false;
    if (!mounted) return;

    // Swiped away rather than advanced — drop the draft.
    if (ref.read(issueReportProvider).phase == IssueReportPhase.composing) {
      ref.read(issueReportProvider.notifier).cancel();
    }
  }

  void _announceIssueRaised(IssueDraft? draft) {
    if (draft == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Issue raised: ${draft.title}')));
  }

  Future<void> _openNamingSheet(CaptureDraft draft) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    await NameCaptureSheet.show(context, draft);
    _sheetOpen = false;
    if (!mounted) return;

    // Dismissed by the scrim or the back gesture rather than confirmed —
    // "Cancel returns to the dock with nothing recorded".
    if (ref.read(captureFlowProvider).phase == CapturePhase.naming) {
      ref.read(captureFlowProvider.notifier).discard();
    }
  }

  void _announceSaved(CaptureDraft? draft) {
    if (draft == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${draft.name} saved — queued for upload'),
          action: SnackBarAction(
            label: 'Queue',
            onPressed: () => context.push(Routes.uploads),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<LevelWorkspaceData> data =
        ref.watch(workspaceDataProvider(widget.calibrationId));
    final WorkspaceViewState view =
        ref.watch(workspaceViewProvider(widget.calibrationId));
    final CameraSession camera = ref.watch(cameraSessionProvider);
    final CaptureFlow flow = ref.watch(captureFlowProvider);
    final IssueReportFlow report = ref.watch(issueReportProvider);

    ref.listen<CaptureFlow>(captureFlowProvider, _onFlowChanged);
    ref.listen<IssueReportFlow>(issueReportProvider, _onReportChanged);

    // A fresh camera loss brings the help card back even if the last one was
    // dismissed — the crew needs to know before they reach for Video.
    ref.listen<CameraSession>(cameraSessionProvider,
        (CameraSession? previous, CameraSession next) {
      if (previous is! CameraDisconnected && next is CameraDisconnected) {
        ref
            .read(workspaceViewProvider(widget.calibrationId).notifier)
            .resetCameraHelp();
      }
    });

    final bool capturePinning =
        flow.phase.isPinning && flow.ownedBy(widget.calibrationId);
    final bool issuePinning = report.isPinningOn(widget.calibrationId);
    final bool pinning = capturePinning || issuePinning;

    return PopScope(
      // In a pin mode, Back cancels the mode rather than leaving the level.
      canPop: !pinning,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (issuePinning) {
          // Back steps to the sheet rather than throwing the report away.
          ref.read(issueReportProvider.notifier).backToCompose();
          return;
        }
        final CaptureFlowController controller =
            ref.read(captureFlowProvider.notifier);
        if (flow.phase == CapturePhase.pinningWaypoint) {
          controller.cancelWaypoint();
        } else {
          controller.discard();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.chrome,
        appBar: FieldAppBar(
          title: data.valueOrNull?.levelName ?? 'Level',
          subtitle: data.valueOrNull?.projectName,
          actions: pinning
              ? const <Widget>[]
              : <Widget>[
                  IconButton(
                    onPressed: () => context.push(Routes.settings),
                    icon: const Icon(Icons.settings_outlined),
                    color: AppColors.onChrome,
                    iconSize: 22,
                    tooltip: 'Settings',
                  ),
                  UploadQueueButton(
                    onPressed: () => context.push(Routes.uploads),
                  ),
                ],
        ),
        body: data.when(
          loading: () => const _WorkspaceShell(
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          ),
          error: (Object error, StackTrace _) => _WorkspaceShell(
            child: ErrorStateView(
              title: 'Could not open this calibration',
              message: 'The plan bundle on this device could not be read. '
                  'Re-download it from the calibration list.',
              onRetry: () => ref
                  .read(workspaceDataProvider(widget.calibrationId).notifier)
                  .refresh(),
            ),
          ),
          data: (LevelWorkspaceData workspace) => _Body(
            workspace: workspace,
            view: view,
            camera: camera,
            flow: flow,
            report: report,
            plan: _plan,
            calibrationId: widget.calibrationId,
          ),
        ),
      ),
    );
  }
}

class _WorkspaceShell extends StatelessWidget {
  const _WorkspaceShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: AppColors.background, child: child);
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.workspace,
    required this.view,
    required this.camera,
    required this.flow,
    required this.report,
    required this.plan,
    required this.calibrationId,
  });

  final LevelWorkspaceData workspace;
  final WorkspaceViewState view;
  final CameraSession camera;
  final CaptureFlow flow;
  final IssueReportFlow report;
  final PlanViewController plan;
  final String calibrationId;

  bool get _pinning => flow.phase.isPinning && flow.ownedBy(calibrationId);
  bool get _issuePinning => report.isPinningOn(calibrationId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final WorkspaceViewController controller =
        ref.read(workspaceViewProvider(calibrationId).notifier);

    if (_issuePinning) {
      return _IssuePinModeBody(
        workspace: workspace,
        report: report,
        plan: plan,
      );
    }

    if (_pinning) {
      return _PinModeBody(
        workspace: workspace,
        flow: flow,
        plan: plan,
      );
    }

    return Column(
      children: <Widget>[
        const CameraStatusBar(),
        WorkspaceTabs(
          selected: view.tab,
          issueCount: workspace.issues.length,
          onChanged: controller.selectTab,
        ),
        Expanded(
          child: switch (view.tab) {
            WorkspaceTab.capture => _CaptureTab(
                workspace: workspace,
                view: view,
                camera: camera,
                plan: plan,
                calibrationId: calibrationId,
              ),
            WorkspaceTab.issues => IssuesTab(workspace: workspace),
          },
        ),
        CaptureDock(
          cameraConnected: camera.isConnected,
          onSelect: (CaptureMode mode) => _beginCapture(ref, mode),
          onBlocked: (CaptureMode mode) => _refuseCapture(context, ref, mode),
        ),
      ],
    );
  }

  /// "Every capture is named before it starts." The dock opens the naming
  /// sheet; the flow controller drives everything after it.
  void _beginCapture(WidgetRef ref, CaptureMode mode) {
    ref.read(captureFlowProvider.notifier).beginNaming(
          mode: mode,
          calibrationId: workspace.calibrationId,
          levelCode: workspace.levelCode,
          existingNames: <String>[
            for (final CaptureMarker c in workspace.captures) c.name,
            for (final Trajectory t in workspace.trajectories) t.name,
          ],
        );
  }

  /// "Capture modes that need the camera stay visible but refuse politely."
  void _refuseCapture(BuildContext context, WidgetRef ref, CaptureMode mode) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${mode.label} needs the 360° camera. Mobile Capture still works.',
          ),
          action: SnackBarAction(
            label: 'Reconnect',
            onPressed: ref.read(cameraSessionProvider.notifier).reconnect,
          ),
        ),
      );
  }
}

/// Prototype screens 07, 09 and 10 — the three pin modes.
///
/// The chrome collapses to a banner and an action bar; the plan takes
/// everything else. Tapping drops a crosshair, and only the confirm button
/// commits it — "so a mis-tap costs nothing".
class _PinModeBody extends ConsumerWidget {
  const _PinModeBody({
    required this.workspace,
    required this.flow,
    required this.plan,
  });

  final LevelWorkspaceData workspace;
  final CaptureFlow flow;
  final PlanViewController plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CaptureFlowController controller =
        ref.read(captureFlowProvider.notifier);
    final CaptureDraft draft = flow.draft!;
    final bool hasPin = draft.provisionalPin != null;

    return Column(
      children: <Widget>[
        const CameraStatusBar(),
        InstructionBanner(
          message: _bannerFor(flow.phase, draft),
          recording: flow.phase == CapturePhase.pinningWaypoint,
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: PlanCanvas(
                  controller: plan,
                  document: workspace.document,
                  captures: workspace.captures,
                  issues: workspace.issues,
                  trajectories: workspace.trajectories,
                  showCoverage: false,
                  mutedIds: const <String>{},
                  onPlanTap: controller.placeProvisionalPin,
                  provisionalPin: draft.provisionalPin,
                  liveTrajectory: draft.liveTrajectory,
                ),
              ),
              Positioned(
                right: AppSizes.md,
                top: 0,
                bottom: 0,
                child: Center(child: MapControls(controller: plan)),
              ),
            ],
          ),
        ),
        _actionBarFor(flow.phase, draft, hasPin, controller),
      ],
    );
  }

  String _bannerFor(CapturePhase phase, CaptureDraft draft) {
    switch (phase) {
      case CapturePhase.pinningStart:
        // Only the video line is drawn in the prototype; the other two follow
        // its shape. ASSUMPTIONS.md §G2.
        return switch (draft.mode) {
          CaptureMode.video =>
            'Zoom in and tap the exact point where recording begins',
          CaptureMode.image =>
            'Zoom in and tap the point where the 360° image is taken',
          CaptureMode.mobile =>
            'Zoom in and tap the point where the sweep is taken',
        };
      case CapturePhase.pinningWaypoint:
        return 'Recording continues — tap your current position to drop '
            'waypoint ${draft.nextWaypointNumber}';
      case CapturePhase.pinningEnd:
        return 'Walk finished — tap the point where you stopped';
      default:
        return '';
    }
  }

  Widget _actionBarFor(
    CapturePhase phase,
    CaptureDraft draft,
    bool hasPin,
    CaptureFlowController controller,
  ) {
    switch (phase) {
      case CapturePhase.pinningStart:
        return PinModeActionBar(
          cancelLabel: 'Cancel',
          onCancel: controller.discard,
          confirmLabel: switch (draft.mode) {
            CaptureMode.video => 'Start Walking',
            CaptureMode.image => 'Capture image',
            CaptureMode.mobile => 'Start sweep',
          },
          onConfirm: hasPin ? controller.confirmStartPin : null,
        );

      case CapturePhase.pinningWaypoint:
        // The prototype draws only the single "no waypoint" button, because it
        // draws the moment before a pin is placed. Once one is, a confirm is
        // needed — ASSUMPTIONS.md §G8.
        if (!hasPin) {
          return PinModeActionBar.single(
            confirmLabel: 'Back to recording — no waypoint',
            onConfirm: controller.cancelWaypoint,
            showRecordingDot: true,
          );
        }
        return PinModeActionBar(
          cancelLabel: 'No waypoint',
          onCancel: controller.cancelWaypoint,
          confirmLabel: 'Drop waypoint ${draft.nextWaypointNumber}',
          onConfirm: controller.confirmWaypoint,
        );

      case CapturePhase.pinningEnd:
        return PinModeActionBar(
          cancelLabel: 'Discard',
          onCancel: controller.discard,
          confirmLabel: 'Save capture',
          onConfirm: hasPin ? controller.confirmEndPin : null,
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

class _CaptureTab extends ConsumerWidget {
  const _CaptureTab({
    required this.workspace,
    required this.view,
    required this.camera,
    required this.plan,
    required this.calibrationId,
  });

  final LevelWorkspaceData workspace;
  final WorkspaceViewState view;
  final CameraSession camera;
  final PlanViewController plan;
  final String calibrationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final WorkspaceViewController controller =
        ref.read(workspaceViewProvider(calibrationId).notifier);

    final bool showAll = view.filter == HistoryFilter.all;
    final DateTime now = DateTime.now();

    bool isToday(DateTime moment) =>
        moment.year == now.year &&
        moment.month == now.month &&
        moment.day == now.day;

    final List<CaptureMarker> captures = showAll
        ? workspace.captures
        : workspace.captures
            .where((CaptureMarker c) => isToday(c.recordedAt))
            .toList(growable: false);

    final List<Trajectory> trajectories = showAll
        ? workspace.trajectories
        : workspace.trajectories
            .where((Trajectory t) => isToday(t.recordedAt))
            .toList(growable: false);

    // With the All filter on, anything from an earlier visit is drawn faded
    // "so today reads first".
    final Set<String> muted = <String>{
      for (final CaptureMarker c in captures)
        if (!isToday(c.recordedAt)) c.id,
      for (final Trajectory t in trajectories)
        if (!isToday(t.recordedAt)) t.id,
    };

    final bool showCameraHelp =
        camera is CameraDisconnected && !view.cameraHelpDismissed;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: PlanCanvas(
            controller: plan,
            document: workspace.document,
            captures: captures,
            issues: workspace.issues,
            trajectories: trajectories,
            showCoverage: view.showCoverage,
            mutedIds: muted,
            onIssueTap: (IssueMarker issue) =>
                _showIssuePreview(context, issue),
            onCaptureTap: (CaptureMarker capture) =>
                _showCapturePreview(context, capture),
          ),
        ),

        // Top-left: coverage toggle and history filter. Top-right: 3D.
        Positioned(
          left: AppSizes.md,
          right: AppSizes.md,
          top: AppSizes.md,
          child: Row(
            children: <Widget>[
              PillToggle(
                label: 'Coverage',
                icon: view.showCoverage
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                active: view.showCoverage,
                onPressed: controller.toggleCoverage,
              ),
              const SizedBox(width: AppSizes.sm),
              Flexible(
                child: SegmentedToggle<HistoryFilter>(
                  values: HistoryFilter.values,
                  selected: view.filter,
                  labelOf: (HistoryFilter f) => f.label,
                  onChanged: controller.setFilter,
                ),
              ),
              const Spacer(),
              PillToggle(
                label: '3D',
                icon: Icons.view_in_ar_outlined,
                onPressed: workspace.hasModel
                    ? () => context.push(
                          Routes.perspectiveFor(workspace.calibrationId),
                        )
                    : () => _noModel(context),
              ),
            ],
          ),
        ),

        // Left: level rail, clear of the thumb arc.
        Positioned(
          left: AppSizes.md,
          top: 0,
          bottom: 0,
          child: Center(
            child: LevelRail(
              levels: workspace.levels,
              currentCalibrationId: workspace.calibrationId,
              onSelect: (WorkspaceLevel level) =>
                  context.replace(Routes.workspaceFor(level.calibrationId)),
              onBlocked: (WorkspaceLevel level) =>
                  _levelNotDownloaded(context, level),
            ),
          ),
        ),

        // Right: zoom controls.
        Positioned(
          right: AppSizes.md,
          top: 0,
          bottom: 0,
          child: Center(child: MapControls(controller: plan)),
        ),

        if (showCameraHelp)
          Positioned(
            left: AppSizes.md,
            right: AppSizes.md,
            top: 60,
            child: CameraLostCard(
              reconnecting: camera is CameraReconnecting,
              onReconnect: ref.read(cameraSessionProvider.notifier).reconnect,
              onDismiss: controller.dismissCameraHelp,
            ),
          ),
      ],
    );
  }

  void _levelNotDownloaded(BuildContext context, WorkspaceLevel level) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${level.name} is not downloaded to this device.'),
        ),
      );
  }

  void _noModel(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('This level has no 3D model yet.')),
      );
  }

  /// A one-line read-out so a tapped pin says something. The issue detail
  /// sheet and the capture preview are Phase 4.
  void _showIssuePreview(BuildContext context, IssueMarker issue) {
    final String reference = workspace.document.grid.referenceFor(issue.at);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('${issue.title} · grid $reference')),
      );
  }

  void _showCapturePreview(BuildContext context, CaptureMarker capture) {
    final String reference = workspace.document.grid.referenceFor(capture.at);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('${capture.name} · grid $reference')),
      );
  }
}

/// The pin step of Report an issue.
///
/// The prototype contradicts itself here: "Next — pin location" implies a
/// required step, while the same page says "the pin defaults to the current
/// plan centre if not placed". Both are honoured — the step always happens, but
/// placing a crosshair is optional and Save is never disabled.
/// ASSUMPTIONS.md §H1.
class _IssuePinModeBody extends ConsumerWidget {
  const _IssuePinModeBody({
    required this.workspace,
    required this.report,
    required this.plan,
  });

  final LevelWorkspaceData workspace;
  final IssueReportFlow report;
  final PlanViewController plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IssueReportController controller =
        ref.read(issueReportProvider.notifier);
    final IssueDraft draft = report.draft!;

    return Column(
      children: <Widget>[
        const CameraStatusBar(),
        InstructionBanner(
          message: draft.pin == null
              ? 'Tap where the issue is — or save to pin it at the centre '
                  'of the plan'
              : 'Grid ${workspace.document.grid.referenceFor(draft.pin!)} — '
                  'tap again to move it',
          icon: Icons.warning_amber_rounded,
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: PlanCanvas(
                  controller: plan,
                  document: workspace.document,
                  captures: workspace.captures,
                  issues: workspace.issues,
                  trajectories: workspace.trajectories,
                  showCoverage: false,
                  mutedIds: const <String>{},
                  onPlanTap: controller.placePin,
                  provisionalPin: draft.pin,
                ),
              ),
              Positioned(
                right: AppSizes.md,
                top: 0,
                bottom: 0,
                child: Center(child: MapControls(controller: plan)),
              ),
            ],
          ),
        ),
        PinModeActionBar(
          cancelLabel: 'Back',
          onCancel: controller.backToCompose,
          confirmLabel: 'Save issue',
          onConfirm: () => controller.save(workspace.document),
        ),
      ],
    );
  }
}
