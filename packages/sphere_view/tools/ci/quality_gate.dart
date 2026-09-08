import 'dart:convert';
import 'dart:io';

import '../harness/field_metrics.dart';
import '../harness/profiles.dart';

/// The comparison half of `quality_gate.sh`: replay every profile, write a
/// markdown table, and fail on regression against `phases/baselines/`.
///
/// **A recorded FAIL is not a regression.** That distinction is the whole
/// design of this file, and it is what the phase doc's exit criteria ask for:
/// the gate must run green today, against a stitcher that is known to be bad,
/// with its badness written down. If the gate simply failed whenever a metric
/// missed its target it would be red from now until Phase 04 lands, which means
/// nobody would look at it, which means it would not catch the regression it
/// exists for. So the baseline records what each number *is*, the gate checks
/// that it has not got worse, and the table prints the target verdict next to
/// it so the gap stays visible.
///
/// Two things count as a regression:
///
/// 1. a metric moving in the bad direction by more than the tolerance, or
/// 2. a metric that used to meet its target no longer meeting it — regardless
///    of tolerance, because crossing a criterion is a different kind of event
///    from drifting within one.
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

  final baselines = Directory(options.baselineDirectory);
  if (options.record) await baselines.create(recursive: true);

  final rows = <String>[];
  final regressions = <String>[];
  final missing = <String>[];
  var headerWritten = false;
  // Column count, so a refused profile can pad its row to match the header.
  var metricCount = 0;
  var header = '';

  for (final profile in SynthProfile.all) {
    final bundle =
        '${options.bundleDirectory}${Platform.pathSeparator}${profile.name}';
    if (!Directory(bundle).existsSync()) {
      stderr.writeln(
        'no bundle at $bundle — run tools/synth.dart --all first',
      );
      return 2;
    }

    // A subprocess per profile, not one process doing all nine.
    //
    // Peak RSS is one of the metrics. Measured in a shared process it would be
    // the high-water mark of everything replayed so far, so profile nine would
    // inherit profile one's worst moment and the number would be meaningless
    // for every profile but the first.
    final run = await Process.run('dart', [
      'run',
      'tools/replay.dart',
      '--bundle',
      bundle,
      '--backend',
      options.backend,
      '--report',
      'json',
    ]);
    if (run.exitCode != 0) {
      // A refusal is an OUTCOME, not a crash — for one profile it is the whole
      // point. `sparse_plan` exists to prove the pipeline says no to a capture
      // nothing downstream could recover, so treating its refusal as a broken
      // run would mean the gate could never be green against the native backend
      // and would be switched off, which is how the regression this backend
      // change exists to catch got in.
      //
      // The distinction is `!enforceCoverage`: that flag is set on exactly the
      // profiles built to be refused. Anywhere else a non-zero exit is still a
      // hard failure.
      if (!profile.enforceCoverage && _looksLikeRefusal(run.stderr as String)) {
        stdout.writeln('  ${profile.name.padRight(13)} REFUSED (as designed)');
        rows.add(
          '| `${profile.name}` | '
          '${List.filled(metricCount, 'refused').join(' | ')} | REFUSED |',
        );
        final refusalFile = File(
          '${baselines.path}${Platform.pathSeparator}${profile.name}.json',
        );
        if (options.record) {
          await refusalFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'profile': profile.name,
              'backend': options.backend,
              'note': options.note,
              'refused': true,
              'metrics': <String, Object?>{},
            }),
          );
        }
        continue;
      }
      stderr.writeln('replay failed for ${profile.name}:\n${run.stderr}');
      return 2;
    }

    final report = jsonDecode(_lastJsonObject(run.stdout as String))
        as Map<String, Object?>;
    final metrics = (report['metrics'] as List).cast<Map<String, Object?>>();

    metricCount = metrics.length;
    if (!headerWritten) {
      header =
          '| profile | ${metrics.map((m) => m['label']).join(' | ')} | result |\n'
          '| --- | ${metrics.map((_) => '---').join(' | ')} | --- |';
      headerWritten = true;
    }

    final passed = report['pass'] == true;
    rows.add(
      '| `${profile.name}` | '
      '${metrics.map((m) => '${m['formatted']}${m['pass'] == false ? ' ✗' : ''}').join(' | ')}'
      ' | ${passed ? 'PASS' : 'FAIL'} |',
    );

    final file = File(
      '${baselines.path}${Platform.pathSeparator}${profile.name}.json',
    );

    if (options.record) {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'profile': profile.name,
          'backend': options.backend,
          'note': options.note,
          'pass': passed,
          'metrics': {
            for (final m in metrics)
              if (m['value'] != null)
                m['id'] as String: {
                  'value': m['value'],
                  'pass': m['pass'],
                  'lower_is_better': m['lower_is_better'],
                },
          },
        }),
      );
      stdout.writeln(
        '  recorded ${profile.name.padRight(14)}'
        '${passed ? 'PASS' : 'FAIL'} (${file.path})',
      );
      continue;
    }

    if (!file.existsSync()) {
      missing.add(profile.name);
      stdout.writeln(
        '  ${profile.name.padRight(14)}${passed ? 'PASS' : 'FAIL'}  '
        '(no baseline)',
      );
      continue;
    }

    final baseline =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;

    // The mirror of the refusal branch above: a profile whose baseline records
    // a refusal and which now returns a panorama.
    //
    // Note what this no longer covers. Weak *plan geometry* is not a refusal any
    // more — thin overlap and an incomplete sphere are graded and stitched, on
    // the reasoning in `sphere_stitch.cpp`: the operator is standing on a site
    // and the alternative to a flawed panorama is walking back for another one.
    // `sparse_plan` was re-recorded with real metrics when that changed, so it
    // is now watched the same way every other profile is — by whether its
    // numbers move — and this branch is what would catch that re-record being
    // reverted by accident.
    //
    // The check stays because refusals that remain are the ones no policy should
    // quietly drop: a bundle with no frames, an unreadable manifest, a schema
    // the ABI cannot parse. Those cost the user nothing to refuse, because there
    // is nothing there to salvage.
    if (baseline['refused'] == true) {
      regressions.add(
        '${profile.name}: was refused as unregisterable, now returns a '
        'panorama — the guard against an unrecoverable capture has stopped '
        'firing',
      );
      stdout.writeln(
        '  ${profile.name.padRight(14)}REGRESSED (no longer refused)',
      );
      continue;
    }

    final recorded = (baseline['metrics'] as Map).cast<String, Object?>();
    final moved = <String>[];

    for (final metric in metrics) {
      final id = metric['id'] as String;
      final value = metric['value'];
      final was = recorded[id];
      if (value is! num || was is! Map) continue;
      final previous = (was['value'] as num).toDouble();
      final lowerIsBetter = was['lower_is_better'] != false;
      final now = value.toDouble();

      // A relative tolerance plus an absolute floor. Without the floor, a
      // metric legitimately sitting near zero — residual tilt on a levelled
      // solution — would trip on a change of 0.0001 degrees.
      //
      // Peak RSS gets its own, much wider band. It is the high-water mark of a
      // garbage-collected VM, so it moves several percent between identical
      // runs depending on when a collection happened to land; gating it at 5%
      // produces a gate that cries wolf, and a gate that cries wolf gets
      // switched off. It is still watched — a real leak moves it far more than
      // this — just not to three significant figures.
      final tolerance = id == 'rss'
          ? _rssTolerance
          : _fusionAffected.contains(id)
          ? _fusionNoiseTolerance
          : options.tolerance;
      final allowance = previous.abs() * tolerance + options.absoluteFloor;
      final worse = lowerIsBetter
          ? now > previous + allowance
          : now < previous - allowance;
      if (worse) {
        moved.add(
          '$id ${previous.toStringAsFixed(3)} -> ${now.toStringAsFixed(3)}',
        );
      }

      // Crossing a criterion is normally a different kind of event from
      // drifting within one, and worth reporting regardless of tolerance — but
      // not for peak RSS, which is a garbage-collected VM's high-water mark
      // sitting a few percent from the 700 MB target. It crosses back and forth
      // between identical runs, so applying the crossing rule to it reports a
      // regression on roughly every other run and teaches the reader to ignore
      // the gate. Its own 25% drift band is what watches it; a real leak moves it
      // far further than the boundary it happens to straddle.
      if (id != 'rss' && was['pass'] == true && metric['pass'] == false) {
        moved.add('$id no longer meets its target');
      }
    }

    if (moved.isEmpty) {
      stdout.writeln(
        '  ${profile.name.padRight(14)}${passed ? 'PASS' : 'FAIL'}  '
        '(no regression against baseline)',
      );
    } else {
      regressions.add('${profile.name}: ${moved.join('; ')}');
      stdout.writeln(
        '  ${profile.name.padRight(14)}${passed ? 'PASS' : 'FAIL'}  '
        'REGRESSED: ${moved.join('; ')}',
      );
    }
  }

  // ── the real-site corpus (Phase 12 §4) ────────────────────────────────────
  //
  // What makes the gate stop being a synthetic-only claim. Every field capture is
  // a permanent fixture with a committed baseline, so a regression six months
  // from now is caught here rather than by a user.
  //
  // **An absent corpus is reported, never silently skipped.** The bundles live
  // outside git (they are hundreds of megabytes of JPEG) and are fetched by
  // `tools/fetch_corpus.sh`, so "not downloaded" is the normal state on a fresh
  // clone — and a gate that prints nothing in that state is a gate that goes on
  // being green for a year after the corpus is lost. That is the same failure as
  // the backend defaulting to `legacy-dart`: a regression detector pointed at
  // nothing.
  final fieldRows = <String>[];
  var fieldPresent = 0;
  for (final scene in FieldScene.all) {
    final bundle =
        '${options.corpusDirectory}${Platform.pathSeparator}${scene.name}';
    final baselineFile = File(
      '${baselines.path}${Platform.pathSeparator}field'
      '${Platform.pathSeparator}${scene.name}.json',
    );
    if (!Directory(bundle).existsSync()) {
      fieldRows.add(
        '| `${scene.name}` | not downloaded | '
        '${baselineFile.existsSync() ? 'baseline committed' : '**no baseline**'} |',
      );
      continue;
    }
    ++fieldPresent;
    final run = await Process.run('dart', [
      'run',
      'tools/replay.dart',
      '--bundle',
      bundle,
      '--backend',
      options.backend,
      '--report',
      'json',
    ]);
    if (run.exitCode != 0) {
      stderr.writeln('field replay failed for ${scene.name}:\n${run.stderr}');
      return 2;
    }
    final report = jsonDecode(_lastJsonObject(run.stdout as String))
        as Map<String, Object?>;
    final metrics = (report['metrics'] as List).cast<Map<String, Object?>>();
    final passed = report['pass'] == true;
    fieldRows.add(
      '| `${scene.name}` | '
      '${metrics.map((m) => '${m['formatted']}${m['pass'] == false ? ' ✗' : ''}').join(', ')} '
      '| ${passed ? 'PASS' : 'FAIL'} |',
    );

    if (options.record) {
      await baselineFile.parent.create(recursive: true);
      await baselineFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scene': scene.name,
          'backend': options.backend,
          'note': options.note,
          'pass': passed,
          'metrics': {
            for (final m in metrics)
              if (m['value'] != null)
                m['id'] as String: {
                  'value': m['value'],
                  'pass': m['pass'],
                  'lower_is_better': m['lower_is_better'],
                },
          },
        }),
      );
      stdout.writeln('  recorded field/${scene.name.padRight(22)}'
          '${passed ? 'PASS' : 'FAIL'}');
      continue;
    }
    if (!baselineFile.existsSync()) {
      missing.add('field/${scene.name}');
      stdout.writeln('  field/${scene.name.padRight(22)}(no baseline)');
      continue;
    }
    final baseline =
        jsonDecode(await baselineFile.readAsString()) as Map<String, Object?>;
    final recorded = (baseline['metrics'] as Map).cast<String, Object?>();
    final moved = <String>[];
    for (final metric in metrics) {
      final id = metric['id'] as String;
      final value = metric['value'];
      final was = recorded[id];
      if (value is! num || was is! Map) continue;
      final previous = (was['value'] as num).toDouble();
      final lowerIsBetter = was['lower_is_better'] != false;
      final now = value.toDouble();
      // The same bands as the synthetic side, and for the same reasons — plus
      // one field-specific fact: a real capture is not re-rendered, so the only
      // run-to-run variation is the pipeline's own. That makes these baselines
      // *tighter* evidence than the synthetic ones, not looser.
      final tolerance = id == 'rss'
          ? _rssTolerance
          : _fusionAffected.contains(id)
          ? _fusionNoiseTolerance
          : options.tolerance;
      final allowance = previous.abs() * tolerance + options.absoluteFloor;
      final worse = lowerIsBetter
          ? now > previous + allowance
          : now < previous - allowance;
      if (worse) {
        moved.add(
          '$id ${previous.toStringAsFixed(3)} -> ${now.toStringAsFixed(3)}',
        );
      }
    }
    if (moved.isEmpty) {
      stdout.writeln(
        '  field/${scene.name.padRight(22)}${passed ? 'PASS' : 'FAIL'}  '
        '(no regression against baseline)',
      );
    } else {
      regressions.add('field/${scene.name}: ${moved.join('; ')}');
      stdout.writeln(
        '  field/${scene.name.padRight(22)}REGRESSED: ${moved.join('; ')}',
      );
    }
  }

  if (fieldPresent == 0) {
    stdout.writeln(
      '\n  the real-site corpus is ABSENT (0 of ${FieldScene.all.length} '
      'scenes in ${options.corpusDirectory}).\n'
      '  Every number above is synthetic. Fetch it with '
      'tools/fetch_corpus.sh, or read docs/FIELD_CORPUS.md to capture it.',
    );
  } else if (fieldPresent < FieldScene.all.length) {
    stdout.writeln(
      '\n  the real-site corpus is PARTIAL ($fieldPresent of '
      '${FieldScene.all.length} scenes).',
    );
  }

  final markdown = StringBuffer()
    ..writeln('# sphere_view quality gate')
    ..writeln()
    ..writeln('backend: `${options.backend}`  ')
    ..writeln('generated: ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln()
    ..writeln(header)
    ..writeAll(rows, '\n')
    ..writeln()
    ..writeln()
    ..writeln('## Real-site corpus (Phase 12 §4)')
    ..writeln()
    ..writeln(
      fieldPresent == 0
          ? 'ABSENT — 0 of ${FieldScene.all.length} scenes present in '
                '`${options.corpusDirectory}`. **Every number above is '
                'synthetic.** `tools/fetch_corpus.sh` downloads the bundles; '
                '`docs/FIELD_CORPUS.md` says how to capture them.'
          : '$fieldPresent of ${FieldScene.all.length} scenes present. Field '
                'metrics are reference-free and carry their own ids — `s3_field` '
                'is not `s3`, and `s1_reported` is the stitcher marking its own '
                'homework rather than a measurement. See '
                '`tools/harness/field_metrics.dart`.',
    )
    ..writeln()
    ..writeln('| scene | metrics | result |')
    ..writeln('| --- | --- | --- |')
    ..writeAll(fieldRows, '\n')
    ..writeln()
    ..writeln()
    ..writeln('`✗` marks a metric that misses its target. A profile can be')
    ..writeln('`FAIL` and the gate still green: the gate compares against')
    ..writeln('`${options.baselineDirectory}`, and until the native stitcher')
    ..writeln('lands every recorded baseline is a FAIL on purpose.');

  await File(options.output).writeAsString(markdown.toString());
  stdout.writeln('table written to ${options.output}');

  if (missing.isNotEmpty) {
    stderr.writeln(
      'no baseline for: ${missing.join(', ')}\n'
      '  record them deliberately with:\n'
      '      tools/ci/quality_gate.sh --record --note "why these numbers"',
    );
    return 3;
  }
  if (regressions.isNotEmpty) {
    stderr.writeln('\nREGRESSION');
    for (final line in regressions) {
      stderr.writeln('  $line');
    }
    stderr.writeln(
      '\nIf a number moved for a good reason, re-record the baseline in its '
      'own commit and say why in the message.',
    );
    return 1;
  }
  stdout.writeln('no regressions.');
  return 0;
}

