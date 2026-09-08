import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../camera/exposure_controller.dart';
import '../ui/capture_hud.dart';
import '../ui/capture_instructions.dart';
import 'models/capture_bundle.dart';
import 'sphere_capture_session.dart';

/// The capture screen: preview, centre ring, helper dot, progress.
///
/// It is a thin widget over [SphereCaptureSession] and holds **no capture
/// logic** — the session decides when to fire, this only draws what the session
/// reports. That split is the point: it lets the whole capture state machine be
/// tested without a camera, and it stops the aim and steadiness rules from
/// being quietly re-implemented in a gesture handler, which is how conventions
/// drift apart.
///
/// Read the build method as a list and it is six things (Phase 09 §2): a
/// segmented progress bar with a counter, a fixed centre ring that fills as the
/// dwell runs, a target dot that moves, an edge arrow when the target is off
/// screen, one line of text, and two buttons. There is no coverage minimap, no thumbnail strip, no grid,
/// no histogram, no filters, no settings gear and no resolution picker. Each of
/// those was considered and rejected: the user's attention has to be on the
/// physical world — where they are standing, what they are about to walk into —
/// and every element on screen is attention taken away from aiming.
///
/// The screen is portrait-locked. A plan is only valid for one intrinsics and
/// orientation pair, and portrait also gives the larger vertical FOV, which
/// means fewer rings and a shorter capture (Phase 09 §4).
class SphereCaptureView extends StatefulWidget {
  /// Creates the capture view for [session].
  const SphereCaptureView({
    required this.session,
    required this.onCompleted,
    super.key,
    this.onCancelled,
    this.onError,
    this.previewBuilder,
    this.previewQuarterTurns,
    this.previewAspectRatio,
    this.lockOrientation = true,
  });

  /// The session to drive. Must already be created, since creating it probes
  /// the camera and can fail.
  final SphereCaptureSession session;

  /// Called with the finished bundle, complete or not.
  final void Function(CaptureBundle bundle) onCompleted;

  /// Called when the user abandons the capture before anything was shot.
  final VoidCallback? onCancelled;

  /// Called when the session fails unrecoverably.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Overrides how the camera preview is rendered.
  ///
  /// The default attaches the session's camera and renders its texture. Tests
  /// pass a flat colour — which is exactly what the golden tests over pure white
  /// and pure black do, since legibility against those two extremes is a
  /// correctness property here rather than a preference (§6).
  final WidgetBuilder? previewBuilder;

  /// Overrides how many clockwise quarter turns the preview texture needs to be
  /// upright.
  ///
  /// `null` — the default — uses what the platform reported about its own sensor
  /// mounting, which is right on every device that reports it honestly. This
  /// exists because that is not all of them, and because a sideways or squashed
  /// preview is the one defect in this package that no test on a desk can catch:
  /// every input to the decision is something the device says about itself.
  ///
  /// Try `1` if the preview is a quarter turn clockwise of where it should be,
  /// `3` for the other way, `2` if it is upside down. Whatever value makes the
  /// preview upright is also the one that makes the guidance dots line up with it,
  /// because both are placed in the same frame.
  final int? previewQuarterTurns;

  /// Preview width / height in the device's portrait frame.
  ///
  /// Defaults to [SphereCaptureSession.previewAspectRatio] — the *preview
  /// stream's* own shape, turned into the device frame. That is the rectangle the
  /// texture actually occupies, and therefore the one the dot has to be placed
  /// against: it used to default to the capture intrinsics' aspect, which is a
  /// different rectangle on any device whose preview and still sizes come from
  /// different output lists, and the error grows toward the frame edges.
  final double? previewAspectRatio;

  /// Whether to lock the device to portrait for the length of the capture.
  ///
  /// On by default and not a shortcut: the plan is computed for one
  /// intrinsics/orientation pair (Phase 08 §7.4), so a mid-session rotation
  /// would invalidate every remaining target. Tests turn it off to keep the
  /// system-channel traffic out of the way.
  final bool lockOrientation;

  @override
  State<SphereCaptureView> createState() => _SphereCaptureViewState();
}

