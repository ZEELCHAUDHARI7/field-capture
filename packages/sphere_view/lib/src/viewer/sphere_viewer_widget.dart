import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api/models/device_pose.dart';
import '../camera/camera_platform.dart';
import '../metadata/gpano_writer.dart';
import '../metadata/panorama_metadata.dart';
import '../tracking/platform_ahrs_pose_source.dart';
import '../tracking/pose_source.dart';
import 'panorama_texture.dart';
import 'viewer_controller.dart';

/// Loads the equirect fragment shader bundled with this package.
///
/// Consumer apps see package assets under `packages/sphere_view/…`, while
/// the package's own tests/example resolve the bare declared path — try
/// both so the viewer works everywhere.
Future<ui.FragmentProgram> loadEquirectFragmentProgram() async {
  const packageKey =
      'packages/sphere_view/lib/src/viewer/shaders/equirect.frag';
  const bareKey = 'lib/src/viewer/shaders/equirect.frag';
  try {
    return await ui.FragmentProgram.fromAsset(packageKey);
  } catch (_) {
    return ui.FragmentProgram.fromAsset(bareKey);
  }
}

/// Interactive 360° equirectangular image viewer.
///
/// Rendering happens in a GLSL fragment shader
/// (`lib/src/viewer/shaders/equirect.frag`) that samples the panorama with
/// a yaw/pitch/roll-controlled camera — the same technique used by Street
/// View and Insta360 web viewers, and the one part of the original package
/// that was architecturally sound.
///
/// The mapping it uses is **exactly** §3 of `01_MATH_AND_CONVENTIONS.md`, and
/// that is a correctness property rather than a tidiness one. A sign flip here
/// produces a mirrored view that looks entirely plausible — rooms are roughly
/// symmetric, and nobody notices a flipped panorama until they try to walk to
/// something — and it would silently invalidate every visual review of the
/// stitcher's output that anyone had ever done. `viewer_mapping_test.dart`
/// guards it with rendered direction markers.
class SphereViewer extends StatefulWidget {
  /// Creates a viewer over a panorama.
  const SphereViewer({
    super.key,
    this.image,
    this.imageProvider,
    this.previewImage,
    this.controller,
    this.gyroscopeEnabled = false,
    this.poseSource,
    this.platform,
    this.textureLimit,
    this.dragSensitivity = 0.005,
    this.doubleTapToReset = true,
    this.showControls = false,
    this.showLoadingIndicator = true,
    this.errorBuilder,
    this.onMetadata,
    this.onWarning,
  }) : assert(
         image != null || imageProvider != null,
         'Provide either a File via `image` or an `imageProvider`.',
       );

  /// Panorama file on disk (JPEG or PNG).
  final File? image;

  /// Alternative: any Flutter [ImageProvider] (asset, network, memory).
  final ImageProvider? imageProvider;

  /// The fast low-resolution pass, shown while [image] decodes.
  ///
  /// Phase 04 §7's 2048×1024 preview, written beside the panorama. Supplying it
  /// is the difference between a sphere that appears in ~50 ms and one that
  /// appears in ~800 ms, which is the difference between "instant" and
  /// "sluggish" (§3.1) — and 800 ms of blank screen after a tap is long enough
  /// that people tap again.
  ///
  /// When it is `null` the viewer looks for the file `sphere_view` actually
  /// writes — `<name>_preview.jpg` beside the panorama — so the common case
  /// needs no wiring at all.
  final File? previewImage;

  /// Camera state. Supply one to drive the view programmatically, or to open
  /// at a chosen compass heading via
  /// [SphereViewerController.forPanorama].
  final SphereViewerController? controller;

  /// When `true`, moving the device moves the view.
  ///
  /// Off by default, and deliberately so: it is delightful when expected and
  /// disorienting when not — a viewer that starts panning because the user
  /// shifted in their chair reads as a bug (§3.2).
  final bool gyroscopeEnabled;

  /// The pose source gyro look uses. Defaults to the same platform AHRS source
  /// capture runs on (Phase 07), so enabling it costs nothing new.
  final PoseSource? poseSource;

  /// Where the texture limit is probed. `null` uses the real platform channel.
  final SphereCameraPlatform? platform;

