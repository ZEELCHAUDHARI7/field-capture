import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connectivity_status.dart';

/// Single source of truth for connectivity, read by every screen that shows
/// the status pill.
///
/// PHASE 1 IS MOCK. There is no `connectivity_plus` dependency yet — the
/// prototype gives no requirement beyond "show three states", and adding a
/// platform plugin before it is needed would violate the no-unnecessary-
/// dependencies rule. Phase 4 swaps the body of this class for a real
/// listener; no screen changes.
class ConnectivityController extends Notifier<ConnectivityStatus> {
  @override
  ConnectivityStatus build() => ConnectivityStatus.syncing;

  /// Test and demo hook — lets QA walk every screen through all three states
  /// without a real network.
  void setStatus(ConnectivityStatus status) => state = status;

  void cycle() {
    state = switch (state) {
      ConnectivityStatus.online => ConnectivityStatus.syncing,
      ConnectivityStatus.syncing => ConnectivityStatus.offline,
      ConnectivityStatus.offline => ConnectivityStatus.online,
    };
  }
}

final NotifierProvider<ConnectivityController, ConnectivityStatus>
    connectivityControllerProvider =
    NotifierProvider<ConnectivityController, ConnectivityStatus>(
  ConnectivityController.new,
);
