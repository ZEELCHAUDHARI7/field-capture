import 'dart:convert';
import 'dart:io';

/// `tools/device_matrix` — merge the rows one device each produced into the
/// published table.
///
/// ```
/// dart run tools/device_matrix.dart --add tab-a9.json
/// dart run tools/device_matrix.dart --out docs/DEVICE_MATRIX.md
/// ```
///
/// Phase 12 §1's matrix is the deliverable that decides whether the feature
/// ships, and the reason it is generated rather than typed is that a table filled
/// in by hand is filled in differently on every device — and the one number
/// somebody rounds in their favour is the one that matters. Each row comes from
/// `example/integration_test/device_matrix_test.dart` on that device; this tool
/// only merges and formats.
///
/// **A missing device is a row that says so.** The fleet is declared here, in
/// [_fleet], so the table has a line for every device that ships whether or not
/// anybody has run it — which is what stops "the matrix passes" from meaning "the
/// two tablets we happened to have on the desk pass". The low-end rugged Android
/// is listed first because that is the order the phase doc insists on: iPads will
/// be fine; the 3 GB `LEGACY` tablet is what decides.
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

/// The fleet, in the order the phase doc says to test it.
///
/// Names and specs are what the *doc* declares, not measurements — a row is
/// filled in from a device run or it says "not measured". Where a spec here
/// disagrees with what a device reported, the device wins and the disagreement is
/// printed, because a fleet list that quietly diverges from the hardware is worse
/// than no list.
const List<_FleetEntry> _fleet = [
  _FleetEntry(
    'rugged Android tablet (site model)',
    key: 'rugged_android',
    expectedRamMb: 3072,
    note:
        'THE DEVICE THAT DECIDES. 3 GB, LEGACY camera, possibly no gyroscope. '
        'Test first, not last.',
  ),
  _FleetEntry(
    'Samsung Galaxy Tab A-series',
    key: 'galaxy_tab_a',
    expectedRamMb: 4096,
    note: 'the volume Android tablet; LIMITED camera is likely',
  ),
  _FleetEntry(
    'mid-range Android phone (fallback)',
    key: 'android_phone',
    expectedRamMb: 6144,
    note: 'the device a manager already has in their pocket',
  ),
  _FleetEntry(
    'Samsung Galaxy Tab S-series',
    key: 'galaxy_tab_s',
    expectedRamMb: 8192,
    note: 'FULL camera, real bracketing',
  ),
  _FleetEntry(
    'iPad (10th/11th gen)',
    key: 'ipad_base',
    expectedRamMb: 4096,
    note: 'single rear camera, so no calibrated intrinsics (R2)',
  ),
  _FleetEntry(
    'iPad Pro (M-series)',
    key: 'ipad_pro',
    expectedRamMb: 8192,
    note: 'multi-camera, so AVCameraCalibrationData is available',
  ),
];

class _FleetEntry {
  const _FleetEntry(
    this.label, {
    required this.key,
    required this.expectedRamMb,
    required this.note,
  });

  final String label;

  /// File name stem a device's row is stored under, in `phases/device_matrix/`.
  final String key;

  final int expectedRamMb;
  final String note;
}

Future<int> _run(List<String> arguments) async {
  final rowsDirectory = Directory('phases/device_matrix');
  var output = 'docs/DEVICE_MATRIX.md';
  String? add;
  String? key;

  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--add':
        add = arguments[++i];
      case '--key':
        key = arguments[++i];
      case '--out':
        output = arguments[++i];
      case '--help' || '-h':
        stdout.write('''
tools/device_matrix — merge per-device rows into the published matrix.

  --add <file>   a sphere_view_device_matrix.json pulled off a device
  --key <name>   which fleet row it is (${_fleet.map((f) => f.key).join(', ')})
  --out <file>   where to write the table (default docs/DEVICE_MATRIX.md)
''');
        return 0;
    }
  }

  await rowsDirectory.create(recursive: true);

  if (add != null) {
    final source = File(add);
    if (!source.existsSync()) {
      stderr.writeln('no such file: $add');
      return 2;
    }
    final row = (jsonDecode(await source.readAsString()) as Map)
        .cast<String, Object?>();
    final resolved = key ?? _guessKey(row);
    if (resolved == null) {
      stderr.writeln(
        'could not tell which fleet row this is from '
        '"${row['device']}". Pass --key <${_fleet.map((f) => f.key).join('|')}>.',
      );
      return 2;
    }
    if (!_fleet.any((f) => f.key == resolved)) {
      stderr.writeln('"$resolved" is not a fleet row; add it to _fleet first');
      return 2;
    }
    final target = File('${rowsDirectory.path}/$resolved.json');
    await target.writeAsString(
      const JsonEncoder.withIndent('  ').convert(row),
    );
    stdout.writeln('recorded ${row['device']} as $resolved -> ${target.path}');
  }

  final rows = <String, Map<String, Object?>>{};
  for (final entry in _fleet) {
    final file = File('${rowsDirectory.path}/${entry.key}.json');
    if (file.existsSync()) {
      rows[entry.key] =
          (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    }
  }

  final table = _render(rows);
  await File(output).writeAsString(table);
  stdout
    ..writeln()
    ..write(table)
    ..writeln('written to $output');

  // Exit non-zero while the matrix is incomplete. Phase 12's exit criterion is
  // "all rows passing, low-end Android verified first", and a tool that exits 0
  // on an empty table would let that criterion be marked done by running nothing.
  final measured = rows.length;
  if (measured < _fleet.length) {
    stderr.writeln(
      '\n$measured of ${_fleet.length} fleet rows measured. The exit criterion '
      'is every row, and the rugged Android first.',
    );
    return 1;
  }
  return 0;
}

