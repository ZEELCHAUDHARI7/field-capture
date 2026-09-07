import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/screens/sign_in_screen.dart';
import '../../features/calibrations/screens/calibration_list_screen.dart';
import '../../features/capture/screens/mobile_capture_screen.dart';
import '../../features/capture/screens/recording_screen.dart';
import '../../features/placeholders/placeholder_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/uploads/screens/upload_queue_screen.dart';
import '../../features/plan/screens/level_workspace_screen.dart';
import '../../features/projects/screens/project_list_screen.dart';
import 'routes.dart';

/// The app router.
///
/// All ten routes are declared here from day one. Seven resolve to a
/// PlaceholderScreen naming the phase that will build them, so no navigation
/// path in the app is a dead end and later phases only swap a builder.
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

      // ---------------------------------------------------------------------
      // Phase 2 onwards. Declared now so links resolve and the shape of the
      // app is visible in one file.
      // ---------------------------------------------------------------------
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
        path: Routes.perspective,
        builder: (BuildContext context, GoRouterState state) =>
            const PlaceholderScreen(
          title: '3D Perspective',
          subtitle: 'Movement bound to trajectories',
          phase: 'Phase 5',
          prototypePages: 'p. 14',
          summary: 'Pick a recorded walk to fly. Held back deliberately: the '
              'prototype never states the model source or format, so this '
              'phase starts with a spike rather than a screen.',
        ),
      ),
      GoRoute(
        path: Routes.perspectiveWalk,
        builder: (BuildContext context, GoRouterState state) =>
            const PlaceholderScreen(
          title: '3D Perspective',
          subtitle: 'Walk the trajectory',
          phase: 'Phase 5',
          prototypePages: 'pp. 15–16',
          summary: 'Scrub along the recorded walk at eye height, with the mini '
              'plan for orientation and a draggable Compare wipe between the '
              'design model and the captured imagery.',
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
