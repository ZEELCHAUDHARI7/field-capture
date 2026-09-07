/// How fresh a project's local copy is.
///
/// The prototype draws two icons on the project rows: a green check and a
/// grey refresh glyph. The names here are ASSUMED; the two visual states are not.
enum ProjectSyncState {
  /// Green check — local copy matches Asite.
  synced,

  /// Grey refresh — there is newer data on Asite, or nothing downloaded yet.
  stale,
}

/// A project the user can capture against.
class Project {
  const Project({
    required this.id,
    required this.reference,
    required this.name,
    required this.location,
    required this.calibrationsOffline,
    required this.syncState,
    this.lastSyncedAt,
  });

  /// Internal identifier used for routing.
  final String id;

  /// The human reference shown on the row — "PRJ-4821".
  final String reference;

  /// "Riverside Quarter — Tower B".
  final String name;

  /// "London".
  final String location;

  /// How many calibrations are already downloaded for offline use.
  final int calibrationsOffline;

  final ProjectSyncState syncState;

  /// The prototype's copy says rows carry a sync stamp, but none is drawn.
  /// ASSUMED: a relative timestamp under the offline count.
  final DateTime? lastSyncedAt;
}
