import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/screens/sign_in_screen.dart';
import '../../features/calibrations/screens/calibration_list_screen.dart';
import '../../features/capture/screens/image_capture_screen.dart';
import '../../features/capture/screens/mobile_capture_screen.dart';
import '../../features/capture/screens/recording_screen.dart';
import '../../features/demo/screens/demo_controls_screen.dart';
import '../../features/perspective/screens/perspective_walk_screen.dart';
import '../../features/perspective/screens/trajectory_picker_screen.dart';
import '../../features/plan/screens/level_workspace_screen.dart';
import '../../features/projects/screens/project_list_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/uploads/screens/upload_queue_screen.dart';
import 'routes.dart';

/// The app router.
///
/// The ten prototype routes, every one backed by a real screen, plus the two
/// Phase 6 additions the deck does not draw: the Image shutter (§C7) and the
/// demo console (see the README).
///
/// The ten were declared here from day one — the seven not yet built resolved
/// to a placeholder naming the phase that would deliver them, so no navigation
/// path in the app was ever a dead end and each phase only swapped a builder.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.signIn,
    routes: <RouteBase>[
      GoRoute(
        path: Routes.signIn,
        builder: (BuildContext context, GoRouterState state) =>
            const SignInScreen(),
      ),
      GoRoute(
        path: Routes.projects,
        builder: (BuildContext context, GoRouterState state) =>
            const ProjectListScreen(),
      ),
      GoRoute(
        path: Routes.calibrations,
        builder: (BuildContext context, GoRouterState state) =>
            CalibrationListScreen(
          projectId: state.pathParameters['projectId'] ?? '',
        ),
      ),

      GoRoute(
        path: Routes.workspace,
        builder: (BuildContext context, GoRouterState state) =>
            LevelWorkspaceScreen(
          calibrationId: state.pathParameters['calibrationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.captureWalk,
        builder: (BuildContext context, GoRouterState state) =>
            const RecordingScreen(),
      ),
      GoRoute(
        path: Routes.captureMobile,
        builder: (BuildContext context, GoRouterState state) =>
            const MobileCaptureScreen(),
      ),
      GoRoute(
        path: Routes.captureImage,
        builder: (BuildContext context, GoRouterState state) =>
            const ImageCaptureScreen(),
      ),
      GoRoute(
        path: Routes.uploads,
        builder: (BuildContext context, GoRouterState state) =>
            const UploadQueueScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.demoControls,
        builder: (BuildContext context, GoRouterState state) =>
            const DemoControlsScreen(),
      ),
      GoRoute(
        path: Routes.perspective,
        builder: (BuildContext context, GoRouterState state) =>
            TrajectoryPickerScreen(
          calibrationId: state.pathParameters['calibrationId'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.perspectiveWalk,
        builder: (BuildContext context, GoRouterState state) =>
            PerspectiveWalkScreen(
          calibrationId: state.pathParameters['calibrationId'] ?? '',
          trajectoryId: state.pathParameters['trajectoryId'] ?? '',
        ),
      ),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) =>
        _RouteNotFound(location: state.uri.toString()),
  );
});

class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound({required this.location});
  final String location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('No screen at $location',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(Routes.projects),
                child: const Text('Back to projects'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
