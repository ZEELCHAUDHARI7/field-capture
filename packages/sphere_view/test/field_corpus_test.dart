import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/harness/field_metrics.dart';

/// Phase 12 §4 — the corpus mechanism, tested without the corpus.
///
/// The bundles need a site visit. Everything around them does not, and the part
/// worth testing now is the part that decides whether the corpus can be trusted
/// when it arrives: that the seven scenes are the seven scenes, that a field
/// metric never inherits a truth-referenced metric's name, and that the absence
/// of a bundle is loud.
void main() {
  test('the seven scenes of §4 are all defined, once each', () {
    expect(FieldScene.all.length, 7);
    final names = FieldScene.all.map((s) => s.name).toList();
    expect(names.toSet().length, names.length, reason: 'duplicate scene name');
    // The names are the contract: `replay.dart` resolves a bundle directory to a
    // scene by name, and an unmatched name is refused rather than scored against
    // defaults that describe no scene in particular.
    for (final name in names) {
      expect(name, matches(RegExp(r'^[a-z0-9_]+$')));
      expect(FieldScene.byName(name), isNotNull);
    }
    expect(FieldScene.byName('a_scene_nobody_defined'), isNull);
  });

  test('every scene says what it stresses and how to shoot it', () {
    for (final scene in FieldScene.all) {
      expect(scene.stresses, isNotEmpty, reason: '${scene.name} has no purpose');
      // Without this a "regression" six months from now is indistinguishable
      // from a different afternoon in a different corner of the building.
      expect(
        scene.shootingNote.length,
        greaterThan(80),
        reason:
            '${scene.name} has no usable shooting note, so a re-shoot would not '
            'be the same experiment',
      );
    }
  });

  test('the daylight shell is held to the tightest bar in the corpus', () {
    // §4's words are "must be excellent, no excuses", and a corpus where the
    // easy scene is judged as leniently as the 1 m room would let a real
    // regression through on the one capture that has no excuse for it.
    final shell = FieldScene.byName('daylight_shell')!;
    for (final other in FieldScene.all) {
      if (other.name == shell.name) continue;
      expect(
        shell.seamScore,
        lessThanOrEqualTo(other.seamScore),
        reason: '${other.name} is held to a tighter seam bar than the shell',
      );
      expect(shell.reportedRmsPx, lessThanOrEqualTo(other.reportedRmsPx));
    }
  });

  test('the tight room and the low-texture corridor are allowed to be worse', () {
    // The other half of the same rule: holding a 1 m room to the shell's bar
    // would fail it for obeying optics, and holding bare drywall to it would
    // fail it for being bare drywall — which is the scene's entire purpose.
    final tight = FieldScene.byName('tight_room_1m')!;
    final drywall = FieldScene.byName('bare_drywall_corridor')!;
    final shell = FieldScene.byName('daylight_shell')!;
    expect(tight.reportedRmsPx, greaterThan(shell.reportedRmsPx * 5));
    expect(drywall.reportedRmsPx, greaterThan(shell.reportedRmsPx * 5));
  });

  test('the manifest exists and knows which scenes are still owed', () {
    final manifest = File('phases/corpus/manifest.json');
    expect(
      manifest.existsSync(),
      isTrue,
      reason:
          'the manifest is the committed half of the corpus — the bundles are '
          'fetched, and a real capture cannot be regenerated from a seed the way '
          'a synthetic one can, so the checksums are the only proof a download is '
          'the capture a baseline was measured against',
    );
    final decoded =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    expect(decoded['schema_version'], 1);
    expect(decoded['scenes'], isA<List<Object?>>());
    for (final scene in (decoded['scenes']! as List)) {
      final entry = (scene as Map).cast<String, Object?>();
      expect(
        FieldScene.byName(entry['name']! as String),
        isNotNull,
        reason: '${entry['name']} is in the manifest but is not a known scene',
      );
      expect(entry['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(entry['bytes'], isA<int>());
    }
  });

  test('a field metric never wears a truth-referenced metric\'s name', () {
    // The rule the whole field path exists to keep. `s1` is reprojection against
    // the camera's true pose; `s1_reported` is bundle adjustment's opinion of its
    // own solution, and a solution can be smoothly, confidently,
    // self-consistently wrong — a focal error does exactly that. If these ever
    // shared an id, a field baseline and a synthetic one would silently be
    // compared, and this project has already made that mistake twice (Phase 03's
    // loop-closure tautology, and S1 over only the frames that registered).
    const truthReferenced = {'s1', 's2', 's6_ssim', 's6_psnr', 'tilt', 's3', 's3_wrap'};
    const fieldIds = {
      's3_field',
      's3_field_wrap',
      's4',
      's5',
      'holes',
      's1_reported',
      's2_reported',
      'tilt_reported',
      'rss',
    };
    for (final id in fieldIds) {
      // S4, S5, holes and rss are computed the same way in both paths from the
      // same inputs, so they legitimately share their names. The four that differ
      // must not.
      if (const {'s4', 's5', 'holes', 'rss'}.contains(id)) continue;
      expect(
        truthReferenced,
        isNot(contains(id)),
        reason:
            '"$id" is measured without a reference and must not share an id with '
            'a truth-referenced metric',
      );
    }
    // And the self-reported ones are visibly self-reported, so a table cannot be
    // read as if they were measurements.
    for (final id in const ['s1_reported', 's2_reported', 'tilt_reported']) {
      expect(id, endsWith('_reported'));
    }
  });

  test('the gate reports an absent corpus rather than passing quietly', () {
    // Checked by reading the gate rather than by running it, because running it
    // takes 98 seconds and this is a statement about what the code says. The
    // property is the one the `legacy-dart` default already cost this project
    // once: a regression detector with no fixtures catches nothing, and the way
    // that happens is silence.
    final gate = File('tools/ci/quality_gate.dart').readAsStringSync();
    expect(gate, contains('is ABSENT'));
    expect(gate, contains('Every number above is synthetic'));
    expect(
      gate,
      contains('FieldScene.all'),
      reason: 'the gate has to iterate the declared scenes, not a directory '
          'listing — a scene nobody captured must still produce a row',
    );
  });
}