/// Pulls the JSON object off the end of a replay's stdout.
///
/// `dart run` prepends its own build chatter on a cold cache, so the output is
/// not guaranteed to start with `{`.
String _lastJsonObject(String output) {
  final start = output.indexOf('{');
  if (start < 0) {
    throw FormatException('no JSON in replay output:\n$output');
  }
  return output.substring(start);
}

/// Run-to-run noise band for peak RSS. See where it is used.
const double _rssTolerance = 0.25;

/// Metrics that sit downstream of HDR fusion, and therefore inherit its
/// non-determinism.
///
/// `cv::MergeMertens::process` returns different output for identical input —
/// isolated by elimination: 16 of 34 fused frames differ byte-for-byte between
/// two runs even with serial decode, alignment off and ghost suppression off, and
/// JPEG encoding is deterministic, so the pixels themselves differ. Everything
/// computed from a fused frame moves with it: S1 spans 8.24–9.13 px on `nominal`
/// across repeated runs, about 10%.
///
/// This band is a **placeholder for a bug, not a judgement about the metric.**
/// The alternative was a gate that reported a different regression set on every
/// run, and by this file's own reasoning that is a gate nobody reads — which is
/// how the last regression got in. Once fusion is deterministic these belong back
/// on the default tolerance, and the fact that they are not is written down in
/// `phases/README.md` rather than left in a constant.
const Set<String> _fusionAffected = {
  's1', 's2', 's3', 's3_wrap', 's4', 's6_ssim', 's6_psnr', 'tilt', 'holes',
};

