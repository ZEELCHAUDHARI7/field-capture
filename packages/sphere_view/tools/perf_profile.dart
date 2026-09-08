import 'dart:convert';
import 'dart:io';

import 'harness/profiles.dart';

/// `tools/perf_profile` — where the minute goes, stage by stage.
///
/// ```
/// dart run tools/perf_profile.dart --tier mid
/// dart run tools/perf_profile.dart --profiles nominal --repeat 3
/// ```
///
/// Phase 12 §3 opens with "measure before optimising", and this is the
/// measurement. It replays the synthetic corpus, groups the fifteen reported
/// stages into the nine rows the phase doc predicts a distribution for, and
/// prints both next to each other.
///
/// **It cannot measure five of those rows honestly, and it says so rather than
/// printing a number that looks like it can.** The corpus renders 480×640
/// frames (`SynthRunner.frameSize`) because nine profiles of 12 MP frames is
/// hundreds of gigabytes of PNG and hours of pure-Dart rendering. A device
/// shoots 12 MP. So every stage whose cost is *per input pixel* — the bracket
/// decode, the fusion itself, the registration decode — is understated here by
/// up to the 40× pixel ratio, and worse than proportionally so, because §5's
/// downscale-before-fusion never even engages at 0.58× oversampling
/// (`hdr_oversampling` in the output below) whereas at 12 MP it fires at 3.55×
/// and changes the shape of the stage.
///
/// What the corpus *does* measure faithfully is everything driven by the output
/// canvas and the position count, because both are the real ones: the tier's
/// 6144×3072 canvas, 34 positions, 0.33 overlap. Warping, gain compensation,
/// seam finding, blending, pole filling and encoding are all in that group, and
/// together they are over half the pipeline.
///
/// The per-input-pixel half is measured at capture resolution by
/// `sphere_stitch_test`'s `§3 capture-resolution stage benchmark`, in C++, where
/// synthesising a 12 MP frame costs milliseconds instead of minutes. Run both;
/// `docs/PERFORMANCE.md` is where the two halves are combined into a predicted
/// device distribution, and where the prediction is compared against the device
/// matrix once a device has run.
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.write(_usage);
    return 0;
  }

  final runs = <String, List<Map<String, num>>>{};
  final facts = <String, Map<String, Object?>>{};

  for (final name in options.profiles) {
    final bundle =
        '${options.bundleDirectory}${Platform.pathSeparator}$name';
    if (!Directory(bundle).existsSync()) {
      stderr.writeln(
        'no bundle at $bundle — run `dart run tools/synth.dart --all` first',
      );
      return 2;
    }
    for (var repeat = 0; repeat < options.repeat; repeat++) {
      stdout.write(
        '  ${name.padRight(14)}'
        '${options.repeat > 1 ? 'run ${repeat + 1}/${options.repeat} ' : ''}',
      );
      final run = await Process.run('dart', [
        'run',
        'tools/replay.dart',
        '--bundle',
        bundle,
        '--backend',
        'native',
        '--tier',
        options.tier,
        '--report',
        'json',
        '--out',
        '${options.outputDirectory}/replay/$name',
      ]);
      if (run.exitCode != 0) {
        // A refusal is an outcome, not a crash — `sparse_plan` is built to be
        // refused. It has no stage distribution to contribute either way.
        stdout.writeln('refused (no timings to report)');
        continue;
      }
      final text = run.stdout as String;
      final report =
          jsonDecode(text.substring(text.indexOf('{'))) as Map<String, Object?>;
      final stages = (report['stage_milliseconds'] as Map)
          .cast<String, Object?>();
      final diagnostics =
          (report['compositing'] as Map?)?.cast<String, Object?>() ?? {};
      final row = <String, num>{
        for (final entry in stages.entries)
          entry.key: (entry.value as num?) ?? 0,
        for (final entry in diagnostics.entries)
          if (entry.key.endsWith('_ms') && entry.value is num)
            entry.key: entry.value as num,
      };
      runs.putIfAbsent(name, () => []).add(row);
      facts[name] = {
        for (final key in _factKeys)
          if (diagnostics[key] != null) key: diagnostics[key],
      };
      stdout.writeln('${((row['total'] ?? 0) / 1000).toStringAsFixed(1)}s');
    }
  }

  if (runs.isEmpty) {
    stderr.writeln('nothing was measured');
    return 2;
  }

  final table = _render(runs, facts, options);
  stdout.writeln();
  stdout.write(table);

  final out = Directory(options.outputDirectory);
  await out.create(recursive: true);
  await File('${out.path}/stage_distribution.md').writeAsString(table);
  await File('${out.path}/stage_distribution.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'tier': options.tier,
      'repeat': options.repeat,
      'measured': DateTime.now().toUtc().toIso8601String(),
      'host': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'cores': Platform.numberOfProcessors,
      'runs': runs,
      'facts': facts,
    }),
  );
  stdout.writeln('written to ${out.path}/stage_distribution.{md,json}');
  return 0;
}

