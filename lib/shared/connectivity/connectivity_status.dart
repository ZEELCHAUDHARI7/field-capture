/// The app-wide connectivity state.
///
/// The prototype treats offline as a normal state, not an error state: eight
/// screens display this and the capture path never requires a round trip.
enum ConnectivityStatus {
  /// Connected, nothing outstanding.
  online('Online'),

  /// Connected and actively draining the upload queue.
  syncing('Online — syncing'),

  /// No signal. Captures continue; uploads park in the queue.
  offline('Offline');

  const ConnectivityStatus(this.label);

  /// The literal string the prototype renders in the pill.
  final String label;

  bool get isOffline => this == ConnectivityStatus.offline;
  bool get isSyncing => this == ConnectivityStatus.syncing;
}
