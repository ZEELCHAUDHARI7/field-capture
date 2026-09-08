import 'package:flutter/foundation.dart';

import 'plan_space.dart';

/// The three capture modes on the dock.
enum CaptureMode {
  video('Video', '360° video'),
  image('Image', '360° image'),
  mobile('Mobile Capture', 'Mobile 360°');

  const CaptureMode(this.label, this.mediaLabel);

  /// Dock label.
  final String label;

  /// How the mode is described in the upload queue and naming sheet.
  final String mediaLabel;

  /// Video and Image go through the 360° camera; Mobile Capture never needed
  /// it, which is why it stays enabled when the camera drops.
  bool get requiresCamera => this != CaptureMode.mobile;

  /// The token used in a capture name: `L03_Img_2026-07-03_13`.
  String get nameToken => switch (this) {
        CaptureMode.video => 'Walk',
        CaptureMode.image => 'Img',
        CaptureMode.mobile => 'Mobile',
      };
}

/// Anything pinned on the plan.
sealed class PlanMarker {
  const PlanMarker({
    required this.id,
    required this.at,
    required this.recordedAt,
  });

  final String id;
  final PlanPoint at;
  final DateTime recordedAt;
}

/// How far a Mobile Capture sphere has got through stitching.
///
/// A stitch takes up to a minute and runs behind the crew, so a capture point
/// is on the plan long before its panorama exists. This is what the pin draws
/// and what decides whether tapping it opens a viewer.
///
/// [none] is not a stage of the same process — it means this marker has no
/// panorama and never will. It is what the seeded mock captures and the
/// external-camera modes carry.
enum SphereStitchState { none, stitching, ready, failed }

/// A capture point — where a 360° image or mobile pano was taken.
///
/// Video walks are drawn as a [Trajectory] instead, since they have a path.
@immutable
class CaptureMarker extends PlanMarker {
  const CaptureMarker({
    required super.id,
    required super.at,
    required super.recordedAt,
    required this.name,
    required this.mode,
    this.sphereSessionId,
    this.panoramaPath,
    this.previewPath,
    this.stitch = SphereStitchState.none,
    this.reportJson,
    this.stitchError,
  });

  /// `L03_Img_2026-07-03_13`.
  final String name;

  final CaptureMode mode;

  /// The `sphere_view` session this came from, which is also the key the stitch
  /// queue tracks it by. Null for everything that is not a real sphere capture.
  final String? sphereSessionId;

  /// `StitchResult.equirectPath` — the full-resolution equirectangular JPEG,
  /// with its XMP GPano block already written. Null until the stitch lands.
  final String? panoramaPath;

  /// The 2048 px preview the pipeline writes first, so there is something to
  /// look at within seconds of the last shutter rather than after a minute.
  final String? previewPath;

  final SphereStitchState stitch;

  /// `StitchReport.toJson`, kept verbatim.
  ///
  /// Persisted rather than parsed into fields because the value of it is
  /// answering "why is this defect soft" months later, and a report that has to
  /// be modelled here would lose whatever the pipeline learns to measure next.
  final String? reportJson;

  /// Why the stitch failed, in the pipeline's own words. Only set for [failed].
  final String? stitchError;

  /// True when there is a file to open — the preview counts, since it is a
  /// complete panorama at a lower resolution rather than a partial one.
  bool get hasPanorama => panoramaPath != null || previewPath != null;

  /// The best file available to view: the full panorama, else the preview.
  String? get viewablePath => panoramaPath ?? previewPath;

  CaptureMarker copyWith({
    String? name,
    String? panoramaPath,
    String? previewPath,
    SphereStitchState? stitch,
    String? reportJson,
    String? stitchError,
    bool clearStitchError = false,
  }) {
    return CaptureMarker(
      id: id,
      at: at,
      recordedAt: recordedAt,
      name: name ?? this.name,
      mode: mode,
      sphereSessionId: sphereSessionId,
      panoramaPath: panoramaPath ?? this.panoramaPath,
      previewPath: previewPath ?? this.previewPath,
      stitch: stitch ?? this.stitch,
      reportJson: reportJson ?? this.reportJson,
      stitchError:
          clearStitchError ? null : (stitchError ?? this.stitchError),
    );
  }
}

/// Severity as drawn on the issue chips.
enum IssueSeverity { low, medium, high }

/// Category as drawn on the report sheet.
enum IssueCategory { access, safety, other }

/// How far an issue has travelled. The prototype names four states but draws
/// only two — see ASSUMPTIONS.md §B4.
enum IssueSyncState { local, queued, synced, assigned }

/// An issue raised against this calibration, pinned on the plan.
///
/// Phase 2 needs this only to draw the diamond pins and count the tab label.
/// The Site Issues list, detail sheet and report sheet arrive in Phase 4.
@immutable
class IssueMarker extends PlanMarker {
  const IssueMarker({
    required super.id,
    required super.at,
    required super.recordedAt,
    required this.title,
    required this.category,
    required this.severity,
    required this.syncState,
    this.assignee,
    this.hasPhoto = false,
  });

  final String title;
  final IssueCategory category;
  final IssueSeverity severity;
  final IssueSyncState syncState;

  /// "D. Okafor". Assignment happens in Asite Field; read-only here.
  final String? assignee;

  /// A photo is optional — only severity and category are required, because
  /// "speed matters on site".
  final bool hasPhoto;
}

/// Display labels, kept beside the enums so no widget spells them itself.
extension IssueCategoryLabel on IssueCategory {
  String get label => switch (this) {
        IssueCategory.access => 'Access',
        IssueCategory.safety => 'Safety',
        IssueCategory.other => 'Other',
      };
}

extension IssueSeverityLabel on IssueSeverity {
  String get label => switch (this) {
        IssueSeverity.low => 'Low',
        IssueSeverity.medium => 'Medium',
        IssueSeverity.high => 'High',
      };
}

extension IssueSyncStateLabel on IssueSyncState {
  /// The deck draws only Synced and Assigned; the other two follow §B4.
  String get label => switch (this) {
        IssueSyncState.local => 'On this device',
        IssueSyncState.queued => 'Queued',
        IssueSyncState.synced => 'Synced',
        IssueSyncState.assigned => 'Assigned',
      };
}
