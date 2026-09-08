import 'dart:convert';
import 'dart:io';

import 'harness/field_metrics.dart';

/// `tools/corpus_manifest` — read and write `phases/corpus/manifest.json`.
///
/// The manifest is the committed half of the Phase 12 §4 corpus: the bundles are
/// too large for git, so what is committed is their names, sizes and SHA-256s,
/// plus the baselines measured against them. That split has one property worth
/// being explicit about — **a real capture cannot be regenerated**. A synthetic
/// fixture traces back to a profile name and a seed; a station in a building
/// traces back to an afternoon. So the checksum is not bureaucracy: it is the
/// only way to know that the pixels the baseline was recorded against are the
/// pixels being scored.
///
/// ```
/// dart run tools/corpus_manifest.dart --list          # tab-separated, for the shell
/// dart run tools/corpus_manifest.dart --add corpus/daylight_shell.tar.gz
/// dart run tools/corpus_manifest.dart --check
/// ```
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

const String _manifestPath = 'phases/corpus/manifest.json';

Future<int> _run(List<String> arguments) async {
  final list = arguments.contains('--list');
  final check = arguments.contains('--check');
  final addIndex = arguments.indexOf('--add');

  final file = File(_manifestPath);
  final manifest = file.existsSync()
      ? (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>()
      : <String, Object?>{'schema_version': 1, 'scenes': <Object?>[]};
  final scenes = ((manifest['scenes'] as List?) ?? const [])
      .map((e) => (e as Map).cast<String, Object?>())
      .toList();

  if (addIndex >= 0 && addIndex + 1 < arguments.length) {
    final archive = File(arguments[addIndex + 1]);
    if (!archive.existsSync()) {
      stderr.writeln('no such archive: ${archive.path}');
      return 2;
    }
    final name = archive.uri.pathSegments.last.replaceAll('.tar.gz', '');
    if (FieldScene.byName(name) == null) {
      stderr.writeln(
        '"$name" is not one of the seven scenes in FieldScene.all. The scene '
        'names are the contract between the corpus, the per-scene thresholds and '
        'the baselines — an archive named anything else would be scored against '
        'default thresholds that describe no scene in particular.',
      );
      return 2;
    }
    // `shasum` rather than a Dart digest: no dependency, and the number a human
    // can reproduce from a shell to check a download by hand.
    final digest = await Process.run('shasum', ['-a', '256', archive.path]);
    if (digest.exitCode != 0) {
      stderr.writeln('shasum failed: ${digest.stderr}');
      return 2;
    }
    final sha = (digest.stdout as String).split(RegExp(r'\s+')).first;
    scenes.removeWhere((s) => s['name'] == name);
    scenes.add({
      'name': name,
      'sha256': sha,
      'bytes': archive.lengthSync(),
      'captured': DateTime.now().toUtc().toIso8601String(),
    });
    scenes.sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));
    manifest['scenes'] = scenes;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
    stdout.writeln('added $name  $sha  ${archive.lengthSync()} bytes');
    return 0;
  }

  if (list) {
    // Tab-separated for `tools/fetch_corpus.sh`, which reads this rather than
    // parsing JSON in bash.
    for (final scene in scenes) {
      stdout.writeln(
        '${scene['name']}\t${scene['sha256']}\t${scene['bytes']}',
      );
    }
    return 0;
  }

  if (check) {
    final named = {for (final scene in scenes) scene['name'] as String};
    var incomplete = false;
    for (final scene in FieldScene.all) {
      final present = named.contains(scene.name);
      stdout.writeln(
        '  ${scene.name.padRight(24)}${present ? 'in the manifest' : 'NOT CAPTURED'}'
        '  — ${scene.stresses}',
      );
      if (!present) incomplete = true;
    }
    if (incomplete) {
      stdout.writeln(
        '\nThe corpus is incomplete. That is a fact about what has been shot, '
        'not a build failure — but the quality gate says so on every run rather '
        'than passing quietly, because a regression detector with no fixtures '
        'catches nothing.',
      );
    }
    return 0;
  }

  stdout.write('''
tools/corpus_manifest — the committed half of the real-site corpus.

  --list              tab-separated name/sha/bytes, for fetch_corpus.sh
  --add <archive>     record a scene's checksum and size
  --check             which of the seven scenes have been captured
''');
  return 0;
}
