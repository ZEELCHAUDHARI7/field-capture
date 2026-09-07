import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/project.dart';

/// The boundary a real Asite projects client will implement.
abstract interface class ProjectsRepository {
  Future<List<Project>> fetchProjects();
}

/// PHASE 1 MOCK.
///
/// Seeded with the prototype's own data so the built screen can be held next
/// to page 03 of the PDF for comparison.
///
/// The two flags exist so QA can reach the empty and error states, which the
/// prototype never draws. Flip them in a ProviderScope override or in
/// [projectsRepositoryProvider] below.
class MockProjectsRepository implements ProjectsRepository {
  MockProjectsRepository({
    this.latency = const Duration(milliseconds: 700),
    this.simulateEmpty = false,
    this.simulateError = false,
  });

  final Duration latency;
  final bool simulateEmpty;
  final bool simulateError;

  @override
  Future<List<Project>> fetchProjects() async {
    await Future<void>.delayed(latency);

    if (simulateError) {
      throw Exception('The site office server did not respond.');
    }
    if (simulateEmpty) return const <Project>[];

    final DateTime now = DateTime.now();
    return <Project>[
      Project(
        id: 'prj-4821',
        reference: 'PRJ-4821',
        name: 'Riverside Quarter — Tower B',
        location: 'London',
        calibrationsOffline: 3,
        syncState: ProjectSyncState.synced,
        lastSyncedAt: now.subtract(const Duration(minutes: 4)),
      ),
      Project(
        id: 'prj-5107',
        reference: 'PRJ-5107',
        name: 'Northfield Logistics Hub',
        location: 'Manchester',
        calibrationsOffline: 1,
        syncState: ProjectSyncState.stale,
        lastSyncedAt: now.subtract(const Duration(hours: 26)),
      ),
      Project(
        id: 'prj-4996',
        reference: 'PRJ-4996',
        name: "St Mary's Hospital Extension",
        location: 'Leeds',
        calibrationsOffline: 0,
        syncState: ProjectSyncState.stale,
        lastSyncedAt: null,
      ),
    ];
  }
}

final projectsRepositoryProvider =
    Provider<ProjectsRepository>((ref) => MockProjectsRepository());