  /// Overrides the GPU texture ceiling. Tests use it to pose as a
  /// 4096-limited device; a real device should leave it `null` and be asked.
  final TextureLimit? textureLimit;

  /// Radians of view movement per logical pixel of drag.
  final double dragSensitivity;

  /// Whether a double tap returns to the opening view.
  final bool doubleTapToReset;

  /// Shows built-in overlay controls: zoom in/out, auto-rotate toggle,
  /// and reset-to-home.
  final bool showControls;

  /// Whether to show a spinner until the first image is ready.
  final bool showLoadingIndicator;

  /// Builds the error state. Defaults to a plain message.
  final Widget Function(BuildContext, Object)? errorBuilder;

  /// Called with the panorama's own GPano/EXIF metadata once it is read.
  ///
  /// Exposed because the metadata is what tells a caller which way the image
  /// faces, when it was taken and which station it belongs to — and a viewer
  /// that reads it and keeps it to itself would force every host app to parse
  /// the file a second time.
  final void Function(PanoramaMetadata metadata)? onMetadata;

  /// Called with any compromise the viewer made, in plain language.
  ///
  /// Architecture §8 again: the one that matters here is a downscale forced by
  /// the GPU, because a manager judging a defect deserves to know they are
  /// looking at a reduced rendering rather than the file.
  final void Function(String warning)? onWarning;

  @override
  State<SphereViewer> createState() => _SphereViewerState();
}