/// Just above the measured 10% spread, so real movement still trips it.
const double _fusionNoiseTolerance = 0.15;

const String _usage = '''
quality_gate.dart — replay every profile and compare against the baselines.
Normally invoked through tools/ci/quality_gate.sh.

  --bundles <dir>    where the synthetic bundles are (default build/bundles)
  --corpus <dir>     where the real-site bundles are (default corpus)
  --baselines <dir>  baseline directory (default phases/baselines)
  --backend <name>   legacy-dart (default), reference-dart or native
  --out <file>       markdown table (default build/quality_gate.md)
  --tolerance <f>    relative drift allowed before it counts (default 0.05)
  --record           write baselines from this run instead of checking them
  --note <s>         the explanation recorded alongside them
  --help
''';

class _Options {
  _Options({
    required this.bundleDirectory,
    required this.corpusDirectory,
    required this.baselineDirectory,
    required this.backend,
    required this.output,
    required this.tolerance,
    required this.absoluteFloor,
    required this.record,
    required this.note,
    required this.help,
  });

  final String bundleDirectory;

  /// Where the real-site bundles are. Outside `build/` because they are fetched
  /// rather than generated, and losing them to a `flutter clean` would quietly
  /// turn the gate back into a synthetic-only claim.
  final String corpusDirectory;
  final String baselineDirectory;
  final String backend;
  final String output;
  final double tolerance;
  final double absoluteFloor;
  final bool record;
  final String note;
  final bool help;

