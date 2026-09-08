import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_flow.dart';
import 'device_report_page.dart';
import 'report_page.dart';
import 'simulate_kill.dart';
import 'stations.dart';
import 'viewer_page.dart';

void main() => runApp(const SphereViewExampleApp());

/// The `sphere_view` demo.
///
/// One screen, three actions, no chrome. It exists to prove the package works
/// end to end and to show a future integrator exactly how to call it, and it
/// demonstrates seven things:
///
/// 1. **capture** — the full guided session, including the pre-capture pivot
///    coaching and the metering sweep (`CaptureFlow.start`);
/// 2. **the background queue** — capture two or three spheres back to back
///    without waiting; every row shows `queued → stitching N% → ready`
///    (`StationStore`, and the fact that `CaptureFlow` awaits no stitch);
/// 3. **view** — tap a ready row for the viewer, with gyro look toggleable
///    (`ViewerPage`);
/// 4. **report** — tap the metrics line for the whole `StitchReport`, every
///    number said twice (`ReportPage`);
/// 5. **export** — the share sheet, so the equirect can be opened in Google
///    Photos and criterion S10 checked by somebody else's parser
///    (`ViewerPage`);
/// 6. **device report** — the capability probe plus a measured burst
///    (`DeviceReportPage`);
/// 7. **resume after a kill** — `SimulateKillButton` ends the process; reopen
///    and a half-finished capture is a station you can resume.
///
/// Deliberately absent, because they belong to a consuming app and not to this
/// package: a plan viewer, PDF export, a map, authentication, a backend.
class SphereViewExampleApp extends StatelessWidget {
  /// Creates the demo app.
  ///
  /// [store] exists for widget tests, which need the demo pointed at a
  /// temporary directory rather than at the device's documents folder.
  const SphereViewExampleApp({super.key, this.store});

  /// An already-opened store, or `null` to open the app's own.
  final StationStore? store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sphere_view demo',
      theme: ThemeData.dark(useMaterial3: true),
      home: StationListPage(store: store),
    );
  }
}

/// The demo's only screen: the station list.
class StationListPage extends StatefulWidget {
  /// Creates the station list.
  const StationListPage({super.key, this.store});

  /// An already-opened store, or `null` to open the app's own.
  final StationStore? store;

  @override
  State<StationListPage> createState() => _StationListPageState();
}

class _StationListPageState extends State<StationListPage> {
  StationStore? _store;
  String? _error;

  @override
  void initState() {
    super.initState();
    final provided = widget.store;
    if (provided != null) {
      // Already opened by whoever supplied it. The widget tests have to do the
      // opening themselves, inside `WidgetTester.runAsync`, because a
      // `testWidgets` body runs on a fake clock that real file I/O never
      // completes against.
      _store = provided;
    } else {
      unawaited(_open());
    }
  }

