/// Every route in the application, declared up front.
///
/// The prototype draws 21 states, but only 10 of them are routes. Eleven are
/// tabs, sheets, pin modes or data-driven variants of the Level Workspace.
/// Keeping those out of the router is the central architecture decision — see
/// the Phase 0 teardown.
///
/// Routes not yet implemented resolve to a PlaceholderScreen that names the
/// phase which will deliver them, so navigation is never a dead end.
abstract final class Routes {
  // Phase 1 — implemented.
  static const String signIn = '/signin';
  static const String projects = '/projects';
  static const String calibrations = '/projects/:projectId';

  // Phase 2 — the hub.
  static const String workspace = '/calibration/:calibrationId';

  // Phase 3 — capture.
  static const String captureWalk = '/capture/walk';
  static const String captureMobile = '/capture/mobile';

  // Phase 4 — sync and settings.
  static const String uploads = '/uploads';
  static const String settings = '/settings';

  // Phase 5 — 3D perspective.
  static const String perspective = '/calibration/:calibrationId/3d';
  static const String perspectiveWalk =
      '/calibration/:calibrationId/3d/:trajectoryId';

  // ---------------------------------------------------------------------------
  // Path builders. Screens must use these rather than interpolating strings,
  // so a route rename is a single-file change.
  // ---------------------------------------------------------------------------

  static String calibrationsFor(String projectId) => '/projects/$projectId';

  static String workspaceFor(String calibrationId) =>
      '/calibration/$calibrationId';

  static String perspectiveFor(String calibrationId) =>
      '/calibration/$calibrationId/3d';

  static String perspectiveWalkFor(String calibrationId, String trajectoryId) =>
      '/calibration/$calibrationId/3d/$trajectoryId';
}
