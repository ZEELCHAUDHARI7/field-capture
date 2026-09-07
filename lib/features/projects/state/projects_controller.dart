import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/connectivity/connectivity_controller.dart';
import '../../../shared/connectivity/connectivity_status.dart';
import '../data/projects_repository.dart';
import '../models/project.dart';

class ProjectsController extends AsyncNotifier<List<Project>> {
  @override
  Future<List<Project>> build() {
    // watch, not read, so a ProviderScope override of the repository (the real
    // Asite client, or a mock configured for QA) rebuilds this list.
    return ref.watch(projectsRepositoryProvider).fetchProjects();
  }

  /// Pull-to-refresh. Keeps the current list on screen while reloading, which
  /// is what "Pull to refresh project list" implies on the prototype.
  Future<void> refresh() async {
    final ConnectivityStatus connectivity =
        ref.read(connectivityControllerProvider);
    if (connectivity.isOffline) {
      // Offline is a normal state in this product, not an error. Keep the
      // cached list and say nothing — the pill already tells the story.
      return;
    }

    state = await AsyncValue.guard<List<Project>>(
      () => ref.read(projectsRepositoryProvider).fetchProjects(),
    );
  }
}

final projectsControllerProvider =
    AsyncNotifierProvider<ProjectsController, List<Project>>(
  ProjectsController.new,
);

/// Look one project up by id without refetching. Used by the calibration
/// screen for its app-bar title.
final projectByIdProvider = Provider.family<Project?, String>((ref, id) {
  final List<Project>? projects =
      ref.watch(projectsControllerProvider).valueOrNull;
  if (projects == null) return null;
  for (final Project project in projects) {
    if (project.id == id) return project;
  }
  return null;
});
