import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// A hands-on view of the Phase 06 camera: what the device reported, what the
/// intrinsics chain made of it, and a live preview.
///
/// It exists for one thing the integration test cannot do. The test calls
/// `attachPreview()` and asserts it returns a texture id, which proves the
/// channel works and proves nothing about whether anything is *drawn* — §4's
/// requirement is that preview arrives through the platform texture APIs rather
/// than as bytes over the channel, and the only way to confirm that is to look
/// at it. Everything else here is a convenience: when a device run fails, this
/// screen is much faster to reason about than a JSON file.
class CameraProbePage extends StatefulWidget {
  /// Creates the probe page.
  const CameraProbePage({super.key});

  @override
  State<CameraProbePage> createState() => _CameraProbePageState();
}

class _CameraProbePageState extends State<CameraProbePage> {
  final _platform = PigeonCameraPlatform();
  // One controller for the whole screen. `warnings` reads the lock the platform
  // actually granted, so a fresh instance per call would always report none.
  late final _exposure = ExposureController(_platform);

  ProbedCamera? _probed;
  MeteringResult? _metering;
  BracketCapture? _capture;
  ThermalState? _thermal;
  int? _textureId;
  String? _error;
  String _status = 'Tap Open to start.';
  bool _busy = false;

  StreamSubscription<SessionInterruption>? _interruptions;
  StreamSubscription<CameraPlatformError>? _errors;

  @override
  void initState() {
    super.initState();
    // §7 pitfall 3: on iPad another app taking the camera is common. Surfaced
    // here so it reads as an interruption rather than as a frozen preview.
    _interruptions = _platform.interruptions.listen((event) {
      if (mounted) {
        setState(() => _status = event.interrupted
            ? 'Interrupted: ${event.reason}'
            : 'Resumed: ${event.reason}');
      }
    });
    _errors = _platform.errors.listen((event) {
      if (mounted) setState(() => _error = '${event.code}: ${event.message}');
    });
  }

  @override
  void dispose() {
    _interruptions?.cancel();
    _errors?.cancel();
    unawaited(_platform.close().catchError((_) {}));
    unawaited(_platform.dispose());
    super.dispose();
  }