/// One row of the phase doc's §3 table: which reported stages compose it, what
/// the doc expects it to cost on a device, and whether this corpus can say.
class _Row {
  const _Row(
    this.label,
    this.stages, {
    required this.expected,
    required this.faithful,
  });

  /// The doc's name for it.
  final String label;

  /// The native stage keys that add up to it.
  final List<String> stages;

  /// The phase doc's predicted device range, or `''` where it predicts none.
  final String expected;

  /// Whether this corpus measures it at the size a device would see.
  ///
  /// `false` means per-input-pixel, and the corpus's frames are 0.3 MP against
  /// a device's 12 MP. Printing a number without this column would be the whole
  /// error the doc's "measure first" is trying to avoid — it would show fusion
  /// as 13% of the pipeline when on a device it is the largest single cost.
  final bool faithful;
}

/// The nine rows of the §3 table, in its order, plus the two stages it omits.
const List<_Row> _rows = [
  _Row('HDR fusion', ['hdr_total_ms'], expected: '25-45 s', faithful: false),
  _Row(
    'decode + undistort',
    ['undistort'],
    // The doc folds this into "features"; it is separated because it is the
    // target of win #2 (parallelise JPEG decode) and mixing a decode into a
    // SIFT measurement would hide exactly the number that decides whether the
    // win is worth taking.
    expected: '(inside features)',
    faithful: false,
  ),
  _Row('features (SIFT)', ['features'], expected: '8-12 s', faithful: false),
  _Row('matching', ['match'], expected: '3-6 s', faithful: true),
  _Row('bundle adjust', ['adjust'], expected: '1-3 s', faithful: true),
  _Row('warp', ['warp'], expected: '5-8 s', faithful: true),
  _Row('gain comp', ['compensate'], expected: '1-2 s', faithful: true),
  _Row('seam (graph-cut)', ['seam'], expected: '6-12 s', faithful: true),
  _Row('blend (strips)', ['blend'], expected: '8-15 s', faithful: true),
  _Row('pole fill', ['poles'], expected: '', faithful: true),
  _Row('encode', ['encode'], expected: '1-2 s', faithful: true),
];

/// Diagnostics that decide how to read the table, so they are printed with it.
const List<String> _factKeys = [
  'hdr_oversampling',
  'hdr_frame_scale',
  'hdr_decode_reduction',
  'hdr_fused',
  'hdr_positions',
  'seam_scale',
  'strips',
  'num_bands',
  'canvas_width',
  'seam_pair_max_ms',
];

