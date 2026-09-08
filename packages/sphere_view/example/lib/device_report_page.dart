import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

import 'camera_probe_page.dart';

/// Flow 6: one screen that answers "will this work on my tablet".
///
/// It has two halves, and the split is the same one Phase 12 §1 draws.
///
/// The **top** is [SphereCapabilityProbe], which is what a consuming app should
/// call at its feature entry point: motion capabilities, camera *descriptors*
/// and total RAM, with no camera opened. It is cheap enough to run before
/// showing a button, which is the whole point — discovering on site that a
/// tablet cannot do this is acceptable, discovering it after 25 captures is
/// not.
///
/// The **bottom** costs a camera open and is therefore a button rather than
/// something that happens on load. It is the only place the burst wall clock
/// exists: R3 established that no source anywhere publishes a measured number
/// for a three-frame bracket, so every device that runs this screen is adding
/// the first data point it will ever have.
class DeviceReportPage extends StatefulWidget {
  /// Creates the device report screen.
  const DeviceReportPage({super.key});

  @override
  State<DeviceReportPage> createState() => _DeviceReportPageState();
}

class _DeviceReportPageState extends State<DeviceReportPage> {
  /// Spike C's budget for a three-shot bracket, in milliseconds. Above it the
  /// hand moves far enough between exposures that fusion has to work harder.
  static const double burstBudgetMs = 600;