class _SphereViewerState extends State<SphereViewer>
    with SingleTickerProviderStateMixin {
  ui.FragmentProgram? _program;
  PanoramaTexture? _texture;
  Object? _loadError;
  late final SphereViewerController _controller;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _zoomStart = 1.0;

  PoseSource? _poseSource;
  StreamSubscription<DevicePose>? _poseSubscription;
  bool _poseStarted = false;
  double? _poseYawDatum;

  /// Set as soon as `dispose` runs, so an in-flight decode that completes
  /// afterwards disposes its image instead of leaking it. `mounted` alone is
  /// not enough: it answers whether the element is still in the tree, and the
  /// image has to be freed either way.
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? SphereViewerController();
    // Created but not started. The ticker runs only while something is
    // actually moving — see [_syncTicker].
    _ticker = createTicker(_onTick);
    _controller.addListener(_syncTicker);
    _load();
    if (widget.gyroscopeEnabled) _startGyro();
  }

  /// Starts and stops the ticker with the controller's [needsTick].
  ///
  /// A panorama sitting still is the common state — somebody reading a defect
  /// off a wall is not dragging — and a ticker that wakes every frame to
  /// recompute nothing costs battery on a tablet that is out all day. It also
  /// means a host app's `pumpAndSettle` terminates, which a permanently
  /// running ticker quietly makes impossible for every widget test in the
  /// embedding app.
  void _syncTicker() {
    if (_disposed) return;
    final wanted = _controller.needsTick;
    if (wanted && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!wanted && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(SphereViewer old) {
    super.didUpdateWidget(old);
    if (widget.gyroscopeEnabled != old.gyroscopeEnabled) {
      widget.gyroscopeEnabled ? _startGyro() : _stopGyro();
    }
    if (widget.image?.path != old.image?.path ||
        widget.imageProvider != old.imageProvider) {
      _load();
    }
  }

  /// Loads the panorama in two passes: the preview, then the full image.
  ///
  /// The passes are sequential rather than concurrent on purpose. They compete
  /// for the same decode thread and the same memory, and running them together
  /// would make the preview — whose entire reason for existing is to arrive
  /// early — arrive alongside the thing it was covering for.
  Future<void> _load() async {
    try {
      _program ??= await loadEquirectFragmentProgram();
      final limit =
          widget.textureLimit ?? await TextureLimit.probe(platform: widget.platform);
      final loader = PanoramaLoader(limit);

      final previewBytes = await _previewBytes();
      if (previewBytes != null) {
        final preview = await loader.decode(previewBytes, isPreview: true);
        _adopt(preview);
      }

      final fullBytes = await _fullBytes();
      if (fullBytes != null) {
        _readMetadata(fullBytes);
        final full = await loader.decode(fullBytes);
        if (full.downscaleNote != null) widget.onWarning?.call(full.downscaleNote!);
        _adopt(full);
      } else {
        // An ImageProvider gives no bytes to inspect, so the metadata and the
        // texture limit cannot be applied to it. Resolving it directly is the
        // honest fallback rather than a silent failure — and a caller passing
        // an asset already knows what size it is.
        _adopt(await _fromProvider());
      }
    } catch (e) {
      if (_disposed || !mounted) return;
      if (_texture != null) {
        // The preview is up and the full-resolution pass failed. Keeping the
        // preview is right — a soft panorama beats an error page — but it must
        // not be silent (architecture §8): what the user is looking at is a
        // 2048-wide rendering, and if they zoom in to read a defect off it they
        // are entitled to know why it will not sharpen.
        widget.onWarning?.call(
          'The full-resolution panorama could not be loaded ($e), so this is '
          'the low-resolution preview. The saved file is unaffected.',
        );
        return;
      }
      setState(() => _loadError = e);
    }
  }

  /// Installs [next], disposing whatever it replaces.
  ///
  /// A late preview never displaces a full image. The two passes are ordered,
  /// but an old preview decode can still land after a new full one when the
  /// widget is rebuilt with a different file, and a preview overwriting the
  /// sharp image would look like the viewer degrading on its own.
  void _adopt(PanoramaTexture next) {
    if (_disposed || !mounted) {
      next.dispose();
      return;
    }
    final current = _texture;
    if (current != null && !current.isPreview && next.isPreview) {
      next.dispose();
      return;
    }
    setState(() {
      _texture = next;
      _loadError = null;
    });
    current?.dispose();
  }

  Future<Uint8List?> _fullBytes() async {
    final file = widget.image;
    if (file == null) return null;
    return file.readAsBytes();
  }

  /// The preview file, if one was supplied or if the pipeline wrote one.
  Future<Uint8List?> _previewBytes() async {
    final explicit = widget.previewImage;
    if (explicit != null && await explicit.exists()) {
      return explicit.readAsBytes();
    }
    final full = widget.image;
    if (full == null) return null;
    // `compositing.cpp` writes `<stem>_preview.jpg` beside the output. Guessing
    // the name is worth it: it makes the fast path automatic for every caller
    // who does nothing, and getting it wrong costs only the guess.
    final path = full.path;
    final dot = path.lastIndexOf('.');
    if (dot <= 0) return null;
    final candidate = File('${path.substring(0, dot)}_preview.jpg');
    if (!await candidate.exists()) return null;
    return candidate.readAsBytes();
  }

  void _readMetadata(Uint8List bytes) {
    final callback = widget.onMetadata;
    if (callback == null) return;
    try {
      final metadata = const GPanoReader().read(bytes);
      if (metadata != null) callback(metadata);
    } on Object {
      // A file with no readable metadata is still a viewable panorama. This is
      // the one place the viewer is handed arbitrary bytes from outside the
      // package, so it must not refuse to display an image over a bad header.
    }
  }

  Future<PanoramaTexture> _fromProvider() async {
    final completer = Completer<ui.Image>();
    final stream = widget.imageProvider!.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (e, s) {
        if (!completer.isCompleted) completer.completeError(e, s);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future;
    return PanoramaTexture(
      image: image,
      sourceWidth: image.width,
      sourceHeight: image.height,
      isPreview: false,
    );
  }

  // ── gyro look ─────────────────────────────────────────────────────────────

  /// Starts driving the view from the device's own orientation.
  ///
  /// The yaw datum is captured from the first sample rather than taken as
  /// zero. A pose source's yaw 0 is wherever the device happened to point when
  /// *it* started (Math §1.1), which has nothing to do with where the user is
  /// looking in this panorama — so without the datum, switching gyro look on
  /// would snap the view to an arbitrary direction, which is precisely the
  /// disorientation §3.2 warns about.
  Future<void> _startGyro() async {
    if (_poseStarted) return;
    _poseStarted = true;
    try {
      final source = widget.poseSource ?? PlatformAhrsPoseSource();
      _poseSource = source;
      if (!await source.isSupported) {
        _poseStarted = false;
        widget.onWarning?.call(
          'This device has no gyroscope, so moving it cannot move the view. '
          'Drag to look around instead.',
        );
        return;
      }
      await source.start();
      if (_disposed) {
        await _stopGyro();
        return;
      }
      _poseYawDatum = null;
      _poseSubscription = source.poses.listen(_onPose);
    } on Object catch (e) {
      _poseStarted = false;
      widget.onWarning?.call('Gyro look could not be started: $e');
    }
  }

  void _onPose(DevicePose pose) {
    if (_disposed) return;
    _poseYawDatum ??= pose.yaw - _controller.yaw;
    _controller.setOrientation(
      yaw: pose.yaw - _poseYawDatum!,
      pitch: pose.pitch,
    );
  }

  /// Releases the sensor and the subscription.
  ///
  /// Both, and in that order. §3.4 asks specifically that gyro look "does not
  /// leak the sensor subscription", and the leak that actually happens is the
  /// other one: cancelling the Dart stream while leaving the platform sensor
  /// registered leaves a tablet sampling its IMU at 100 Hz for the rest of the
  /// app's life, which is a battery complaint nobody would ever trace to a
  /// closed panorama.
  Future<void> _stopGyro() async {
    _poseStarted = false;
    _poseYawDatum = null;
    final subscription = _poseSubscription;
    _poseSubscription = null;
    await subscription?.cancel();
    final source = _poseSource;
    _poseSource = null;
    // Only a source this widget created is stopped. One passed in belongs to
    // the caller, who may well be using it for something else.
    if (source != null && widget.poseSource == null) {
      await source.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.016
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    // Gyro look owns the orientation outright while it is on; running inertia
    // underneath it would fight the sensor.
    if (_poseSubscription == null) _controller.applyInertiaTick(dt);
    _syncTicker();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.removeListener(_syncTicker);
    _ticker.dispose();
    unawaited(_stopGyro());
    if (widget.controller == null) _controller.dispose();
    _texture?.dispose();
    _texture = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final texture = _texture;
    if (_loadError != null && texture == null) {
      return widget.errorBuilder?.call(context, _loadError!) ??
          Center(
            child: Text(
              'Failed to load panorama: $_loadError',
              style: const TextStyle(color: Colors.white70),
            ),
          );
    }
    if (_program == null || texture == null) {
      return widget.showLoadingIndicator
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.doubleTapToReset ? _controller.resetToHome : null,
          onScaleStart: (_) => _zoomStart = 1.0,
          onScaleUpdate: (details) {
            if (details.scale != 1.0) {
              _controller.zoom(details.scale / _zoomStart);
              _zoomStart = details.scale;
            }
            if (details.focalPointDelta != Offset.zero &&
                _poseSubscription == null) {
              // §3.2's inverted drag: the content follows the finger, so
              // dragging left turns the view right. Every panorama viewer
              // behaves this way; one that does not feels broken.
              _controller.drag(
                details.focalPointDelta.dx * widget.dragSensitivity,
                details.focalPointDelta.dy * widget.dragSensitivity,
              );
            }
          },
          child: CustomPaint(
            painter: SpherePainter(
              program: _program!,
              panorama: texture.image,
              controller: _controller,
            ),
            size: Size.infinite,
          ),
        ),
        if (widget.showControls) _buildControls(),
      ],
    );
  }

  Widget _buildControls() {
    return Positioned(
      right: 12,
      bottom: 24,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _controlButton(
              icon: Icons.add,
              tooltip: 'Zoom in',
              onTap: () => _controller.zoom(1.2),
            ),
            const SizedBox(height: 8),
            _controlButton(
              icon: Icons.remove,
              tooltip: 'Zoom out',
              onTap: () => _controller.zoom(1 / 1.2),
            ),
            const SizedBox(height: 8),
            _controlButton(
              icon: _controller.isAutoRotating ? Icons.pause : Icons.threesixty,
              tooltip: 'Auto-rotate',
              onTap: () {
                _controller.autoRotateSpeed = _controller.isAutoRotating
                    ? 0
                    : 0.25;
              },
            ),
            const SizedBox(height: 8),
            _controlButton(
              icon: Icons.center_focus_strong,
              tooltip: 'Reset view',
              onTap: _controller.resetToHome,
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Paints the sphere by handing the panorama to the equirect fragment shader.
///
/// Public so the mapping test can drive exactly the code the viewer draws
/// with. A test that rebuilt the uniform order itself would pass while the
/// widget passed `pitch` where the shader reads `roll`.
class SpherePainter extends CustomPainter {
  /// Creates a painter.
  SpherePainter({
    required this.program,
    required this.panorama,
    required this.controller,
  }) : super(repaint: controller);

  /// The compiled equirect shader.
  final ui.FragmentProgram program;

  /// The panorama texture.
  final ui.Image panorama;

  /// Camera state.
  final SphereViewerController controller;

  /// Uniform slots, in the order `equirect.frag` declares them.
  ///
  /// Named because the failure mode of getting them wrong is not a crash: the
  /// shader reads whatever float sits at that index, so passing pitch where
  /// roll is expected produces a view that tilts when it should tip. It looks
  /// like a bug in the maths rather than in an argument list.
  /// Canvas width, in pixels.
  static const int uResolutionX = 0;

  /// Canvas height, in pixels.
  static const int uResolutionY = 1;

  /// Camera yaw, radians.
  static const int uYaw = 2;

  /// Camera pitch, radians.
  static const int uPitch = 3;

  /// Camera roll, radians.
  static const int uRoll = 4;

  /// Vertical field of view, radians.
  static const int uFov = 5;

  /// Panorama width, in pixels.
  static const int uPanoWidth = 6;

  /// Panorama height, in pixels.
  static const int uPanoHeight = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    shader.setFloat(uResolutionX, size.width);
    shader.setFloat(uResolutionY, size.height);
    shader.setFloat(uYaw, controller.yaw);
    shader.setFloat(uPitch, controller.pitch);
    shader.setFloat(uRoll, controller.roll);
    shader.setFloat(uFov, controller.fov);
    shader.setFloat(uPanoWidth, panorama.width.toDouble());
    shader.setFloat(uPanoHeight, panorama.height.toDouble());
    shader.setImageSampler(0, panorama);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant SpherePainter old) =>
      old.panorama != panorama || old.controller != controller;
}

/// The screen position the viewer's own mapping puts a world direction at, or
/// `null` when it is behind the camera or outside the view.
///
/// This is the test's half of §3.3, and it exists in shipping code rather than
/// in the test file for a reason worth stating: a golden test that computes the
/// expected position with its own formula proves the two formulas agree, which
/// is not the claim. This one inverts the *shader's* transform step by step, so
/// the assertion is between what the GPU drew and where this says it should be.
({double x, double y})? screenPositionOf({
  required double worldYaw,
  required double worldPitch,
  required double cameraYaw,
  required double cameraPitch,
  required double cameraRoll,
  required double fov,
  required Size size,
}) {
  // The shader's frame is the world frame turned half a turn about Y: its
  // camera looks along −Z while Math §3's yaw 0 is +Z. So a world direction
  // enters as (−sin·cos, sin, −cos·cos) — the same 180° rotation, applied
  // once, in the one place it belongs.
  final cp = math.cos(worldPitch);
  var x = -math.sin(worldYaw) * cp;
  var y = math.sin(worldPitch);
  var z = -math.cos(worldYaw) * cp;

  // Undo yaw, then pitch, then roll: the inverse of the shader's order.
  final cy = math.cos(-cameraYaw), sy = math.sin(-cameraYaw);
  var nx = x * cy + z * sy;
  var nz = -x * sy + z * cy;
  x = nx;
  z = nz;

  final cpi = math.cos(-cameraPitch), spi = math.sin(-cameraPitch);
  var ny = y * cpi - z * spi;
  nz = y * spi + z * cpi;
  y = ny;
  z = nz;

  final cr = math.cos(-cameraRoll), sr = math.sin(-cameraRoll);
  nx = x * cr - y * sr;
  ny = x * sr + y * cr;
  x = nx;
  y = ny;

  // The camera looks along −Z, so anything with z ≥ 0 is behind it.
  if (z >= -1e-9) return null;

  final tanHalfFov = math.tan(fov * 0.5);
  final aspect = size.width / size.height;
  final u = x / (-z) / (aspect * tanHalfFov);
  final v = y / (-z) / tanHalfFov;
  if (u.abs() > 1 || v.abs() > 1) return null;

  // Back to pixels: u ∈ [−1, 1] across the width, v ∈ [−1, 1] up the height.
  return (x: (u + 1) / 2 * size.width, y: (1 - v) / 2 * size.height);
}