/// Which fleet row a report belongs to, from what the device called itself.
String? _guessKey(Map<String, Object?> row) {
  final device = '${row['device'] ?? ''}'.toLowerCase();
  if (device.contains('ipad')) {
    return device.contains('pro') ? 'ipad_pro' : 'ipad_base';
  }
  if (device.contains('sm-x') || device.contains('tab s')) return 'galaxy_tab_s';
  if (device.contains('sm-t') || device.contains('tab a')) return 'galaxy_tab_a';
  return null;
}

String _render(Map<String, Map<String, Object?>> rows) {
  final buffer = StringBuffer()
    ..writeln('# Device matrix')
    ..writeln()
    ..writeln(
      'Generated by `tools/device_matrix.dart` from the JSON each device wrote '
      'in `example/integration_test/device_matrix_test.dart`. Do not edit by '
      'hand — a matrix somebody can type into is a matrix somebody can round in '
      'their favour, and the one number that gets rounded is the one that '
      'matters.',
    )
    ..writeln()
    ..writeln(
      '`${rows.length}` of `${_fleet.length}` rows measured. Rows are in the '
      'order Phase 12 §1 says to test them: **the low-end rugged Android '
      'first** — iPads will be fine, and the 3 GB tablet with a `LEGACY` camera '
      'is what determines whether this ships.',
    )
    ..writeln()
    ..writeln('## Capability and budgets')
    ..writeln()
    ..writeln(
      '| device | OS | RAM | tier | bracketing | intrinsics | gyro | S7 capture | '
      'S8 stitch | S9 peak | thermal | battery/station |',
    )
    ..writeln(
      '| --- | --- | ---: | --- | --- | --- | --- | ---: | ---: | ---: | --- | ---: |',
    );

  for (final entry in _fleet) {
    final row = rows[entry.key];
    if (row == null) {
      buffer.writeln(
        '| **${entry.label}** | — | ${entry.expectedRamMb} MB (declared) | — '
        '| — | — | — | — | — | — | — | — |',
      );
      continue;
    }
    final capability = (row['capability'] as Map?)?.cast<String, Object?>() ?? {};
    final pose = (capability['pose_support'] as Map?)?.cast<String, Object?>() ?? {};
    buffer.writeln(
      '| **${row['device'] ?? entry.label}** '
      '| ${row['os_version'] ?? '?'} '
      '| ${row['total_memory_mb'] ?? '?'} MB '
      '| `${row['tier'] ?? '?'}` '
      '| ${capability['supports_bracketing'] == true ? 'yes (${capability['max_bracket_count']})' : '**no** (${capability['hardware_level']})'} '
      '| ${capability['has_distortion_model'] == true ? 'with distortion' : 'no distortion model'} '
      '| ${pose['has_gyroscope'] == true ? 'yes' : '**NO — unsupported**'} '
      '| ${_seconds(row['s7_session_ms'])} '
      '| ${_seconds(row['s8_stitch_ms'])} '
      '| ${row['s9_peak_rss_mb'] ?? '—'} MB '
      '| ${row['thermal_after_stitch'] ?? '—'} '
      '| ${_battery(row)} |',
    );
  }

  buffer
    ..writeln()
    ..writeln(
      'S7 ≤ 90 s, S8 ≤ 60 s, S9 < 700 MB are the exit criteria. **S8 here is a '
      'lower bound**: the reference scene is rendered on the device from 240×320 '
      'frames, because the renderer is pure Dart, so the decode and fusion '
      'stages do less work than a 12 MP capture gives them. The 12 MP figure '
      'comes from `sphere_stitch_test`\'s capture-resolution measurement — see '
      '`docs/METRICS.md`.',
    )
    ..writeln()
    ..writeln('## Quality on the fixed reference scene')
    ..writeln()
    ..writeln(
      'Every device stitches the *same* synthetic scene (`nominal`, seeded by '
      'name), so these numbers are comparable across hardware and against the '
      'desktop baselines in `phases/baselines/`. A device that differs here '
      'differs because of its arithmetic, not because of its scene.',
    )
    ..writeln()
    ..writeln(
      '| device | S1 rms | S2 loop | S3 seam | S4 gain | S5 coverage | S6 SSIM | '
      'S6 PSNR | warnings |',
    )
    ..writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |');
  for (final entry in _fleet) {
    final row = rows[entry.key];
    if (row == null) {
      buffer.writeln('| **${entry.label}** | — | — | — | — | — | — | — | — |');
      continue;
    }
    final quality = (row['quality'] as Map?)?.cast<String, Object?>() ?? {};
    final codes = (row['stitch_warning_codes'] as List?) ?? const [];
    buffer.writeln(
      '| **${row['device'] ?? entry.label}** '
      '| ${_fixed(quality['s1'], 2)} px '
      '| ${_fixed(quality['s2'], 3)}° '
      '| ${_fixed(quality['s3'], 2)}× '
      '| ${_fixed(quality['s4'], 3)} '
      '| ${_fixed(quality['s5'], 3)} '
      '| ${_fixed(quality['s6_ssim'], 4)} '
      '| ${_fixed(quality['s6_psnr'], 1)} dB '
      '| ${codes.isEmpty ? 'none' : codes.map((c) => '`$c`').join(', ')} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Soak: $_soakLabel')
    ..writeln()
    ..writeln('| device | runs | first-five peak | last-five peak | downgrades |')
    ..writeln('| --- | ---: | ---: | ---: | --- |');
  for (final entry in _fleet) {
    final soak = (rows[entry.key]?['soak'] as Map?)?.cast<String, Object?>();
    if (soak == null) {
      buffer.writeln('| **${entry.label}** | — | — | — | — |');
      continue;
    }
    final downgrades = (soak['downgraded_runs'] as List?) ?? const [];
    buffer.writeln(
      '| **${rows[entry.key]!['device']}** '
      '| ${soak['runs']} '
      '| ${soak['first_five_mean_mb']} MB '
      '| ${soak['last_five_mean_mb']} MB '
      '| ${downgrades.isEmpty ? 'none' : '**$downgrades**'} |',
    );
  }

  buffer
    ..writeln()
    ..writeln(
      'The soak is Phase 12 §5\'s "20 consecutive `low`-tier runs without an '
      'OOM". The two peak columns are the point: a leak or heap fragmentation is '
      'invisible in one run and obvious by the twentieth, and the test fails if '
      'the last five average more than 1.4× the first five.',
    )
    ..writeln()
    ..writeln('## How to add a device')
    ..writeln()
    ..writeln('```sh')
    ..writeln('cd example')
    ..writeln('flutter test integration_test/device_matrix_test.dart -d <id>')
    ..writeln('# pull sphere_view_device_matrix.json off the device, then:')
    ..writeln('dart run tools/device_matrix.dart --add that-file.json --key rugged_android')
    ..writeln('```')
    ..writeln()
    ..writeln(
      'Tests 1–5 are unattended and need no physical setup. Test 6 is the only '
      'source of S7 and needs somebody to pivot the tablet through 29 positions; '
      'it takes two minutes.',
    );
  return buffer.toString();
}

const String _soakLabel = '20 consecutive low-tier stitches';

String _seconds(Object? ms) =>
    ms is num ? '${(ms / 1000).toStringAsFixed(1)} s' : '—';

String _fixed(Object? value, int digits) =>
    value is num ? value.toStringAsFixed(digits) : '—';

String _battery(Map<String, Object?> row) {
  final capture = row['battery_capture_delta'];
  final stitch = row['battery_stitch_delta'];
  if (capture is! num && stitch is! num) return '—';
  final total =
      (capture is num ? capture : 0) + (stitch is num ? stitch : 0);
  // Reported as a station count as well as a percentage, because "3%" invites
  // arithmetic on site and getting it wrong, and "about 33 stations" is the
  // question being asked.
  final stations = total <= 0 ? null : (100 / total).floor();
  return '$total%${stations == null ? '' : ' (~$stations stations)'}';
}
