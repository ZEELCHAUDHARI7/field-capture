import 'package:flutter/foundation.dart';

import '../../plan/models/plan_marker.dart';
import '../../plan/models/plan_space.dart';

/// Where a report is in its short life.
///
///   idle ──begin──▶ composing ──next──▶ pinning ──save──▶ saving ──▶ idle
///            ▲                              │
///            └────────── back ──────────────┘
enum IssueReportPhase {
  idle,

  /// The "Report a site issue" sheet is open.
  composing,

  /// The plan is asking where the issue is.
  pinning,

  /// Writing to the calibration's local store.
  saving;

  bool get isActive => this != IssueReportPhase.idle;
}

/// Which of the two buttons on the sheet attached the photo.
///
/// The deck draws "Phone photo" and "360° camera still" side by side and gives
/// neither a capture flow (ASSUMPTIONS.md §H2). They were wired to the same
/// no-op, so the two buttons were indistinguishable once tapped. Recording the
/// source keeps them honest — and a 360° still is unavailable when the camera
/// is, the same way the capture dock refuses.
enum IssuePhoto {
  phone('Phone photo'),
  camera360('360° camera still');

  const IssuePhoto(this.label);

  final String label;
}

/// The issue being raised.
///
/// "Raising an issue is a short sheet: title, category, severity, optional
/// photo and a pin. Everything else is inferred from context."
@immutable
class IssueDraft {
  const IssueDraft({
    required this.calibrationId,
    this.title = '',
    this.category = IssueCategory.access,
    this.severity = IssueSeverity.medium,
    this.photo,
    this.pin,
  });

  final String calibrationId;
  final String title;

  /// Access is pre-selected in the prototype.
  final IssueCategory category;

  /// Medium is pre-selected in the prototype.
  final IssueSeverity severity;

  /// Which button attached it, or null for none. Optional — only title,
  /// category and severity are required: "speed matters on site".
  final IssuePhoto? photo;

  bool get hasPhoto => photo != null;

  /// Null means the user never tapped the plan, and the pin falls back to the
  /// centre of it. See ASSUMPTIONS.md §H1.
  final PlanPoint? pin;

  /// The only gate on "Next — pin location".
  bool get canAdvance => title.trim().isNotEmpty;

  IssueDraft copyWith({
    String? title,
    IssueCategory? category,
    IssueSeverity? severity,
    IssuePhoto? photo,
    bool clearPhoto = false,
    PlanPoint? pin,
  }) {
    return IssueDraft(
      calibrationId: calibrationId,
      title: title ?? this.title,
      category: category ?? this.category,
      severity: severity ?? this.severity,
      photo: clearPhoto ? null : (photo ?? this.photo),
      pin: pin ?? this.pin,
    );
  }
}

@immutable
class IssueReportFlow {
  const IssueReportFlow({required this.phase, this.draft});

  const IssueReportFlow.idle()
      : phase = IssueReportPhase.idle,
        draft = null;

  final IssueReportPhase phase;
  final IssueDraft? draft;

  bool ownedBy(String calibrationId) =>
      draft != null && draft!.calibrationId == calibrationId;

  bool isPinningOn(String calibrationId) =>
      phase == IssueReportPhase.pinning && ownedBy(calibrationId);
}