  /// Cold start, which is also the recovery path.
  ///
  /// There is no separate "did we crash" branch anywhere in this app, and there
  /// should not be: `StitchQueue.load` repairs an entry a kill left in
  /// `running`, and a capture row with a bundle but no queue entry *is* an
  /// interrupted capture. Recovery that only runs down a special path is
  /// recovery that rots.
  Future<void> _open() async {
    try {
      final store = await StationStore.forApp();
      await store.load();
      await store.start();
      if (!mounted) return;
      setState(() => _store = store);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    if (widget.store == null) _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('sphere_view demo'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: Center(child: SimulateKillButton(label: 'Kill')),
          ),
        ],
      ),
      body: switch ((store, _error)) {
        (_, final String error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error, textAlign: TextAlign.center),
          ),
        ),
        (final StationStore s, _) => _Body(store: s),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.store});

  final StationStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final stations = store.stations;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => CaptureFlow.start(context, store),
                  icon: const Icon(Icons.panorama_photosphere),
                  label: const Text('Capture a 360°'),
                ),
              ),
            ),
            if (store.pauseReason case final reason?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  reason,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const _SectionHeader('Captured'),
            Expanded(
              child: stations.isEmpty
                  ? const _Empty()
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: stations.length,
                      itemBuilder: (context, index) => _StationRow(
                        store: store,
                        station: stations[index],
                      ),
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DeviceReportPage(),
                          ),
                        ),
                        child: const Text('Device report'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            stations.isEmpty ? null : () => _confirmClear(context),
                        child: const Text('Clear'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear everything?'),
        content: const Text(
          'Deletes every capture bundle, every panorama and the queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (go == true) await store.clear();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Text(text, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(width: 12),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'No stations yet.\n\n'
        'Capture one, then capture another without waiting — the first sphere '
        'stitches while you shoot the second.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

/// One row: thumbnail, name, and where it has got to.
///
/// The status line is the demo's most load-bearing sentence. `queued`,
/// `stitching 42%` and `ready` have to be visibly different and have to move on
/// their own, because the failure this is watching for — a queue that only
/// drains when the UI happens to poke it — looks exactly like a row that says
/// `queued` forever.
class _StationRow extends StatelessWidget {
  const _StationRow({required this.store, required this.station});

  final StationStore store;
  final Station station;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = store.phaseOf(station);
    final result = store.resultFor(station);
    final progress = store.progressFor(station);
    final entry = store.entryFor(station);

    // Openable as soon as *a* panorama exists, which the fast preview satisfies
    // before the full-resolution pass finishes. The phase stays honest about
    // whether the station is actually done.
    final viewable = store.viewablePathFor(station);
    final previewOnly = store.isPreviewOnly(station);
    final ready = viewable != null;
    // The panorama the latest result actually points at, **not**
    // `station.outputPath`.
    //
    // Those are the same file once the full-resolution pass has finished, and
    // different before it. A station becomes openable the moment the fast
    // preview lands — that is the entire point of the preview — and the preview
    // is written to its own path so a failure in the full pass cannot destroy
    // it. Opening `station.outputPath` at that moment asks for a file that does
    // not exist yet, which is exactly the
    // `PathNotFoundException ... station-1-<id>.jpg (errno = 2)` this produced.
    final panorama = File(viewable ?? station.outputPath);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Thumbnail(
            file: ready && panorama.existsSync() ? panorama : null,
            phase: phase,
            progress: progress?.fraction,
            onTap: ready
                ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ViewerPage(
                        file: panorama,
                        title: station.label,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(station.label, style: theme.textTheme.titleSmall),
                Text(
                  _statusLine(phase, progress, result, entry),
                  style: theme.textTheme.bodySmall,
                ),
                // Said plainly, because the sphere is about to change under the
                // operator: they can open it now, and it will sharpen when the
                // full-resolution pass lands. Unexplained, that reads as a bug.
                if (previewOnly)
                  Text(
                    'Preview ready — open it now; the full-resolution version '
                    'is still stitching.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                // Gated on the *final* result, not on `ready`: `ready` is now
                // also true when only the fast preview exists, and a report
                // quoting a 4096-wide preview as this station's measured quality
                // would be wrong.
                if (result != null)
                  // Flow 4's entry point. A tap target on the metrics rather
                  // than a button, because the metrics *are* the affordance:
                  // anyone who wonders what "0.42 px" means is exactly the
                  // person the report screen is for.
                  InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReportPage(
                          title: station.label,
                          result: result,
                          elapsedNote: station.bundleDeleted
                              ? 'Capture bundle deleted — this stitch met its '
                                    'quality targets.'
                              : 'Capture bundle kept, so this station can be '
                                    're-stitched after a pipeline improvement '
                                    'without going back to site.',
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '${_metricsLine(result)}  ›',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: result.report.meetsQualityTargets
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (phase == StationPhase.failed &&
                    store.errorFor(station) != null)
                  Text(
                    store.errorFor(station)!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          _RowAction(store: store, station: station, phase: phase),
        ],
      ),
    );
  }

  static String _statusLine(
    StationPhase phase,
    StitchProgress? progress,
    StitchResult? result,
    StitchQueueEntry? entry,
  ) {
    final interruptions = entry == null || entry.interruptions == 0
        ? ''
        : ' · interrupted ${entry.interruptions}×';
    return switch (phase) {
      StationPhase.empty => 'nothing captured yet',
      StationPhase.interrupted => 'capture interrupted — resume it',
      StationPhase.queued => 'queued$interruptions',
      StationPhase.stitching =>
        'stitching ${((progress?.fraction ?? 0) * 100).round()}%'
            '${progress == null ? '' : ' · ${progress.stage.name}'}'
            '$interruptions',
      StationPhase.ready => result == null
          ? 'ready'
          : '${result.width}×${result.height} · ready',
      StationPhase.failed => 'failed',
    };
  }

  static String _metricsLine(StitchResult result) {
    final report = result.report;
    return 'S1 ${report.rmsReprojectionErrorPx.toStringAsFixed(2)} px · '
        'coverage ${(report.coverageFraction * 100).toStringAsFixed(0)}% · '
        '${report.warnings.length} warning'
        '${report.warnings.length == 1 ? '' : 's'}';
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.file,
    required this.phase,
    required this.progress,
    required this.onTap,
  });

  final File? file;
  final StationPhase phase;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = this.file;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 54,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: file != null
            // `cacheWidth` matters here rather than being a nicety: the source
            // is 6144 px wide and a list of full-resolution decodes is how a
            // tablet runs out of memory looking at a list.
            ? Image.file(file, fit: BoxFit.cover, cacheWidth: 216)
            : Center(
                child: switch (phase) {
                  StationPhase.stitching => SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: progress,
                    ),
                  ),
                  StationPhase.failed => Icon(
                    Icons.error_outline,
                    color: scheme.error,
                  ),
                  StationPhase.interrupted || StationPhase.empty => const Icon(
                    Icons.pause_circle_outline,
                  ),
                  _ => const Icon(Icons.hourglass_empty),
                },
              ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.store,
    required this.station,
    required this.phase,
  });

  final StationStore store;
  final Station station;
  final StationPhase phase;

  @override
  Widget build(BuildContext context) {
    return switch (phase) {
      StationPhase.interrupted => TextButton(
        onPressed: () => CaptureFlow.resume(context, store, station),
        child: const Text('Resume'),
      ),
      StationPhase.empty => TextButton(
        onPressed: () => store.discard(station),
        child: const Text('Discard'),
      ),
      StationPhase.failed => TextButton(
        onPressed: () => store.retry(station),
        child: const Text('Retry'),
      ),
      _ => const SizedBox(width: 8),
    };
  }
}