  static _Options parse(List<String> arguments) {
    var bundles = 'build/bundles';
    var corpus = 'corpus';
    var baselines = 'phases/baselines';
    var backend = 'legacy-dart';
    var out = 'build/quality_gate.md';
    var tolerance = 0.05;
    var record = false;
    var note = '';
    var help = false;

    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--bundles':
          bundles = arguments[++i];
        case '--corpus':
          corpus = arguments[++i];
        case '--baselines':
          baselines = arguments[++i];
        case '--backend':
          backend = arguments[++i];
        case '--out':
          out = arguments[++i];
        case '--tolerance':
          tolerance = double.parse(arguments[++i]);
        case '--record':
          record = true;
        case '--note':
          note = arguments[++i];
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument "${arguments[i]}"');
      }
    }
    return _Options(
      bundleDirectory: bundles,
      corpusDirectory: corpus,
      baselineDirectory: baselines,
      backend: backend,
      output: out,
      tolerance: tolerance,
      // Half a percent of a metric's own units, so a number sitting at zero
      // does not trip on floating-point weather.
      absoluteFloor: 0.005,
      record: record,
      note: note,
      help: help,
    );
  }
}

/// Whether a non-zero replay exit was the pipeline deliberately refusing a
/// capture rather than falling over. The native library returns a dedicated
/// error for this; the text is matched as a second signal so a refactor of the
/// message alone cannot silently turn a refusal into a hard gate failure.
bool _looksLikeRefusal(String stderrText) =>
    stderrText.contains('registration refused this capture') ||
    stderrText.contains('cannot be registered');