String _render(
  Map<String, List<Map<String, num>>> runs,
  Map<String, Map<String, Object?>> facts,
  _Options options,
) {
  final buffer = StringBuffer()
    ..writeln('# Where the stitch minute goes')
    ..writeln()
    ..writeln('tier `${options.tier}` · ${options.repeat} run(s) per profile · ')
    ..writeln(
      '${Platform.numberOfProcessors} cores · '
      '${Platform.operatingSystem} · '
      '${DateTime.now().toUtc().toIso8601String()}',
    )
    ..writeln()
    ..writeln(
      'The `faithful?` column is the point of this table. `no` means the stage '
      'cost scales with input pixels and this corpus renders 480x640 frames '
      'against a device\'s 12 MP, so the figure understates the device by up to '
      'the pixel ratio and does not even exercise the same code path — Phase 05 '
      "§5's downscale fires at 2x oversampling and this corpus is at "
      '${_oversampling(facts)}x. Those stages are measured at capture '
      'resolution by `sphere_stitch_test` instead.',
    )
    ..writeln();

  for (final profile in runs.keys) {
    final samples = runs[profile]!;
    final total = _mean(samples, ['total']);
    buffer
      ..writeln('## `$profile`')
      ..writeln()
      ..writeln(
        '| stage | measured | share | doc expects (device) | faithful? |',
      )
      ..writeln('| --- | ---: | ---: | --- | --- |');
    for (final row in _rows) {
      final ms = _mean(samples, row.stages);
      final spread = _spread(samples, row.stages);
      buffer.writeln(
        '| ${row.label} '
        '| ${(ms / 1000).toStringAsFixed(2)} s'
        '${samples.length > 1 ? ' ±${(spread / 1000).toStringAsFixed(2)}' : ''} '
        '| ${total == 0 ? '—' : '${(100 * ms / total).toStringAsFixed(1)}%'} '
        '| ${row.expected.isEmpty ? '—' : row.expected} '
        '| ${row.faithful ? 'yes' : '**no**'} |',
      );
    }
    final accounted = _rows.fold<double>(
      0,
      (sum, row) => sum + _mean(samples, row.stages),
    );
    buffer
      ..writeln(
        '| **total** | **${(total / 1000).toStringAsFixed(2)} s** | | '
        '58-105 s | |',
      )
      ..writeln(
        '| unaccounted | ${((total - accounted) / 1000).toStringAsFixed(2)} s '
        '| ${total == 0 ? '—' : '${(100 * (total - accounted) / total).toStringAsFixed(1)}%'} '
        '| | |',
      )
      ..writeln();
    final f = facts[profile];
    if (f != null && f.isNotEmpty) {
      buffer
        ..writeln(
          'how to read it: '
          '${f.entries.map((e) => '`${e.key}` ${e.value}').join(' · ')}',
        )
        ..writeln();
    }
  }
  return buffer.toString();
}

String _oversampling(Map<String, Map<String, Object?>> facts) {
  for (final f in facts.values) {
    final value = f['hdr_oversampling'];
    if (value is num) return value.toStringAsFixed(2);
  }
  return '?';
}

double _mean(List<Map<String, num>> samples, List<String> keys) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final sample in samples) {
    for (final key in keys) {
      sum += (sample[key] ?? 0).toDouble();
    }
  }
  return sum / samples.length;
}

/// Half the observed range, which is what "±" means in the table.
///
/// Not a standard deviation: three runs do not support one, and the reason this
/// column exists is the known `cv::MergeMertens` non-determinism, where the
/// question is how wide the swing gets rather than how it is shaped.
double _spread(List<Map<String, num>> samples, List<String> keys) {
  if (samples.length < 2) return 0;
  var lowest = double.infinity;
  var highest = -double.infinity;
  for (final sample in samples) {
    var value = 0.0;
    for (final key in keys) {
      value += (sample[key] ?? 0).toDouble();
    }
    lowest = value < lowest ? value : lowest;
    highest = value > highest ? value : highest;
  }
  return (highest - lowest) / 2;
}

const String _usage = '''
tools/perf_profile — replay the corpus and report where the time goes.

  --profiles <a,b>   profiles to measure (default: every one that stitches)
  --tier low|mid|high  output tier (default mid, the doc's §3 assumption)
  --repeat <n>       runs per profile, to show the spread (default 1)
  --bundles <dir>    where the bundles are (default build/bundles)
  --out <dir>        where to write the table (default build/perf)
  --help
''';

class _Options {
  _Options({
    required this.profiles,
    required this.tier,
    required this.repeat,
    required this.bundleDirectory,
    required this.outputDirectory,
    required this.help,
  });

  final List<String> profiles;
  final String tier;
  final int repeat;
  final String bundleDirectory;
  final String outputDirectory;
  final bool help;

  static _Options parse(List<String> arguments) {
    // Every profile that produces a panorama. `sparse_plan` is excluded
    // because it is built to be refused and contributes no timings.
    var profiles = [
      for (final p in SynthProfile.all)
        if (p.enforceCoverage) p.name,
    ];
    var tier = 'mid';
    var repeat = 1;
    var bundles = 'build/bundles';
    var out = 'build/perf';
    var help = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--profiles':
          profiles = arguments[++i].split(',');
        case '--tier':
          tier = arguments[++i];
        case '--repeat':
          repeat = int.parse(arguments[++i]);
        case '--bundles':
          bundles = arguments[++i];
        case '--out':
          out = arguments[++i];
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument: ${arguments[i]}');
      }
    }
    return _Options(
      profiles: profiles,
      tier: tier,
      repeat: repeat,
      bundleDirectory: bundles,
      outputDirectory: out,
      help: help,
    );
  }
}
