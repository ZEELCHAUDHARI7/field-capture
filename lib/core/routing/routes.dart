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
  static const String captureImage = '/capture/image';

  /// Phase 7 — the real guided sphere capture, replacing the mock sweep that
  /// used to live at `/capture/mobile`. One route for coaching, capture and
  /// review, because they are one activity and Back means the same thing in
  /// all three of them.
  static const String captureSphere = '/capture/sphere';

  // Phase 4 — sync and settings.
  static const String uploads = '/uploads';
  static const String settings = '/settings';

  /// Phase 7 — a captured sphere, open in the 360° viewer. Nested under the
  /// calibration because a panorama without the level it was taken on is as
  /// meaningless as a pin without its plan.
  static const String sphereViewer =
      '/calibration/:calibrationId/sphere/:captureId';

  // Phase 5 — 3D perspective.
  static const String perspective = '/calibration/:calibrationId/3d';
  static const String perspectiveWalk =
      '/calibration/:calibrationId/3d/:trajectoryId';

  /// Phase 6 — the demo console. Not a prototype screen: it exists to reach
  /// states the deck never draws a way into. Removed with the mocks.
  static const String demoControls = '/settings/demo';

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

  static String sphereViewerFor(String calibrationId, String captureId) =>
      '/calibration/$calibrationId/sphere/$captureId';
}