  SphereCapabilityReport? _capability;
  ProbedCamera? _probed;
  BracketCapture? _burst;
  ThermalState? _thermal;
  String? _error;
  String _status = 'Probing…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _probeCapability();
  }

  Future<void> _probeCapability() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Probing…';
    });
    try {
      final report = await SphereCapabilityProbe.probe();
      if (!mounted) return;
      setState(() {
        _capability = report;
        _status = report.headline;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the camera, reads what the intrinsics chain made of it, and times a
  /// real bracket.
  ///
  /// The camera is closed again in `finally` whatever happens. A screen that
  /// answers "can this device do it" and then keeps the camera is a screen that
  /// makes the very next capture fail.
  Future<void> _measure() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Opening the camera…';
    });
    final platform = PigeonCameraPlatform();
    try {
      final probed = await CameraProbe(platform).openBestCamera();
      if (mounted) {
        setState(() {
          _probed = probed;
          _status = 'Metering and locking…';
        });
      }

      final exposure = ExposureController(platform);
      await exposure.meterAndLock();

      if (mounted) setState(() => _status = 'Firing a bracket…');
      final biases = exposure.bracketBiases(
        const SphereCaptureConfig(),
        mode: probed.opened.bracketMode,
        maxBracketCount: probed.opened.maxBracketCount,
      );
      final directory = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'device_report'),
      );
      await directory.create(recursive: true);
      final burst = await platform.captureBracket(
        biases,
        outputDirectory: directory.path,
        namePrefix: 'burst',
      );
      final thermal = await platform.thermalState();

      // The frames were fired to time the burst, not to keep. Leaving three
      // full-size JPEGs behind every time somebody opens this screen would be
      // the demo quietly filling a tablet.
      for (final frame in burst.frames) {
        try {
          await File(frame.filePath).delete();
        } on Object {
          // Best effort.
        }
      }

      if (!mounted) return;
      setState(() {
        _burst = burst;
        _thermal = thermal;
        _status = 'Measured.';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _status = 'Measurement failed.';
        });
      }
    } finally {
      try {
        await platform.close();
      } on Object {
        // Nothing useful to do; the screen is done with the camera either way.
      }
      await platform.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final capability = _capability;
    final probed = _probed;
    final burst = _burst;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera),
            tooltip: 'Live camera probe',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CameraProbePage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, style: theme.textTheme.titleMedium),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),

          if (capability != null) ...[
            _Facts('The verdict', {
              'Can capture a 360': capability.isSupported ? 'yes' : 'no',
              'Capability': capability.capability.name,
              'Why not': ?capability.blockingReason,
              // `ExposureStrategy` is sealed and every variant is exported, so
              // a host app can switch on it exhaustively rather than reading a
              // string. This is what that looks like.
              //
              // `exposureFor` answers "can this device do what was asked",
              // which is why it takes the request. Asking with `bracket3` is
              // therefore asking the interesting question: a device that can
              // bracket says so, and one that cannot shows what it would be
              // downgraded to instead.
              'Exposure strategy it can honour': switch (capability.exposureFor(
                const ExposureStrategy.bracket3(),
              )) {
                Bracket3Exposure(:final evSpread) =>
                  '3-shot bracket, ±${evSpread.toStringAsFixed(1)} EV',
                AutoExposure() =>
                  'one automatically metered exposure per position',
                LockedExposure() => 'one locked exposure — no HDR here',
              },
              // And what a session started with the defaults will actually run,
              // which is the number that matters on site. It is `auto` unless a
              // caller asked for something else — `configFrom` only downgrades.
              'Exposure a default session runs':
                  capability.configFrom(const SphereCaptureConfig()).exposure
                      .runtimeType
                      .toString(),
            }),
            const Divider(height: 32),

            _Facts('Output size', {
              // Architecture §6.5: the tier is a memory decision, not a user
              // setting, so this is the number that decides how big the
              // panorama comes out on *this* tablet.
              'Quality tier': capability.tier.name,
              'Total RAM': '${capability.totalPhysicalMemoryMb} MB',
            }),
            const Divider(height: 32),

            _Facts('Motion', {
              'Gyroscope': _yesNo(capability.poseSupport.hasGyroscope),
              'Fused rotation vector':
                  _yesNo(capability.poseSupport.hasFusedRotation),
              'Gravity': _yesNo(capability.poseSupport.hasGravity),
              // Math §1.1 rejects the magnetometer indoors; a `true` here means
              // the platform half reached for the wrong sensor.
              'Uses the magnetometer':
                  _yesNo(capability.poseSupport.usesMagnetometer),
              'Reference frame': capability.poseSupport.frame.name,
              'Fastest sample': '${capability.poseSupport.minDelayUs} µs',
              'Platform detail': capability.poseSupport.detail,
            }),
            const Divider(height: 32),

            _Facts('Bracketing', {
              'Hardware bracket': _yesNo(capability.supportsBracketing),
              'Frames per bracket': '${capability.maxBracketCount}',
              // R3 §8: `LIMITED` may or may not carry MANUAL_SENSOR, and
              // without it a three-exposure request returns one frame.
              'MANUAL_SENSOR': _yesNo(capability.hasManualSensor),
              'Hardware level': capability.hardwareLevel,
              'Lens distortion model': _yesNo(capability.hasDistortionModel),
              'Camera': capability.cameraId,
            }),

            if (capability.warnings.isNotEmpty) ...[
              const Divider(height: 32),
              Text('What this device costs you',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final warning in capability.warnings)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(warning.message),
                ),
            ],
          ],

          const Divider(height: 32),
          Text('Measured, not reported', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Opens the camera, locks it, and fires one real bracket. The burst '
            'wall clock is the number R3 found no published source for.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || capability?.isSupported != true ? null : _measure,
            child: const Text('Measure this device'),
          ),
          const SizedBox(height: 16),

          if (probed != null)
            _Facts('Intrinsics, as measured', {
              // R2: the rung this device reaches is the single best predictor
              // of how the joins come out.
              'Chain branch': probed.opened.intrinsicsBranch,
              'Source': probed.opened.intrinsics.source.name,
              'fx': probed.opened.intrinsics.fx.toStringAsFixed(1),
              'fy': probed.opened.intrinsics.fy.toStringAsFixed(1),
              'cx': probed.opened.intrinsics.cx.toStringAsFixed(1),
              'cy': probed.opened.intrinsics.cy.toStringAsFixed(1),
              'Horizontal field of view':
                  '${probed.opened.intrinsics.hfovDegrees.toStringAsFixed(2)}°',
              'Vertical field of view':
                  '${probed.opened.intrinsics.vfovDegrees.toStringAsFixed(2)}°',
              'Distortion':
                  probed.opened.intrinsics.distortion?.toString() ?? 'none',
              'Capture size': '${probed.opened.captureSize}',
              'Bracket mode': probed.opened.bracketMode.name,
            }),

          if (burst != null) ...[
            const SizedBox(height: 16),
            _Facts('The burst', {
              'Wall clock': '${burst.burstWallClockMs.toStringAsFixed(0)} ms '
                  '(budget ${burstBudgetMs.toStringAsFixed(0)} ms — '
                  '${burst.burstWallClockMs <= burstBudgetMs ? 'within' : 'over'})',
              'Frames': '${burst.frames.length}',
              'Shutter to shutter': burst.shutterToShutterMs
                  .map((ms) => '${ms.toStringAsFixed(0)} ms')
                  .join(', '),
              'Produced by': burst.mode.name,
              'Exposure clamped': _yesNo(burst.clampedExposure),
              // If ISO clamped, the requested EV separation was NOT achieved
              // and the bracket holds less dynamic range than the caller thinks.
              'ISO clamped': _yesNo(burst.clampedIso),
              'Deferred encode':
                  '${burst.deferredEncodeMs.toStringAsFixed(0)} ms',
              'Note': ?burst.note,
              'Thermal state after': ?_thermal?.name,
            }),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static String _yesNo(bool value) => value ? 'yes' : 'no';
}

class _Facts extends StatelessWidget {
  const _Facts(this.title, this.rows);

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final entry in rows.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 180,
                  child: Text(entry.key, style: theme.textTheme.bodySmall),
                ),
                Expanded(child: SelectableText(entry.value)),
              ],
            ),
          ),
      ],
    );
  }
}
