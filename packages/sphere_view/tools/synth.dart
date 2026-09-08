import 'dart:io';
import 'dart:isolate';


import 'harness/profiles.dart';
import 'harness/synth_runner.dart';

/// `tools/synth` — the forward renderer.
///
/// ```
/// dart run tools/synth.dart --profile nominal --out build/bundles/nominal
/// dart run tools/synth.dart --all --out build/bundles
/// dart run tools/synth.dart --list
/// ```
///
/// Unlike the sketch in the phase doc there is no `--input` for a ground-truth
/// JPEG. The ground truth is *generated*, from `scene.dart`, for reasons that
/// turned out to matter more than the flexibility: a procedural room is a few
/// hundred lines instead of megabytes of committed image, it has analytic depth
/// so the parallax profiles get honest disparity rather than a hand-painted
/// guess, and its texture richness is a dial, which is what lets `low_texture`
/// differ from `nominal` in exactly one property. `--input` can come back the
/// day a real 8K equirect is worth testing against; nothing here assumes it
/// cannot.
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

/// The real entry point.
///
/// Split out because Dart does **not** turn a value returned from `main` into
/// the process exit code — it is silently discarded, and a CI gate that always
/// exits 0 is worse than no gate at all.
Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.write(_usage);
    return 0;
  }
  if (options.list) {
    for (final profile in SynthProfile.all) {
      stdout.writeln('${profile.name.padRight(14)}${profile.purpose}');
    }
    return 0;
  }

  final profiles = options.all
      ? SynthProfile.all
      : [SynthProfile.byName(options.profile!)];

  final stopwatch = Stopwatch()..start();

  // Rendering is embarrassingly parallel across profiles and nothing else in
  // the rig is, so this is where the exit criteria's five-minute budget is won
  // or lost. Measured on a laptop, all nine profiles: 176 s at one job, 59 s at
  // four — and 348 s at ten, which is *worse than sequential*. The cliff is not
  // core count. Each isolate's working set is a whole ground-truth equirect and
  // the sampler walks it in an order the cache cannot predict, so past about
  // four workers they evict each other continuously and every one of them slows
  // down. Hence the cap: more parallelism here buys negative time.
  final jobs =
      options.jobs ??
      (Platform.numberOfProcessors ~/ 2).clamp(1, _maxUsefulJobs);
  final pending = [...profiles];
  final running = <Future<void>>{};

  Future<void> start(SynthProfile profile) async {
    final each = Stopwatch()..start();
    final path = options.all
        ? '${options.out}${Platform.pathSeparator}${profile.name}'
        : options.out;
    final summary = await _render(
      profile.name,
      path,
      options.groundTruthWidth,
    );
    stdout.writeln(
      '  ${profile.name.padRight(14)}'
      '${summary.positions}/${summary.planned} positions, '
      '${summary.frames} frames, '
      '${(each.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
      '${summary.positions < summary.planned ? '  (partial by design)' : ''}',
    );
  }

  while (pending.isNotEmpty || running.isNotEmpty) {
    while (running.length < jobs && pending.isNotEmpty) {
      late Future<void> future;
      future = start(pending.removeAt(0)).whenComplete(() {
        running.remove(future);
      });
      running.add(future);
    }
    if (running.isNotEmpty) await Future.any(running);
  }

  stdout.writeln(
    'rendered ${profiles.length} profile(s) in '
    '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
    '${profiles.length > 1 ? ' across $jobs isolates' : ''}',
  );
  return 0;
}

/// Renders one profile on its own isolate.
///
/// Only the profile *name* crosses the boundary, not the profile object: the
/// isolate reconstructs it from [SynthProfile.all], which keeps the message
/// trivially sendable and makes it impossible for a worker to be handed a
/// profile the CLI could not also have named.
Future<({int positions, int planned, int frames})> _render(
  String profileName,
  String path,
  int width,
) => Isolate.run(() async {
  final bundle = await SynthRunner(
    profile: SynthProfile.byName(profileName),
    groundTruthWidth: width,
  ).run(Directory(path));
  return (
    positions: bundle.positions.length,
    planned: bundle.plan.length,
    frames: bundle.positions.fold<int>(0, (n, p) => n + p.shots.length),
  );
});

/// Beyond this many render isolates, cache contention makes the wall clock
/// worse rather than better — see the measurement where [main] chooses it.
const int _maxUsefulJobs = 4;

const String _usage = '''
tools/synth — render synthetic CaptureBundles from a procedural ground truth.

  --profile <name>   one profile (see --list)
  --all              every profile, each into <out>/<name>
  --out <dir>        output directory (default build/bundles)
  --width <px>       ground-truth equirect width (default 2048)
  --jobs <n>         parallel isolates (default: half the CPUs, capped at 4)
  --list             list the profiles and what each is for
  --help
''';

class _Options {
  _Options({
    required this.profile,
    required this.all,
    required this.out,
    required this.groundTruthWidth,
    required this.jobs,
    required this.list,
    required this.help,
  });

  final String? profile;
  final bool all;
  final String out;
  final int groundTruthWidth;
  final int? jobs;
  final bool list;
  final bool help;

  static _Options parse(List<String> arguments) {
    String? profile;
    var all = false;
    String? out;
    var width = 2048;
    int? jobs;
    var list = false;
    var help = arguments.isEmpty;

    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--profile':
          profile = arguments[++i];
        case '--all':
          all = true;
        case '--out':
          out = arguments[++i];
        case '--width':
          width = int.parse(arguments[++i]);
        case '--jobs':
          jobs = int.parse(arguments[++i]);
        case '--list':
          list = true;
        case '--quiet':
          break;
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument "${arguments[i]}"');
      }
    }
    if (!list && !help && profile == null && !all) {
      throw ArgumentError('pass --profile <name> or --all');
    }
    return _Options(
      profile: profile,
      all: all,
      out: out ?? 'build/bundles',
      groundTruthWidth: width,
      jobs: jobs,
      list: list,
      help: help,
    );
  }
}