class _SphereCaptureViewState extends State<SphereCaptureView>
    with TickerProviderStateMixin {
  /// The post-shutter confirmation: 120 ms of white on the reticle, and a light
  /// haptic. No shutter sound by default — sites are loud, and the haptic is
  /// what actually registers (§2).
  static const Duration flashDuration = Duration(milliseconds: 120);

  late final CaptureHudModel _model;
  late final AnimationController _flash;
  late final AnimationController _metering;
  StreamSubscription<SessionState>? _states;

  int? _previewTexture;
  SessionPhase _phase = SessionPhase.idle;
  int _lastCapturedCount = 0;
  int? _lastRingIndex;
  bool _finishing = false;
  bool _confirmingExit = false;
  bool _completedNotified = false;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _model = CaptureHudModel(
      plan: session.plan,
      // The device-frame set, which is also what the plan and the guidance use.
      // Handing the overlay the capture-frame intrinsics would put every mark a
      // quarter turn out from the scene it is marking.
      intrinsics: session.deviceIntrinsics,
      state: SessionState(
        phase: session.phase,
        capturedCount: session.positions.length,
        totalCount: session.plan.length,
        currentTarget: session.currentTarget,
      ),
    );
    _phase = session.phase;
    _lastCapturedCount = session.positions.length;
    _lastRingIndex = session.currentTarget?.ringIndex;

    _flash = AnimationController(vsync: this, duration: flashDuration)
      ..addListener(() => _model.flashOpacity = 1 - _flash.value);
    // The sweep bar is a 2 s countdown rather than a report from the camera:
    // `meterAndLock` is one await with no intermediate progress, and the honest
    // alternative — an indeterminate spinner — would not tell the user how long
    // to keep turning, which is the only thing this screen is asking of them.
    _metering = AnimationController(
      vsync: this,
      duration: ExposureController.meteringSweepDuration,
    );

    if (widget.lockOrientation) {
      // `portraitUp` only, and not because upside down is unreasonable to hold.
      //
      // Allowing `portraitDown` used to look free — the plan is the same either
      // way up — but the platform rotates the Flutter view 180° while every mark
      // on this screen is placed from the *physical* device frame: the dot offsets
      // (`guidance_engine.dart`), the left/right hint and the edge-arrow angle. So
      // in that orientation the dot moved opposite to the scene and the arrow
      // pointed away from the target. Supporting it properly means rotating all
      // three by the view's own quarter turns; until something needs it, one
      // orientation is one frame and one frame is correct.
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]),
      );
    }

    _states = session.states.listen(_onState, onError: _onStreamError);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final texture = await widget.session.attachPreview();
      if (mounted) setState(() => _previewTexture = texture);
    } on Object catch (error, stack) {
      // A missing preview is a degraded capture, not a dead one: the reticle,
      // the dot and the gates all still work, and a manager mid-walk would
      // rather shoot blind than lose the station. It is reported, never hidden.
      _report(error, stack);
    }
    try {
      if (widget.session.phase == SessionPhase.idle) {
        _metering.forward(from: 0);
        await widget.session.beginMetering();
      }
      if (!mounted) return;
      if (widget.session.phase == SessionPhase.metering) {
        await widget.session.beginCapture();
      }
    } on Object catch (error, stack) {
      _report(error, stack);
    }
  }

  void _onStreamError(Object error, StackTrace stack) => _report(error, stack);

  void _report(Object error, StackTrace stack) {
    final onError = widget.onError;
    if (onError != null) {
      onError(error, stack);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'sphere_view',
          context: ErrorDescription('during a capture session'),
        ),
      );
    }
  }

  /// The only place this widget reacts to the session at all.
  ///
  /// Everything here is presentation: the model the painter reads, the flash,
  /// the haptics, and handing the finished bundle back. No gate, no threshold
  /// and no decision about when to shoot appears in this file — those are Phase
  /// 08's, and keeping them there is what makes the interaction testable
  /// without a camera.
  void _onState(SessionState state) {
    final captured = state.capturedCount > _lastCapturedCount;
    final complete = state.phase == SessionPhase.completed;
    final ringChanged =
        state.currentTarget != null &&
        _lastRingIndex != null &&
        state.currentTarget!.ringIndex != _lastRingIndex;

    _lastCapturedCount = state.capturedCount;
    if (state.currentTarget != null) {
      _lastRingIndex = state.currentTarget!.ringIndex;
    }
    _model.state = state;

    // The overlay repaints from the model without a rebuild — that is the whole
    // point of the model being a `Listenable`, at ~100 Hz. The widget tree only
    // has to change when the *phase* does: metering ends, an interruption
    // pauses the session, the plan completes. That happens a handful of times
    // in a capture, so it is a rebuild that costs nothing and a stale phase
    // would be a paused session with no way to resume.
    if (state.phase != _phase) {
      _phase = state.phase;
      if (mounted) setState(() {});
    }

    if (captured) {
      _flash.forward(from: 0);
      // One haptic per capture, and the strongest one that applies: finishing
      // the plan is a bigger event than finishing a row, which is a bigger
      // event than one more frame (§5).
      if (complete) {
        unawaited(HapticFeedback.heavyImpact());
      } else if (ringChanged) {
        unawaited(HapticFeedback.mediumImpact());
      } else {
        unawaited(HapticFeedback.lightImpact());
      }
    }

    if (complete && !_completedNotified && !_finishing) {
      _completedNotified = true;
      unawaited(_finish());
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    try {
      final bundle = await widget.session.finish();
      if (!mounted) return;
      widget.onCompleted(bundle);
    } on Object catch (error, stack) {
      _finishing = false;
      _report(error, stack);
    }
  }

  /// The exit button.
  ///
  /// With nothing captured there is nothing to lose, so it just leaves. With
  /// positions on disk it asks once — a mis-tap in gloves, on a screen the user
  /// is holding at arm's length while turning, must not be able to end a site
  /// visit. The confirmation is a transient state rather than a seventh element:
  /// nothing is added to the aiming screen, and it only exists after a
  /// deliberate press.
  void _onExit() {
    if (widget.session.positions.isEmpty) {
      unawaited(_abandon());
      return;
    }
    setState(() => _confirmingExit = true);
  }

  Future<void> _abandon() async {
    try {
      await widget.session.abort();
    } on Object catch (error, stack) {
      _report(error, stack);
    }
    if (!mounted) return;
    widget.onCancelled?.call();
  }

  @override
  void dispose() {
    unawaited(_states?.cancel());
    _flash.dispose();
    _metering.dispose();
    _model.dispose();
    // Swallowed rather than reported: the screen is going away, the session may
    // already have closed the camera underneath it, and a failure to release a
    // texture must not become an unhandled error on the way out.
    unawaited(widget.session.detachPreview().catchError((Object _) {}));
    if (widget.lockOrientation) {
      unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    }
    super.dispose();
  }

  /// Clockwise quarter turns applied to the preview texture.
  ///
  /// [SphereCaptureView.previewQuarterTurns] wins when it is set. It exists
  /// because this is the one thing in the package that cannot be settled without
  /// the hardware in hand: every source of truth here is something the *device*
  /// reports about itself, and devices are inconsistent about it. A host app that
  /// finds its preview sideways on one tablet model can correct it in one line
  /// rather than wait for a package release.
  int get _previewQuarterTurns =>
      widget.previewQuarterTurns ?? widget.session.previewQuarterTurns;

  double get _previewAspectRatio {
    final override = widget.previewAspectRatio;
    if (override != null) return override;
    final size = widget.session.previewSize;
    if (size.width <= 0 || size.height <= 0) {
      // A platform that reported nothing usable. Fall back to the frame the plan
      // was built in rather than to a guess: it is the same sensor, so it is the
      // right shape even when the preview stream's own numbers are missing.
      final device = widget.session.deviceIntrinsics.imageSize;
      return device.height <= 0 ? 3 / 4 : device.width / device.height;
    }
    // The device frame is portrait — the screen is locked to it — so the aspect
    // is the short side over the long one, whichever way round the platform
    // happened to report the two numbers. Rotating the reported pair by the turn
    // and dividing gives the same answer when the report is honest and a
    // sideways rectangle when it is not.
    final long = size.width > size.height ? size.width : size.height;
    final short = size.width > size.height ? size.height : size.width;
    return short / long;
  }

  @override
  Widget build(BuildContext context) {
    final state = _model.state;
    return DefaultTextStyle(
      style: const TextStyle(
        color: CaptureHudColors.foreground,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.none,
      ),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.previewBuilder?.call(context) ?? _buildPreview(),
            CaptureHud(
              model: _model,
              previewAspectRatio: _previewAspectRatio,
            ),
            _buildButtons(state),
            if (_phase == SessionPhase.metering) _MeteringOverlay(_metering),
            if (_phase == SessionPhase.paused)
              _ScrimOverlay(
                title: state.message ?? 'Capture paused',
                body:
                    'Nothing is lost — ${state.capturedCount} of '
                    '${state.totalCount} photos are saved.',
                primaryLabel: 'Resume',
                onPrimary: _resume,
                secondaryLabel: 'Finish here',
                onSecondary: _finish,
              ),
            if (_confirmingExit)
              _ScrimOverlay(
                title: 'Finish this position?',
                body:
                    '${state.capturedCount} of ${state.totalCount} photos are '
                    'saved. Finishing keeps them and stitches what you have.',
                primaryLabel: 'Keep going',
                onPrimary: () => setState(() => _confirmingExit = false),
                secondaryLabel: 'Finish here',
                onSecondary: () {
                  setState(() => _confirmingExit = false);
                  unawaited(_finish());
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _resume() async {
    try {
      await widget.session.beginCapture();
    } on Object catch (error, stack) {
      _report(error, stack);
    }
  }

  Widget _buildPreview() {
    final texture = _previewTexture;
    if (texture == null) return const SizedBox.expand();
    final session = widget.session;
    final size = session.previewSize;
    // The texture arrives in the **capture** frame on both platforms — Android's
    // `SurfaceTexture` is the sensor buffer and iOS never sets
    // `videoOrientation` — so it is sized in that frame and then turned into the
    // device frame, in that order. Sizing it in the device frame and skipping the
    // turn (which is what this used to do) squeezes a landscape buffer into a
    // portrait box: the scene comes out a quarter turn from the frame the dot is
    // projected in and stretched by the aspect ratio squared, so panning right
    // slides the scene down and the dot looks like it is chasing the camera.
    //
    // `RotatedBox` rather than `Transform.rotate` because it turns the *layout*
    // too, so the `FittedBox` below cover-fits the rotated rectangle and the
    // preview rect the HUD computes from `previewAspectRatio` is the rectangle
    // actually on screen.
    // `cover`, never `fill`. `fill` stretches each axis independently to make the
    // child match the box, so any disagreement between the texture's aspect and
    // the box's comes out as a squashed scene rather than as a crop — which is
    // exactly what it did on device. Cover keeps the aspect and crops the
    // overflow, which is also what the HUD's `previewRectFor` assumes when it
    // places the dot.
    //
    // The buffer is the sensor's, in the sensor's own orientation, so it is sized
    // in that frame first and *then* turned into the device frame — `RotatedBox`
    // rather than `Transform.rotate`, because it turns the layout too and the
    // `FittedBox` above it has to cover-fit the rotated rectangle rather than the
    // original one.
    // Size the box so that **after** the turn the result is portrait, which is the
    // frame the screen is locked to and the frame the dots are projected in.
    //
    // One rule for all four turns, and it has to be derived from the same number as
    // the turn or the two disagree — which is what stretched the preview: a box in
    // the sensor frame while the buffer content had already been turned by the
    // platform, so `cover` fitted a landscape rectangle over portrait content.
    //
    // * odd turn — we are rotating it, so the content is still in the sensor's
    //   landscape frame and the box is the reported size. Rotating a landscape box
    //   gives the portrait rectangle.
    // * even turn — nothing is being rotated, so the content is already upright and
    //   the box has to be portrait to match.
    final turns = _previewQuarterTurns;
    final wide = size.width > size.height;
    final long = wide ? size.width : size.height;
    final short = wide ? size.height : size.width;
    final boxWidth = turns.isOdd ? long : short;
    final boxHeight = turns.isOdd ? short : long;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: RotatedBox(
        quarterTurns: turns,
        child: SizedBox(
          width: boxWidth > 0 ? boxWidth.toDouble() : null,
          height: boxHeight > 0 ? boxHeight.toDouble() : null,
          child: Texture(textureId: texture),
        ),
      ),
    );
  }

  /// The only two interactive elements, both in the bottom corners and both
  /// within a thumb's reach of a one-handed grip (§4). Nothing in the top half
  /// is interactive.
  Widget _buildButtons(SessionState state) {
    return Positioned.fill(
      child: SafeArea(
        child: Stack(
          children: [
            Positioned(
              left: CaptureHudMetrics.buttonInset,
              bottom: CaptureHudMetrics.buttonInset,
              child: CaptureHudButton(
                semanticsLabel: 'Exit capture',
                glyph: CaptureGlyph.exit,
                onPressed: _onExit,
              ),
            ),
            Positioned(
              right: CaptureHudMetrics.buttonInset,
              bottom: CaptureHudMetrics.buttonInset,
              child: CaptureHudButton(
                semanticsLabel: 'Take the photo now',
                glyph: CaptureGlyph.shutter,
                onPressed:
                    _phase == SessionPhase.capturing ||
                        _phase == SessionPhase.retaking
                    ? () => unawaited(widget.session.captureManual())
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which of the two glyphs a [CaptureHudButton] draws.
enum CaptureGlyph {
  /// A cross: leave the capture.
  exit,

  /// A ring: fire the shutter now.
  shutter,
}

/// One of the capture screen's two buttons.
///
/// Drawn rather than iconised so it carries the same white-on-dark treatment as
/// everything else on the screen, and sized at 64 dp against §4's 56 dp floor
/// because the hand pressing it is wearing a work glove.
///
/// The glyph sits on a dark disc. A bare stroked glyph relied on its outline
/// alone, and over a blown-out preview that is not enough to *find* a button by
/// — §4's answer to a legibility problem is always more dark, and this is the
/// same plate the progress bar already sits on. Holding it down deepens the
/// plate and shrinks the glyph, so a gloved press is confirmed by something
/// other than the thing it caused.
class CaptureHudButton extends StatefulWidget {
  /// Creates a button.
  const CaptureHudButton({
    required this.semanticsLabel,
    required this.glyph,
    required this.onPressed,
    super.key,
  });

  /// What a screen reader says. Both buttons carry one (§6).
  final String semanticsLabel;

  /// Which glyph to draw.
  final CaptureGlyph glyph;

  /// Tap handler; `null` disables the button.
  final VoidCallback? onPressed;

  @override
  State<CaptureHudButton> createState() => _CaptureHudButtonState();
}

class _CaptureHudButtonState extends State<CaptureHudButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    // Down only counts while the button can act on it, so a disabled shutter
    // does not light up under a thumb and then do nothing.
    final pressed = _pressed && enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: SizedBox(
          width: CaptureHudMetrics.buttonSize,
          height: CaptureHudMetrics.buttonSize,
          child: CustomPaint(
            painter: _GlyphPainter(
              glyph: widget.glyph,
              enabled: enabled,
              pressed: pressed,
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.enabled,
    required this.pressed,
  });

  /// The plate, the outline and the two glyph strokes, built once for the
  /// process rather than once per repaint. This painter now repaints on every
  /// press as well as on every enable, and the overlay it shares a frame with
  /// is the one place in this package that cannot afford garbage.
  static final Paint _plate = Paint()..color = CaptureHudColors.plate;
  static final Paint _platePressed = Paint()
    ..color = CaptureHudColors.platePressed;
  static final Paint _outline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6
    ..strokeCap = StrokeCap.round
    ..color = CaptureHudColors.outline;
  static final Paint _enabledStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..color = CaptureHudColors.foreground;
  static final Paint _disabledStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..color = CaptureHudColors.reticle;
  static final Paint _enabledFill = Paint()
    ..color = CaptureHudColors.foreground;
  static final Paint _disabledFill = Paint()..color = CaptureHudColors.reticle;

  final CaptureGlyph glyph;
  final bool enabled;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    // A press shrinks the glyph about its own centre. Scaled rather than moved,
    // because a button under a thumb is not visible — what the user sees is the
    // edge of the mark move, and a shift would read as a mis-hit.
    final scale = pressed ? 0.92 : 1.0;
    final plateRadius =
        math.min(CaptureHudMetrics.buttonPlateRadius, size.shortestSide / 2) *
        scale;
    // Both glyphs are sized from the plate rather than from the box, so the two
    // buttons read as the same size. Sized from the box, the shutter's ring came
    // out wide enough to cover its own plate while the exit cross left all of
    // its showing, and side by side in the two bottom corners that looked like
    // two different controls.
    final radius = plateRadius * 0.63;
    final stroke = enabled ? _enabledStroke : _disabledStroke;

    canvas.drawCircle(centre, plateRadius, pressed ? _platePressed : _plate);

    switch (glyph) {
      case CaptureGlyph.exit:
        final arm = plateRadius * 0.44;
        for (final paint in [_outline, stroke]) {
          canvas.drawLine(
            centre.translate(-arm, -arm),
            centre.translate(arm, arm),
            paint,
          );
          canvas.drawLine(
            centre.translate(arm, -arm),
            centre.translate(-arm, arm),
            paint,
          );
        }
      case CaptureGlyph.shutter:
        canvas.drawCircle(centre, radius, _outline);
        canvas.drawCircle(centre, radius, stroke);
        canvas.drawCircle(
          centre,
          radius * 0.62,
          enabled ? _enabledFill : _disabledFill,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.glyph != glyph || old.enabled != enabled || old.pressed != pressed;
}

/// The metering pre-sweep, framed as a required step rather than hidden (§3.2).
///
/// The user is turning anyway; saying so sets the expectation that this is a
/// deliberate, measured process, and it buys the exposure controller a sweep
/// that has actually seen the sphere instead of the one wall the tablet happened
/// to be pointing at.
class _MeteringOverlay extends StatelessWidget {
  const _MeteringOverlay(this.progress);

  final Animation<double> progress;

  /// Diameter of the sweep ring. Larger than the aiming ring it prefigures, so
  /// the two are not mistaken for each other.
  static const double ringSize = 108;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xD9000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                CaptureInstructions.meteringText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CaptureHudColors.foreground,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 12),
              const Text('Setting exposure…', textAlign: TextAlign.center),
              const SizedBox(height: 28),
              // A ring rather than the row of ten pips this used to be, for one
              // reason: the very next thing this screen asks of the user is to
              // fill a ring by holding still, and teaching that shape here costs
              // nothing. It is still the honest 2 s countdown — `meterAndLock` is
              // one await with no intermediate progress — and a ring says "keep
              // turning for this long" as well as a pip row did.
              AnimatedBuilder(
                animation: progress,
                builder: (context, _) => SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: CustomPaint(
                    painter: _SweepRingPainter(progress.value),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The metering sweep as a filling ring, in the same visual language as the
/// aiming screen's centre ring: a grey track with a white arc over it.
class _SweepRingPainter extends CustomPainter {
  const _SweepRingPainter(this.progress);

  static final Paint _track = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = CaptureHudMetrics.reticleStroke
    ..color = CaptureHudColors.ringTrack;
  static final Paint _arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = CaptureHudMetrics.dwellRingStroke
    ..strokeCap = StrokeCap.round
    ..color = CaptureHudColors.foreground;

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - CaptureHudMetrics.dwellRingStroke;
    canvas.drawCircle(centre, radius, _track);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      _arc,
    );
  }

  @override
  bool shouldRepaint(covariant _SweepRingPainter old) =>
      old.progress != progress;
}

/// A full-screen question with two answers, used for a pause and for the exit
/// confirmation. Transient by construction: it exists only in response to a
/// deliberate press or a platform interruption, never during aiming.
class _ScrimOverlay extends StatelessWidget {
  const _ScrimOverlay({
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xE6000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: CaptureHudColors.foreground,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 12),
              Text(body, textAlign: TextAlign.center),
              const SizedBox(height: 28),
              CaptureTextButton(label: primaryLabel, onPressed: onPrimary),
              const SizedBox(height: 12),
              CaptureTextButton(
                label: secondaryLabel,
                onPressed: onSecondary,
                filled: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A large, high-contrast, glove-operable button used by the bracketing screens
/// and the overlays.
class CaptureTextButton extends StatefulWidget {
  /// Creates a button labelled [label].
  const CaptureTextButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.filled = true,
  });

  /// The text on the button, which is also its semantics label.
  final String label;

  /// Tap handler; `null` disables the button.
  final VoidCallback? onPressed;

  /// Whether this is the emphasised answer.
  final bool filled;

  @override
  State<CaptureTextButton> createState() => _CaptureTextButtonState();
}

class _CaptureTextButtonState extends State<CaptureTextButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final pressed = _pressed && enabled;
    final filled = widget.filled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: Container(
          // 56 dp is §4's floor for a gloved hand; this is the full-width form,
          // so there is no small target anywhere on these screens.
          constraints: const BoxConstraints(minHeight: 56, minWidth: 220),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            // Pressed inverts, rather than dimming: these two buttons are the
            // answer to a question that has just ended a capture or resumed one,
            // and a dimmed button under a gloved thumb is not visible at all.
            color: filled != pressed
                ? CaptureHudColors.foreground
                : const Color(0x00000000),
            border: Border.all(color: CaptureHudColors.foreground, width: 2),
            borderRadius: BorderRadius.circular(
              CaptureHudMetrics.textButtonRadius,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: filled != pressed
                  ? const Color(0xFF000000)
                  : CaptureHudColors.foreground,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