  Future<void> _guard(String label, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = '$label…';
    });
    try {
      await action();
      if (mounted) setState(() => _status = '$label done.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _guard('Opening', () async {
    final probe = CameraProbe(_platform);
    final probed = await probe.openBestCamera(
      format: const CaptureFormatSpec(computeFrameStatistics: true),
    );
    final textureId = await _platform.attachPreview();
    final thermal = await _platform.thermalState();
    if (!mounted) return;
    setState(() {
      _probed = probed;
      _textureId = textureId;
      _thermal = thermal;
      _metering = null;
      _capture = null;
    });
  });

  Future<void> _meter() => _guard('Metering', () async {
    final result = await _exposure.meterAndLock();
    if (!mounted) return;
    setState(() => _metering = result);
  });

  Future<void> _capture3() => _guard('Capturing', () async {
    final probed = _probed;
    if (probed == null) throw StateError('open the camera first');
    final biases = _exposure.bracketBiases(
      const SphereCaptureConfig(),
      mode: probed.opened.bracketMode,
      maxBracketCount: probed.opened.maxBracketCount,
    );
    final directory = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/probe',
    )..createSync(recursive: true);
    final capture = await _platform.captureBracket(
      biases,
      outputDirectory: directory.path,
      namePrefix: 'probe',
    );
    if (!mounted) return;
    setState(() => _capture = capture);
  });

  @override
  Widget build(BuildContext context) {
    final probed = _probed;
    final textureId = _textureId;

    return Scaffold(
      appBar: AppBar(title: const Text('Camera probe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (textureId != null)
            AspectRatio(
              aspectRatio: probed == null
                  ? 4 / 3
                  : probed.opened.previewSize.aspectRatio,
              // The whole reason this screen exists: if this renders, preview is
              // coming through the platform texture APIs as §4 requires.
              child: Texture(textureId: textureId),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _open,
                child: const Text('Open'),
              ),
              FilledButton(
                onPressed: _busy || probed == null ? null : _meter,
                child: const Text('Meter + lock'),
              ),
              FilledButton(
                onPressed: _busy || _metering == null ? null : _capture3,
                child: const Text('Capture bracket'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(_status),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_thermal != null) ...[
            const Divider(height: 32),
            _Section('Thermal', {
              'state': _thermal!.name,
              'capture': ThermalPolicy.forCapture(_thermal!).message,
              'stitch': ThermalPolicy.forStitch(_thermal!).message,
            }),
          ],
          if (probed != null) ...[
            const Divider(height: 32),
            _Section('Intrinsics', {
              // R2's whole point: which rung of the chain this device reached
              // is the thing that explains a soft panorama later.
              'branch': probed.opened.intrinsicsBranch,
              'source': probed.opened.intrinsics.source.name,
              'HFOV': '${probed.opened.intrinsics.hfovDegrees.toStringAsFixed(2)}°',
              'VFOV': '${probed.opened.intrinsics.vfovDegrees.toStringAsFixed(2)}°',
              'fx': probed.opened.intrinsics.fx.toStringAsFixed(1),
              'fy': probed.opened.intrinsics.fy.toStringAsFixed(1),
              'cx': probed.opened.intrinsics.cx.toStringAsFixed(1),
              'cy': probed.opened.intrinsics.cy.toStringAsFixed(1),
              'distortion': probed.opened.intrinsics.distortion?.toString() ?? 'none',
              'capture': '${probed.opened.captureSize}',
              '4:3': '${probed.opened.captureAspectIsFourThree}',
              'bracket': '${probed.opened.bracketMode.name} '
                  '(max ${probed.opened.maxBracketCount})',
              'clock': '${probed.opened.clock}',
            }),
            if (probed.opened.intrinsicsNotes.isNotEmpty)
              _Notes('Intrinsics notes', probed.opened.intrinsicsNotes),
            if (probed.opened.warning != null)
              _Notes('Open warnings', [probed.opened.warning!]),
            if (probed.selection.rejected.isNotEmpty)
              _Notes('Cameras not chosen', probed.selection.rejected),
          ],
          if (_metering != null) ...[
            const Divider(height: 32),
            _Section('Metering', {
              'exposure': '${(_metering!.exposureTimeNs / 1e6).toStringAsFixed(2)} ms',
              'ISO': '${_metering!.iso}',
              'lock': _metering!.lockQuality.name,
              'pinned ISP modes': '${_metering!.pinnedProcessingModes}',
              'samples': '${_metering!.sampleCount}',
              // §2.3's decision, made visible: a wide gap here means the scene
              // really did have the bright-window skew the percentile resists.
              'p65 EV': _metering!.percentile65Ev.toStringAsFixed(2),
              'mean EV': _metering!.meanEv.toStringAsFixed(2),
            }),
            _Notes('Lock warnings', _exposure.warnings),
          ],
          if (_capture != null) ...[
            const Divider(height: 32),
            _Section('Bracket', {
              'wall clock': '${_capture!.burstWallClockMs.toStringAsFixed(0)} ms '
                  '(budget 600)',
              'shutter-to-shutter': _capture!.shutterToShutterMs
                  .map((v) => v.toStringAsFixed(0))
                  .join(', '),
              'mode': _capture!.mode.name,
              'clamped': 'exposure ${_capture!.clampedExposure}, '
                  'ISO ${_capture!.clampedIso}',
              'EV separation ok': '${_capture!.achievedRequestedSeparation}',
              if (_capture!.deferredEncodeMs > 0)
                'deferred encode': '${_capture!.deferredEncodeMs.toStringAsFixed(0)} ms',
            }),
            for (final frame in _capture!.frames)
              _Section('Frame ${frame.evBias >= 0 ? '+' : ''}${frame.evBias} EV', {
                'achieved EV': frame.achievedEvBias?.toStringAsFixed(2) ?? '—',
                'exposure': frame.exposureTimeNs == null
                    ? '—'
                    : '${(frame.exposureTimeNs! / 1e6).toStringAsFixed(2)} ms',
                'ISO': '${frame.iso ?? '—'}',
                'timestamp': '${frame.timestampUs} µs',
                'bytes': '${frame.byteCount}',
                'mean luma': frame.meanLuma?.toStringAsFixed(1) ?? '—',
                if (frame.note != null) 'note': frame.note!,
              }),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      for (final entry in rows.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(
                  entry.key,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: Text(
                  entry.value,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
    ],
  );
}

class _Notes extends StatelessWidget {
  const _Notes(this.title, this.notes);

  final String title;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• $note', style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
