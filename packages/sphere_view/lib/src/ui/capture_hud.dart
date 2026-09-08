import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../api/models/camera_intrinsics.dart';
import '../api/sphere_capture_session.dart';
import '../guidance/guidance_engine.dart';
import '../plan/capture_plan.dart';
import '../utils/spherical_conventions.dart';
import 'capture_instructions.dart';

/// Every dimension the capture overlay uses, in logical pixels (= dp).
///
/// Constants rather than a theme because none of them is a preference. The
/// touch targets are 64 dp because Phase 09 §4 says ≥ 56 dp and a gloved thumb
/// on a tablet held one-handed is not a precision instrument; the centre ring is
/// 84 dp because that is the size at which the 18 dp mark around the target dot
/// is unambiguously *inside* it at arm's length.
abstract final class CaptureHudMetrics {
  /// Side padding for the progress bar and the instruction line.
  static const double horizontalPadding = 20;

  /// Gap between the top safe area and the progress bar.
  static const double progressTopPadding = 16;

  /// Progress bar height.
  ///
  /// §2 asks for 4 dp. It is 5 here, and the extra dp is not decoration: the bar
  /// is the one element that has to be read *while turning*, in peripheral
  /// vision, and at 4 dp on a high-density tablet the filled and unfilled runs
  /// were told apart by a line thinner than the dark plate around them.
  static const double progressHeight = 5;

  /// Gap between two targets in the same ring.
  static const double progressSegmentGap = 1;

  /// Gap at a ring boundary — 2 dp wider than [progressSegmentGap], so the row
  /// structure is visible without anything being labelled (§2).
  static const double progressRingGap = 3;

  /// Width reserved for the `7/29` counter, sized for the widest string the
  /// session can reach so the bar never re-lays out mid-capture.
  static const double counterColumnWidth = 76;

  /// Gap between the bar and the counter.
  static const double counterGap = 12;

  /// Counter type size.
  static const double counterFontSize = 16;

  /// Diameter of the bounding square the centre ring is inscribed in.
  ///
  /// §2 specified 72 dp for a rounded *square* reticle with the dwell arc on a
  /// second circle outside it. Both are gone: there is one circle now, it is
  /// what fills, and it is 84 dp because the mark it has to contain grew — an
  /// 18 dp ring around a 9 dp dot has to sit unambiguously *inside* the circle
  /// at arm's length, and inside a 72 dp one it did not.
  static const double reticleSize = 84;

  /// The centre ring's stroke width at rest — the grey track the dwell arc
  /// paints over.
  ///
  /// 3 rather than §2's 2: at 2 dp this is a hairline, and a hairline is the
  /// first thing to disappear when the sun is on the glass.
  static const double reticleStroke = 3;

  /// Width of the dark outer stroke that keeps the ring readable against a
  /// white wall.
  static const double outlineStroke = 5;

  /// Radius the centre ring and its dwell arc are drawn at, at rest.
  ///
  /// The arc is drawn **on** the ring rather than on a second circle outside it,
  /// so the resting grey track is what turns white as the dwell fills. Two
  /// concentric marks 12 dp apart read as two unrelated things; one circle that
  /// fills reads as one instruction.
  static const double dwellRingRadius = reticleSize / 2;

  /// The dwell arc's stroke width.
  ///
  /// Heavier than [reticleStroke] because it has to *win* over the track it is
  /// painted on top of — the difference between filled and unfilled is 2 dp of
  /// stroke as well as the change of colour, which is what makes it readable in
  /// peripheral vision while turning.
  static const double dwellRingStroke = 5;

  /// How far the ring pulls in over a full dwell.
  ///
  /// A small inward snap as the arc closes, so arriving on target and the
  /// shutter firing are two visibly different events rather than one long fill.
  static const double ringContraction = 4;

  /// Quantisation steps for [ringContraction].
  ///
  /// The ring's radius changes every frame, and a `Rect` per frame is exactly
  /// what §5 forbids — so the nine circles it can occupy are built once, with
  /// the layout, and indexed. Nine steps across a 4 dp travel is a third of a
  /// dp per step, which is below what the screen can show.
  static const int ringSteps = 8;

  /// Length of the tick that shows which way to level the tablet.
  static const double levelTickLength = 10;

  /// Stroke width of the levelling tick.
  static const double levelTickStroke = 3;

  /// Target dot radius.
  ///
  /// §2 asked for a 12 dp circle — a radius of 6. It is 9 here for the same
  /// reason [pendingDotRadius] grew: the thing the user is aiming *at* must not
  /// be the smallest mark on the screen.
  static const double dotRadius = 9;

  /// Radius of a dot that is not the next one to shoot.
  ///
  /// Only a little smaller than [dotRadius]. It was 3.5, and on a phone at arm's
  /// length in a lit room that is a speck — the field photograph that prompted
  /// this showed dots you had to look for to find, which is worse than no dots at
  /// all because the user does not know they are missing anything.
  static const double pendingDotRadius = 7;

  /// Radius of the ring drawn around the next target, so it reads as "this one"
  /// from the corner of an eye.
  static const double nextDotRingRadius = 18;

  /// Length of the off-screen arrow, tip to base.
  static const double arrowLength = 34;

  /// Half-width of the arrow's base.
  static const double arrowHalfWidth = 15;

  /// How far the arrow tip sits inside the screen edge.
  static const double arrowEdgeInset = 30;

  /// Instruction type size (§2: "16 sp").
  static const double instructionFontSize = 16;

  /// Distance from the bottom safe area to the bottom of the instruction line —
  /// above the two buttons, clear of a thumb.
  static const double instructionBottomOffset = 132;

  /// Diameter of the exit and manual-shutter targets (§4: "≥ 56 dp").
  static const double buttonSize = 64;

  /// Inset of the two buttons from the screen edges.
  static const double buttonInset = 20;

  /// Radius of the dark disc drawn behind each button's glyph.
  ///
  /// Slightly inside [buttonSize] / 2 so the plate has room for its own edge.
  /// The plate is what makes a white glyph findable over a blown-out preview:
  /// a bare stroked glyph relies on its outline alone, and at a glance over a
  /// bright wall that is not enough to locate a button by feel and sight
  /// together.
  static const double buttonPlateRadius = 30;

  /// Corner radius of the progress bar's dark plate.
  static const double progressPlateRadius = 3.5;

  /// Corner radius of the full-width buttons on the overlays.
  static const double textButtonRadius = 12;
}

/// The overlay's palette.
///
/// Two colours and their alphas, and that is the whole design system. Phase 09
/// §4: maximum contrast only — white with a dark outer stroke, no mid-grey, no
/// thin type, no translucent panels. Everything here is either near-white or
/// near-black, because in direct sunlight nothing in between survives.
abstract final class CaptureHudColors {
  /// White at 70%, for an element that is present but not active — the
  /// disabled manual shutter, and the resting stroke this used to give the
  /// reticle before the reticle became [ringTrack]'s circle.
  static const Color reticle = Color(0xB3FFFFFF);

  /// The centre ring once the target is inside it: full white, so arriving on
  /// target is visible without reading anything.
  static const Color reticleArmed = Color(0xFFFFFFFF);

  /// The centre ring's track, before the target is inside it.
  ///
  /// The one light grey on the screen, and the one place §4's "no mid-grey"
  /// rule does not apply — because §4's reason for the rule is that nothing
  /// unfilled may be mistaken for filled, and here the unfilled state *is* the
  /// grey. What reads as filled is [foreground]'s arc drawn over it, brighter
  /// by 0x40 and wider by 2 dp. Like every light element here it carries an
  /// [outline] stroke underneath, so it survives a blown-out wall as well as an
  /// unlit ceiling.
  static const Color ringTrack = Color(0xCCBFBFBF);

  /// The dark outer stroke every white element carries.
  static const Color outline = Color(0xD9000000);

  /// Filled progress segments, the target dot, the arrow, and type.
  static const Color foreground = Color(0xFFFFFFFF);

  /// Progress segments not yet captured. Dark rather than grey: against a
  /// blown-out window a mid-grey segment reads as filled.
  static const Color pending = Color(0xB3000000);

  /// The dark disc behind a button's glyph, and behind the progress segments.
  ///
  /// The same value as [pending] and deliberately a separate name: one is "this
  /// position has not been shot", the other is "this is a place to press", and a
  /// future tune of either must not silently move the other.
  static const Color plate = Color(0xB3000000);

  /// A button's plate while it is held down.
  ///
  /// Darker than [plate] rather than lighter: the glyph on top is white, so
  /// deepening the plate raises its contrast, and a gloved press has to be
  /// confirmable at a glance in sun.
  static const Color platePressed = Color(0xF2000000);

  /// A target that is not the next one to shoot.
  ///
  /// Full white, like everything else here. It was 60%, and §4 is explicit that
  /// nothing between white and black survives direct sunlight — a translucent dot
  /// over a bright preview is exactly the case it rules out. The next target is
  /// distinguished by its ring and its size, not by the others being dimmer.
  static const Color pendingDot = Color(0xFFFFFFFF);
}

/// What the overlay draws, as one mutable object the painter repaints from.
///
/// A [ChangeNotifier] rather than a widget field because `SessionState` arrives
/// once per pose sample — ~100 Hz — and rebuilding a widget subtree at that rate
/// to move a dot would spend the frame budget on element diffing. The painter
/// takes this as its `repaint` listenable, so a new pose costs one repaint and
/// no rebuild.
class CaptureHudModel extends ChangeNotifier {
  /// Creates a model for [plan], showing [state].
  ///
  /// [intrinsics] are the device-frame ones the plan and the guidance were
  /// computed in — the overlay projects every mark through them, so handing it
  /// the capture-frame set would put every dot a quarter turn out.
  CaptureHudModel({
    required this.plan,
    required SessionState state,
    CameraIntrinsics? intrinsics,
  }) : _state = state,
       intrinsics = intrinsics ?? plan.intrinsics,
       _instruction = CaptureInstructions.forState(state, plan: plan);

  /// The plan being shot. Fixed for the life of a session: it supplies the
  /// segment count and the ring boundaries, and a plan is only valid for one
  /// intrinsics/orientation pair anyway (§4).
  final CapturePlan plan;

  /// The device-frame intrinsics every mark is projected through.
  final CameraIntrinsics intrinsics;

  SessionState _state;
  double _flashOpacity = 0;
  String? _instruction;

  /// The latest session snapshot.
  SessionState get state => _state;

  /// Opacity of the 120 ms post-shutter reticle flash, `0..1`.
  double get flashOpacity => _flashOpacity;

  /// The one line to show, or `null` for none. Derived here rather than in the
  /// widget so the painter and the semantics node can never disagree about what
  /// is on screen.
  String? get instruction => _instruction;

  /// Replaces the session snapshot and notifies listeners.
  set state(SessionState value) {
    _state = value;
    _instruction = CaptureInstructions.forState(value, plan: plan);
    notifyListeners();
  }

  /// Sets the flash opacity and notifies listeners.
  set flashOpacity(double value) {
    if (value == _flashOpacity) return;
    _flashOpacity = value;
    notifyListeners();
  }

}

/// Geometry for one canvas size: everything whose position depends on the
/// screen rather than on the pose.
///
/// Computed once per size change and then read, never rebuilt — and stored as
/// bare doubles wherever the paint path touches it, because `Rect.center` and
/// `Offset` are allocations and this is the code that runs 100 times a second.
class CaptureHudLayout {
  CaptureHudLayout._({
    required this.size,
    required this.preview,
    required this.reticle,
    required this.ringRects,
    required this.segments,
    required this.segmentRRects,
    required this.progressBar,
    required this.progressPlate,
    required this.counterColumn,
    required this.instructionBox,
    required this.arrowBounds,
  }) : centre = reticle.center,
       centreX = size.width / 2,
       centreY = size.height / 2,
       previewCentreX = preview.left + preview.width / 2,
       previewCentreY = preview.top + preview.height / 2,
       previewHalfWidth = preview.width / 2,
       previewHalfHeight = preview.height / 2,
       arrowCentreX = arrowBounds.left + arrowBounds.width / 2,
       arrowCentreY = arrowBounds.top + arrowBounds.height / 2;

  /// Where the live preview sits on a canvas of [size], for a preview of aspect
  /// [aspect] (width / height, device frame).
  ///
  /// **Full bleed**, so the frame is cropped to the screen rather than
  /// letterboxed. The dot is placed relative to *this* rectangle and not to the
  /// canvas: the guidance offsets are fractions of the preview's half-width, and
  /// mapping them to the screen instead would put the dot several degrees away
  /// from the thing it points at on any device whose display and sensor aspect
  /// ratios differ — which is all of them.
  ///
  /// An inset preview was tried, to buy a world-locked border wide enough to show
  /// the *next* target as well as the current one — at ω = 0.33 the nearest
  /// neighbour is 1.34 frame half-widths away and so never fits on a full-bleed
  /// screen. On the device it was clearly worse: the surround filled with pinned
  /// thumbnails that a perspective projection stretches without bound as they move
  /// off-axis, and shrinking the live image is a real cost paid every second of
  /// the capture for a marginal gain. Aiming beats previewing. The edge arrow
  /// already says where the next target is.
  static Rect previewRectFor(Size size, double aspect) {
    final coverHeight = math.max(
      aspect > 0 ? size.width / aspect : size.height,
      size.height,
    );
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: coverHeight * aspect,
      height: coverHeight,
    );
  }

  /// Builds the layout for [size], a preview of aspect [previewAspectRatio]
  /// (width / height, in the device's portrait frame), and [plan].
  factory CaptureHudLayout.resolve({
    required Size size,
    required EdgeInsets safeArea,
    required double previewAspectRatio,
    required CapturePlan plan,
  }) {
    final aspect = previewAspectRatio.isFinite && previewAspectRatio > 0
        ? previewAspectRatio
        : math.max(size.width, 1) / math.max(size.height, 1);
    final preview = previewRectFor(size, aspect);

    final reticle = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: CaptureHudMetrics.reticleSize,
      height: CaptureHudMetrics.reticleSize,
    );

    final barTop = safeArea.top + CaptureHudMetrics.progressTopPadding;
    final barLeft = safeArea.left + CaptureHudMetrics.horizontalPadding;
    final barRight =
        size.width -
        safeArea.right -
        CaptureHudMetrics.horizontalPadding -
        CaptureHudMetrics.counterColumnWidth -
        CaptureHudMetrics.counterGap;
    final progressBar = Rect.fromLTRB(
      barLeft,
      barTop,
      math.max(barLeft, barRight),
      barTop + CaptureHudMetrics.progressHeight,
    );
    final segments = _layOutSegments(progressBar, plan);

    return CaptureHudLayout._(
      size: size,
      preview: preview,
      reticle: reticle,
      ringRects: _layOutRingRects(reticle.center),
      segments: segments,
      segmentRRects: _roundSegments(segments),
      progressBar: progressBar,
      // The bar is drawn as a dark plate with a white border and white
      // segments on top, so that both "captured" and "still to shoot" are
      // visible against a blown-out window *and* against an unlit ceiling. A
      // plain two-tone bar loses one of the two on each background — which the
      // golden tests over pure white and pure black are there to catch.
      progressPlate: RRect.fromRectAndRadius(
        progressBar.inflate(2.5),
        const Radius.circular(CaptureHudMetrics.progressPlateRadius),
      ),
      counterColumn: Rect.fromLTWH(
        size.width -
            safeArea.right -
            CaptureHudMetrics.horizontalPadding -
            CaptureHudMetrics.counterColumnWidth,
        barTop,
        CaptureHudMetrics.counterColumnWidth,
        CaptureHudMetrics.progressHeight,
      ),
      instructionBox: Rect.fromLTRB(
        safeArea.left + CaptureHudMetrics.horizontalPadding,
        0,
        size.width - safeArea.right - CaptureHudMetrics.horizontalPadding,
        size.height -
            safeArea.bottom -
            CaptureHudMetrics.instructionBottomOffset,
      ),
      arrowBounds: Rect.fromLTRB(
        safeArea.left + CaptureHudMetrics.arrowEdgeInset,
        safeArea.top + CaptureHudMetrics.arrowEdgeInset,
        size.width - safeArea.right - CaptureHudMetrics.arrowEdgeInset,
        size.height - safeArea.bottom - CaptureHudMetrics.arrowEdgeInset,
      ),
    );
  }

  /// One rectangle per target, gapped wider where the ring changes.
  ///
  /// The wider gap is the only structure the bar carries, and it is why the bar
  /// is worth having at all: "I am most of the way through the middle row" is a
  /// useful thing to know while turning, and a plain 0–100% bar cannot say it.
  static List<Rect> _layOutSegments(Rect bar, CapturePlan plan) {
    final targets = plan.targets;
    if (targets.isEmpty || bar.width <= 0) return const [];

    var gapTotal = 0.0;
    for (var i = 1; i < targets.length; i++) {
      gapTotal += targets[i].ringIndex == targets[i - 1].ringIndex
          ? CaptureHudMetrics.progressSegmentGap
          : CaptureHudMetrics.progressRingGap;
    }
    final segmentWidth = math.max(0.5, (bar.width - gapTotal) / targets.length);

    final segments = <Rect>[];
    var x = bar.left;
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) {
        x += targets[i].ringIndex == targets[i - 1].ringIndex
            ? CaptureHudMetrics.progressSegmentGap
            : CaptureHudMetrics.progressRingGap;
      }
      segments.add(Rect.fromLTWH(x, bar.top, segmentWidth, bar.height));
      x += segmentWidth;
    }
    return List.unmodifiable(segments);
  }

  /// The same segments as rounded rectangles, so the bar's ends are not squared
  /// off against a rounded plate.
  static List<RRect> _roundSegments(List<Rect> segments) {
    if (segments.isEmpty) return const [];
    // Half the bar's height, so a segment is a capsule rather than a rectangle
    // with a hint of a corner. Clamped by the segment's own width, because at 29
    // targets on a phone a segment is narrower than it is tall and a radius
    // wider than the shape it rounds draws nothing at all.
    final radius = math.min(
      segments.first.height / 2,
      segments.first.width / 2,
    );
    return List.unmodifiable([
      for (final segment in segments)
        RRect.fromRectAndRadius(segment, Radius.circular(radius)),
    ]);
  }

  /// The [CaptureHudMetrics.ringSteps] + 1 circles the centre ring can occupy,
  /// from its resting radius in to its fully-contracted one.
  ///
  /// Pre-built because the ring's radius is a function of the dwell and the
  /// dwell changes every frame: §5 asks the painter to allocate nothing, and a
  /// `Rect` per frame is an allocation. This is the same trick
  /// [CaptureHudCache.flashPaints] uses for the flash's colour.
  static List<Rect> _layOutRingRects(Offset centre) => List.unmodifiable([
    for (var i = 0; i <= CaptureHudMetrics.ringSteps; i++)
      Rect.fromCircle(
        center: centre,
        radius:
            CaptureHudMetrics.dwellRingRadius -
            CaptureHudMetrics.ringContraction * i / CaptureHudMetrics.ringSteps,
      ),
  ]);

  /// Canvas size this layout was resolved for.
  final Size size;

  /// Where the camera preview actually lands, cover-fitted.
  final Rect preview;

  /// The bounding square of the fixed centre ring.
  final Rect reticle;

  /// The circles the centre ring can be drawn at, indexed by
  /// [ringStepFor] — index `0` is at rest, the last is fully contracted.
  final List<Rect> ringRects;

  /// One rectangle per plan target, in shooting order.
  final List<Rect> segments;

  /// [segments] as capsules, which is what the painter actually draws.
  final List<RRect> segmentRRects;

  /// The whole progress bar's extent.
  final Rect progressBar;

  /// The dark plate the segments sit on, slightly larger than [progressBar].
  final RRect progressPlate;

  /// Where the `7/29` counter is drawn.
  final Rect counterColumn;

  /// The band the instruction line is laid out in; its bottom is the line's
  /// bottom edge.
  final Rect instructionBox;

  /// The rectangle the off-screen arrow's tip is pinned to.
  final Rect arrowBounds;

  /// Canvas centre, held as an [Offset] so the paint path never builds one:
  /// `Rect.center` allocates, and the centre ring is drawn on every frame.
  final Offset centre;

  /// Canvas centre x.
  final double centreX;

  /// Canvas centre y.
  final double centreY;

  /// Preview centre x.
  final double previewCentreX;

  /// Preview centre y.
  final double previewCentreY;

  /// Half the cover-fitted preview width.
  final double previewHalfWidth;

  /// Half the cover-fitted preview height.
  final double previewHalfHeight;

  /// Centre x of [arrowBounds].
  final double arrowCentreX;

  /// Centre y of [arrowBounds].
  final double arrowCentreY;

  /// Screen x for a guidance offset of [offsetX] (`−1`…`+1` across the
  /// preview).
  double dotX(double offsetX) => previewCentreX + offsetX * previewHalfWidth;

  /// Screen y for a guidance offset of [offsetY].
  double dotY(double offsetY) => previewCentreY + offsetY * previewHalfHeight;

  /// Which of [ringRects] a dwell of [dwell] (`0..1`) draws at.
  int ringStepFor(double dwell) =>
      (dwell.clamp(0.0, 1.0) * CaptureHudMetrics.ringSteps).round();

  /// The circle the centre ring occupies at a dwell of [dwell].
  Rect ringRectFor(double dwell) => ringRects[ringStepFor(dwell)];

  /// The radius the centre ring is drawn at for a dwell of [dwell].
  double ringRadiusFor(double dwell) => ringRectFor(dwell).width / 2;

  /// Whether a mark at ([x], [y]) can be drawn where it belongs.
  ///
  /// **The one visibility rule.** The engine used to decide dot-versus-arrow from
  /// `|offset| ≤ 1` — the whole sensor frame — while the painter re-decided it
  /// against `arrowBounds`, the safe area inset by a further 30 dp. Those are
  /// different rectangles, so a dot vanished and an arrow took over while the
  /// target was still well inside the visible picture, and the two flickered along
  /// that boundary as the user panned.
  ///
  /// It is the **canvas**, not the preview, because the surround is part of the
  /// same projection: a target one frame-step away lands outside the preview and
  /// is still at its true position on screen, which is the whole point of the
  /// surround existing. Less [margin] so a mark is never half-clipped.
  bool markIsVisible(double x, double y, {double margin = 0}) =>
      x >= margin &&
      x <= size.width - margin &&
      y >= margin &&
      y <= size.height - margin;
}

/// Everything the painter would otherwise allocate: paints, paragraphs and the
/// resolved layout.
///
/// It exists because Phase 09 §5 asks for **zero per-frame allocations**, and
/// that is not a style preference here: the overlay repaints on every pose
/// sample, on a device simultaneously running a camera preview, a sensor stream
/// at 100 Hz and a JPEG burst, and a garbage collection at the wrong moment is a
/// dropped frame in the one part of the app the user is looking at while
/// turning.
///
/// Owned by the widget's `State`, not by the painter — a `CustomPainter` is
/// rebuilt whenever the widget is, so a cache living on the painter would be a
/// cache in name only.
class CaptureHudCache {
  /// Creates a cache with its paints and its arrow path already built.
  CaptureHudCache() {
    outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.outlineStroke
      ..strokeJoin = StrokeJoin.round
      ..color = CaptureHudColors.outline;
    ringOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.outlineStroke
      ..color = CaptureHudColors.outline;
    reticlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.reticleStroke
      ..color = CaptureHudColors.ringTrack;
    reticleArmedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.reticleStroke
      ..color = CaptureHudColors.reticleArmed;
    dwellBackingPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.dwellRingStroke + 3
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.outline;
    dwellPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.dwellRingStroke
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.foreground;
    levelTickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.levelTickStroke
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.foreground;
    levelTickOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = CaptureHudMetrics.levelTickStroke + 3
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.outline;
    dotPaint = Paint()..color = CaptureHudColors.foreground;
    dotOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = CaptureHudColors.outline;
    pendingDotPaint = Paint()..color = CaptureHudColors.pendingDot;
    pendingDotOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = CaptureHudColors.outline;
    nextRingPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = CaptureHudColors.foreground;
    nextRingOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = CaptureHudColors.outline;
    arrowPaint = Paint()..color = CaptureHudColors.foreground;
    arrowOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round
      ..color = CaptureHudColors.outline;
    filledSegmentPaint = Paint()..color = CaptureHudColors.foreground;
    platePaint = Paint()..color = CaptureHudColors.pending;
    plateBorderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = CaptureHudColors.foreground;
    typeOutlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeJoin = StrokeJoin.round
      ..color = CaptureHudColors.outline;

    // The flash is the one element whose colour changes every frame, so its
    // paints are pre-built at fixed steps and indexed. Nine steps across 120 ms
    // is finer than the ~7 frames the flash occupies at 60 Hz, so nothing is
    // lost and nothing is allocated.
    flashPaints = List<Paint>.unmodifiable([
      for (var i = 0; i <= flashSteps; i++)
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = CaptureHudMetrics.dwellRingStroke
          ..color = Color.fromARGB(
            (255 * i / flashSteps).round(),
            255,
            255,
            255,
          ),
    ]);
    // The same ramp as fills. The flash is a disc filling the ring rather than a
    // stroke on it, because that is what a shutter looks like — and it is *the
    // ring*, not the screen: a full-screen white flash in an unlit interior
    // destroys the user's dark adaptation, which §4 rules out. The two ramps
    // share `flashSteps`, so a single quantised index drives both.
    flashDiscPaints = List<Paint>.unmodifiable([
      for (var i = 0; i <= flashSteps; i++)
        Paint()
          ..color = Color.fromARGB(
            // Capped below opaque: the dot the user just aimed is under this
            // disc, and covering it completely at the moment of capture reads as
            // the mark disappearing rather than as a shutter.
            (216 * i / flashSteps).round(),
            255,
            255,
            255,
          ),
    ]);

    // The arrow points along +x with its tip at the origin; the painter rotates
    // the canvas rather than rebuilding the path.
    arrowPath = Path()
      ..moveTo(0, 0)
      ..lineTo(-CaptureHudMetrics.arrowLength, -CaptureHudMetrics.arrowHalfWidth)
      ..lineTo(-CaptureHudMetrics.arrowLength * 0.72, 0)
      ..lineTo(-CaptureHudMetrics.arrowLength, CaptureHudMetrics.arrowHalfWidth)
      ..close();
  }

  /// Quantisation steps for the flash ramp.
  static const int flashSteps = 8;

  /// A general-purpose dark outer stroke at [CaptureHudMetrics.outlineStroke].
  ///
  /// Every element here draws its own, so this one is drawn by nothing in the
  /// painter — it is kept, and exported, because a host app adding a mark of its
  /// own to this screen needs the same treatment to stay legible in sun, and
  /// re-deriving it from §4 is how two overlays end up looking different.
  late final Paint outlinePaint;

  /// Dark stroke drawn under the centre ring.
  late final Paint ringOutlinePaint;

  /// The centre ring's grey track, before the target is inside it.
  late final Paint reticlePaint;

  /// The centre ring once the target is inside it: full white.
  late final Paint reticleArmedPaint;

  /// Dark backing under the dwell arc.
  late final Paint dwellBackingPaint;

  /// The dwell arc that sweeps over the ring's track.
  late final Paint dwellPaint;

  /// The tick that shows which way to level the tablet.
  late final Paint levelTickPaint;

  /// The levelling tick's dark outline.
  late final Paint levelTickOutlinePaint;

  /// The target dot's fill.
  late final Paint dotPaint;

  /// The target dot's dark ring.
  late final Paint dotOutlinePaint;

  /// Fill for a target that is not the next one to shoot.
  late final Paint pendingDotPaint;

  /// Dark ring for a target that is not the next one to shoot.
  late final Paint pendingDotOutlinePaint;

  /// The ring that marks the next target out from the rest.
  late final Paint nextRingPaint;

  /// The next-target ring's dark outline.
  late final Paint nextRingOutlinePaint;

  /// The edge arrow's fill.
  late final Paint arrowPaint;

  /// The edge arrow's dark outline.
  late final Paint arrowOutlinePaint;

  /// A captured position's segment.
  late final Paint filledSegmentPaint;

  /// The dark plate the segments sit on, which is what makes a white segment
  /// visible against a white wall.
  late final Paint platePaint;

  /// The plate's white border, which is what makes the bar's extent visible
  /// against a dark ceiling.
  late final Paint plateBorderPaint;

  /// Stroke used to outline type.
  late final Paint typeOutlinePaint;

  /// White ring strokes at nine fixed alphas, indexed by the quantised flash
  /// opacity.
  late final List<Paint> flashPaints;

  /// White fills at the same nine alphas, for the disc the flash fills the ring
  /// with.
  late final List<Paint> flashDiscPaints;

  /// The arrow, tip at the origin, pointing along +x.
  late final Path arrowPath;

  /// How many times anything has been built *during* painting.
  ///
  /// The number the allocation test asserts on: after the first frame it must
  /// not move while only the pose changes. It counts layout resolutions and
  /// paragraph builds, which between them are every object this cache creates
  /// after construction — the paints and the arrow path are built once, in the
  /// constructor, before any frame.
  int buildCount = 0;

  CaptureHudLayout? _layout;
  CapturePlan? _layoutPlan;
  Size? _layoutSize;
  EdgeInsets? _layoutSafeArea;
  double? _layoutAspect;

  ui.Paragraph? _counterFill;
  ui.Paragraph? _counterOutline;
  Offset _counterOffset = Offset.zero;
  int? _counterCaptured;
  int? _counterTotal;

  ui.Paragraph? _instructionFill;
  ui.Paragraph? _instructionOutline;
  Offset _instructionOffset = Offset.zero;
  String? _instructionText;
  double? _instructionWidth;

  /// The layout for [size], rebuilt only when something it depends on moves.
  CaptureHudLayout layout({
    required Size size,
    required EdgeInsets safeArea,
    required double previewAspectRatio,
    required CapturePlan plan,
  }) {
    final cached = _layout;
    if (cached != null &&
        _layoutSize == size &&
        _layoutSafeArea == safeArea &&
        _layoutAspect == previewAspectRatio &&
        identical(_layoutPlan, plan)) {
      return cached;
    }
    buildCount++;
    _layoutSize = size;
    _layoutSafeArea = safeArea;
    _layoutAspect = previewAspectRatio;
    _layoutPlan = plan;
    return _layout = CaptureHudLayout.resolve(
      size: size,
      safeArea: safeArea,
      previewAspectRatio: previewAspectRatio,
      plan: plan,
    );
  }

  /// The `7/29` counter, rebuilt only when the count changes — 29 times in a
  /// session, not 60 times a second.
  void _ensureCounter(int captured, int total, CaptureHudLayout layout) {
    if (_counterCaptured == captured &&
        _counterTotal == total &&
        _counterFill != null) {
      return;
    }
    buildCount++;
    _counterCaptured = captured;
    _counterTotal = total;
    _counterFill?.dispose();
    _counterOutline?.dispose();
    final text = '$captured/$total';
    final width = layout.counterColumn.width;
    _counterFill = _paragraph(
      text,
      width: width,
      fontSize: CaptureHudMetrics.counterFontSize,
      align: ui.TextAlign.right,
      color: CaptureHudColors.foreground,
    );
    _counterOutline = _paragraph(
      text,
      width: width,
      fontSize: CaptureHudMetrics.counterFontSize,
      align: ui.TextAlign.right,
      foreground: typeOutlinePaint,
    );
    _counterOffset = Offset(
      layout.counterColumn.left,
      layout.counterColumn.top +
          CaptureHudMetrics.progressHeight / 2 -
          _counterFill!.height / 2,
    );
  }

  /// The instruction line, rebuilt only when the sentence changes. Instant
  /// swaps, never a cross-fade (§2) — so there is nothing to interpolate
  /// between changes and nothing to allocate between them either.
  void _ensureInstruction(String? text, CaptureHudLayout layout) {
    final width = layout.instructionBox.width;
    if (_instructionText == text && _instructionWidth == width) return;
    buildCount++;
    _instructionText = text;
    _instructionWidth = width;
    _instructionFill?.dispose();
    _instructionOutline?.dispose();
    if (text == null || text.isEmpty) {
      _instructionFill = null;
      _instructionOutline = null;
      return;
    }
    _instructionFill = _paragraph(
      text,
      width: width,
      fontSize: CaptureHudMetrics.instructionFontSize,
      align: ui.TextAlign.center,
      color: CaptureHudColors.foreground,
    );
    _instructionOutline = _paragraph(
      text,
      width: width,
      fontSize: CaptureHudMetrics.instructionFontSize,
      align: ui.TextAlign.center,
      foreground: typeOutlinePaint,
    );
    _instructionOffset = Offset(
      layout.instructionBox.left,
      layout.instructionBox.bottom - _instructionFill!.height,
    );
  }

  static ui.Paragraph _paragraph(
    String text, {
    required double width,
    required double fontSize,
    required ui.TextAlign align,
    Color? color,
    Paint? foreground,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: align,
              textDirection: TextDirection.ltr,
              fontSize: fontSize,
              // Heavy, because §4 forbids thin type: in sunlight a light weight
              // disappears into the scene long before the contrast ratio does.
              fontWeight: FontWeight.w700,
              maxLines: 2,
              ellipsis: '…',
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: color,
              foreground: foreground,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          )
          ..addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: width));
  }

  /// Releases the cached paragraphs.
  void dispose() {
    _counterFill?.dispose();
    _counterOutline?.dispose();
    _instructionFill?.dispose();
    _instructionOutline?.dispose();
    _counterFill = null;
    _counterOutline = null;
    _instructionFill = null;
    _instructionOutline = null;
    _counterCaptured = null;
    _counterTotal = null;
    _instructionText = null;
    _instructionWidth = null;
  }
}

/// Draws the whole capture overlay — progress bar and counter, centre ring,
/// target dot, edge arrow and instruction line — in one painter.
///
/// One painter rather than a stack of widgets because all of them are functions
/// of the same [SessionState], repainted on every pose sample at ~100 Hz. Five
/// widgets would mean five rebuilds and five layout passes per sample on a
/// device already running a camera and a sensor stream — and, more importantly,
/// they could disagree about which frame they belong to. Here the dot and the
/// centre ring come from one snapshot, so the ring can never be filling for a
/// pose the dot has already left (Phase 09 §5).
///
/// The elements have to stay legible against both a blown window and an unlit
/// corner, which is why every light element carries a dark outer stroke, and why
/// the capture flash fills the ring rather than the screen — a dark interior is
/// the normal case here, not the edge case (§4).
class CaptureHudPainter extends CustomPainter {
  /// Creates a painter that repaints whenever [model] changes.
  CaptureHudPainter({
    required this.model,
    required this.cache,
    required this.previewAspectRatio,
    this.safeArea = EdgeInsets.zero,
  }) : super(repaint: model);

  /// What to draw.
  final CaptureHudModel model;

  /// Where the paints, paragraphs and layout live between frames.
  final CaptureHudCache cache;

  /// Preview width / height in the device's portrait frame, so the dot can be
  /// placed against the preview rather than against the screen.
  final double previewAspectRatio;

  /// Insets to keep clear of notches and system bars.
  final EdgeInsets safeArea;

  /// The session snapshot being drawn.
  SessionState get state => model.state;

  /// The 120 ms post-shutter flash, `0..1`.
  double get flashOpacity => model.flashOpacity;

  /// The layout in force, for tests that need to know where an element landed.
  CaptureHudLayout layoutFor(Size size) => cache.layout(
    size: size,
    safeArea: safeArea,
    previewAspectRatio: previewAspectRatio,
    plan: model.plan,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final layout = layoutFor(size);
    final state = model.state;
    final guidance = state.guidance;

    // The pose is what makes everything below world-locked, so the passes that
    // need it are skipped rather than faked when there is none — before the first
    // sample arrives, and after the session has finished.
    final pose = state.pose;
    if (pose != null) {
      // World→device: for a unit quaternion the conjugate is the inverse. Taken
      // once per frame and shared by every mark, so all of them are placed from
      // exactly the same instant.
      final worldToDevice = pose.deviceToWorld.conjugated();
      _paintTargets(canvas, layout, state, worldToDevice);
    }
    _paintProgress(canvas, layout, state);
    _paintReticle(canvas, layout, guidance);
    _paintFlash(canvas, layout);
    if (guidance != null) _paintTarget(canvas, layout, guidance);
    _paintInstruction(canvas, layout);
  }

  void _paintProgress(Canvas canvas, CaptureHudLayout layout, SessionState s) {
    canvas.drawRRect(layout.progressPlate, cache.platePaint);
    canvas.drawRRect(layout.progressPlate, cache.plateBorderPaint);
    final segments = layout.segments;
    // Segments fill in shooting order rather than by target index: the bar
    // answers "how much is left", and a retake re-opens a segment that had been
    // filled. `capturedCount` is the honest count either way. A position still
    // to shoot is drawn as *nothing* — the plate shows through — so the two
    // states differ by presence rather than by a shade, and no mid-grey ever
    // has to survive direct sunlight.
    final capsules = layout.segmentRRects;
    for (var i = 0; i < segments.length && i < s.capturedCount; i++) {
      canvas.drawRRect(capsules[i], cache.filledSegmentPaint);
    }
    cache._ensureCounter(s.capturedCount, s.totalCount, layout);
    final outline = cache._counterOutline;
    final fill = cache._counterFill;
    if (outline != null) canvas.drawParagraph(outline, cache._counterOffset);
    if (fill != null) canvas.drawParagraph(fill, cache._counterOffset);
  }

  /// The centre ring: one circle, in three states, in place.
  ///
  /// It used to be a rounded square with the dwell arc on a *second* circle 12
  /// dp outside it, and at arm's length that read as two unrelated marks — the
  /// thing that filled was not the thing you were putting the dot into. Now the
  /// ring's own grey track is what the white arc paints over, so all three states
  /// are states of one shape:
  ///
  /// * **away** — grey track ([CaptureHudColors.ringTrack]).
  /// * **filling** — a heavier white arc sweeps clockwise from twelve o'clock
  ///   *over that same grey*, and the ring pulls in by
  ///   [CaptureHudMetrics.ringContraction] as it closes, so the shutter arrives
  ///   with a small snap rather than at the end of an even fill.
  /// * **fired** — the ring fills with white and drains ([_paintFlash]).
  ///
  /// The track deliberately stays grey while the arc runs. Whitening the whole
  /// ring on arrival was tried and is worse: it spends the contrast the arc
  /// needs, so the thing that actually reports progress ends up as white on
  /// white. Arrival is already reported twice over — the arc starts, and the
  /// instruction line stops saying "Hold steady".
  ///
  /// Takes the whole [guidance] rather than just the dwell because every state
  /// comes off the same snapshot, which is the reason this is one painter and
  /// not four widgets (§5).
  void _paintReticle(
    Canvas canvas,
    CaptureHudLayout layout,
    GuidanceState? guidance,
  ) {
    final dwell = (guidance?.dwellProgress ?? 0).clamp(0.0, 1.0);
    // One of the pre-built circles, so the contraction costs no allocation.
    final rect = layout.ringRectFor(dwell);
    final radius = rect.width / 2;

    canvas.drawCircle(layout.centre, radius, cache.ringOutlinePaint);
    canvas.drawCircle(layout.centre, radius, cache.reticlePaint);

    if (dwell > 0) {
      // Clockwise from twelve o'clock, which is what makes the auto-shutter feel
      // intentional rather than arbitrary (§2).
      final sweep = 2 * math.pi * dwell;
      canvas.drawArc(rect, -math.pi / 2, sweep, false, cache.dwellBackingPaint);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, cache.dwellPaint);
    }

    if (guidance != null && !guidance.rollWithinTolerance) {
      _paintLevelTick(canvas, layout, radius, guidance.rollErrorRadians);
    }
  }

  /// A tick on the ring showing which way the tablet is rolled.
  ///
  /// The instruction line already says "Level the tablet"; this says *which
  /// way*, without a second sentence and without anything for the user to read.
  /// Drawn only when the roll is actually gating the shot — away from the poles
  /// `rollWithinTolerance` is always true, so this never appears where a rolled
  /// frame is merely untidy rather than unusable.
  void _paintLevelTick(
    Canvas canvas,
    CaptureHudLayout layout,
    double radius,
    double roll,
  ) {
    canvas.save();
    canvas.translate(layout.centre.dx, layout.centre.dy);
    // Positive roll is anticlockwise as the user sees the scene, so the tick that
    // marks where the top of the screen *is* rotates with it. Canvas rotation is
    // clockwise-positive, hence the negation.
    canvas.rotate(-roll);
    final outer = -radius - CaptureHudMetrics.levelTickLength / 2;
    final inner = -radius + CaptureHudMetrics.levelTickLength / 2;
    canvas.drawLine(
      Offset(0, outer),
      Offset(0, inner),
      cache.levelTickOutlinePaint,
    );
    canvas.drawLine(Offset(0, outer), Offset(0, inner), cache.levelTickPaint);
    canvas.restore();
  }

  /// The post-shutter confirmation: the ring fills with white and drains over
  /// 120 ms.
  ///
  /// A disc rather than a stroke, because a stroke that brightens is hard to
  /// tell from the dwell arc completing, and the capture is the one event on
  /// this screen that must be unmissable. It is still *the ring* and not the
  /// screen — a full-screen white flash wrecks dark adaptation, and a dark
  /// interior is the normal case here rather than the edge case (§4).
  void _paintFlash(Canvas canvas, CaptureHudLayout layout) {
    final opacity = flashOpacity;
    if (opacity <= 0) return;
    final index = (opacity.clamp(0.0, 1.0) * CaptureHudCache.flashSteps).round();
    if (index <= 0) return;
    // Drawn at the fully-contracted radius: the flash only ever follows a
    // completed dwell, and that is where the ring is when it completes.
    final radius = layout.ringRadiusFor(1);
    canvas.drawCircle(layout.centre, radius, cache.flashDiscPaints[index]);
    canvas.drawCircle(layout.centre, radius, cache.flashPaints[index]);
  }

  /// Where a world direction lands on this canvas, or `null` if it is behind the
  /// camera.
  ///
  /// The whole reason every mark on this screen is world-locked: it is re-derived
  /// here, from its own absolute direction and the current pose, on every frame.
  /// Nothing is remembered between frames, so nothing can drift, lag behind the
  /// scene, or accumulate.
  Offset? _projectDirection(
    CaptureHudLayout layout,
    Quaternion worldToDevice,
    Vector3 direction,
  ) {
    final offset = SphericalConventions.previewOffsetForWorldDirection(
      k: model.intrinsics,
      worldToDevice: worldToDevice,
      direction: direction,
    );
    if (offset == null) return null;
    return Offset(layout.dotX(offset.x), layout.dotY(offset.y));
  }

  /// Every target still to shoot, the next one picked out.
  ///
  /// One dot at a time was the old behaviour and it hid two things from the user:
  /// where the capture was going next, and how far apart the targets are. A row
  /// of dots answers both without a word of text, and a missing one — the nadir,
  /// before it was planned at all — becomes visible as a gap rather than as
  /// nothing.
  void _paintTargets(
    Canvas canvas,
    CaptureHudLayout layout,
    SessionState state,
    Quaternion worldToDevice,
  ) {
    final current = state.currentTarget;
    for (final target in state.remainingTargets) {
      if (target.index == current?.index) continue;
      final point = _projectDirection(layout, worldToDevice, target.direction);
      if (point == null) continue;
      if (!layout.markIsVisible(
        point.dx,
        point.dy,
        margin: CaptureHudMetrics.pendingDotRadius,
      )) {
        continue;
      }
      canvas.drawCircle(
        point,
        CaptureHudMetrics.pendingDotRadius,
        cache.pendingDotOutlinePaint,
      );
      canvas.drawCircle(
        point,
        CaptureHudMetrics.pendingDotRadius,
        cache.pendingDotPaint,
      );
    }
  }

  void _paintTarget(
    Canvas canvas,
    CaptureHudLayout layout,
    GuidanceState guidance,
  ) {
    final offsetX = guidance.targetScreenOffsetX;
    final offsetY = guidance.targetScreenOffsetY;

    if (offsetX != null && offsetY != null) {
      final x = layout.dotX(offsetX);
      final y = layout.dotY(offsetY);
      // One visibility rule, `layout.markIsVisible`, rather than the engine's
      // `|offset| ≤ 1` and the painter's inset rectangle disagreeing about where
      // the dot stops and the arrow starts. The engine still reports an arrow
      // angle for a target behind the camera, where there is no projection at
      // all — that case has no dot to draw by construction.
      if (layout.markIsVisible(x, y, margin: CaptureHudMetrics.dotRadius)) {
        canvas.drawCircle(
          Offset(x, y),
          CaptureHudMetrics.nextDotRingRadius,
          cache.nextRingOutlinePaint,
        );
        canvas.drawCircle(
          Offset(x, y),
          CaptureHudMetrics.nextDotRingRadius,
          cache.nextRingPaint,
        );
        canvas.drawCircle(
          Offset(x, y),
          CaptureHudMetrics.dotRadius,
          cache.dotOutlinePaint,
        );
        canvas.drawCircle(
          Offset(x, y),
          CaptureHudMetrics.dotRadius,
          cache.dotPaint,
        );
        return;
      }
      _paintArrow(
        canvas,
        layout,
        math.atan2(y - layout.centreY, x - layout.centreX),
      );
      return;
    }
    final arrow = guidance.edgeArrowRadians;
    if (arrow != null) _paintArrow(canvas, layout, arrow);
  }

  /// The arrow replaces the dot whenever the target cannot be drawn on screen.
  ///
  /// Not a dot clamped to the edge: that implies "nearly there" when the user
  /// has to turn 150°, which §2 calls the single most confusing thing a guided
  /// capture UI can do.
  void _paintArrow(Canvas canvas, CaptureHudLayout layout, double angle) {
    final bounds = layout.arrowBounds;
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    // Where the ray from the centre leaves the pinning rectangle.
    var t = double.infinity;
    if (dx.abs() > 1e-9) t = math.min(t, (bounds.width / 2) / dx.abs());
    if (dy.abs() > 1e-9) t = math.min(t, (bounds.height / 2) / dy.abs());
    if (!t.isFinite) t = 0;

    canvas.save();
    canvas.translate(
      layout.arrowCentreX + dx * t,
      layout.arrowCentreY + dy * t,
    );
    canvas.rotate(angle);
    canvas.drawPath(cache.arrowPath, cache.arrowOutlinePaint);
    canvas.drawPath(cache.arrowPath, cache.arrowPaint);
    canvas.restore();
  }

  void _paintInstruction(Canvas canvas, CaptureHudLayout layout) {
    cache._ensureInstruction(model.instruction, layout);
    final outline = cache._instructionOutline;
    final fill = cache._instructionFill;
    if (outline == null || fill == null) return;
    canvas.drawParagraph(outline, cache._instructionOffset);
    canvas.drawParagraph(fill, cache._instructionOffset);
  }

  @override
  bool shouldRepaint(covariant CaptureHudPainter oldDelegate) =>
      !identical(oldDelegate.model, model) ||
      !identical(oldDelegate.cache, cache) ||
      oldDelegate.previewAspectRatio != previewAspectRatio ||
      oldDelegate.safeArea != safeArea;

  @override
  bool shouldRebuildSemantics(covariant CaptureHudPainter oldDelegate) => false;
}

/// The overlay as a widget: the painter, plus the semantics the painter cannot
/// carry.
///
/// Painted pixels are invisible to a screen reader, so the instruction line gets
/// a live region holding the same string the painter drew — read from the same
/// [CaptureHudModel], so the two can never drift.
class CaptureHud extends StatefulWidget {
  /// Creates the overlay for [model].
  const CaptureHud({
    required this.model,
    required this.previewAspectRatio,
    super.key,
    this.safeArea,
  });

  /// What to draw.
  final CaptureHudModel model;

  /// Preview width / height in the device's portrait frame.
  final double previewAspectRatio;

  /// Overrides the ambient safe area; tests pass [EdgeInsets.zero] so goldens
  /// do not depend on a simulated notch.
  final EdgeInsets? safeArea;

  @override
  State<CaptureHud> createState() => CaptureHudState();
}

/// State for [CaptureHud]. Public only so a widget test can reach [cache].
class CaptureHudState extends State<CaptureHud> {
  final CaptureHudCache _cache = CaptureHudCache();
  String? _announced;

  /// The paint cache this overlay is using.
  CaptureHudCache get cache => _cache;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModelChanged);
    _announced = widget.model.instruction;
  }

  @override
  void didUpdateWidget(CaptureHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      oldWidget.model.removeListener(_onModelChanged);
      widget.model.addListener(_onModelChanged);
      _announced = widget.model.instruction;
    }
  }

  /// Rebuilds only when the *sentence* changes.
  ///
  /// The model notifies on every pose sample; the painter listens to it
  /// directly and repaints, and this rebuild exists solely so the semantics
  /// label follows. Rebuilding on every sample instead would spend the frame
  /// budget re-diffing a widget tree that never changes.
  void _onModelChanged() {
    final instruction = widget.model.instruction;
    if (instruction == _announced) return;
    if (!mounted) return;
    setState(() => _announced = instruction);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safeArea = widget.safeArea ?? MediaQuery.paddingOf(context);
    final instruction = _announced;
    return IgnorePointer(
      child: Semantics(
        // One live region, one sentence: exactly what is on screen.
        liveRegion: instruction != null && instruction.isNotEmpty,
        label: instruction ?? '',
        child: CustomPaint(
          painter: CaptureHudPainter(
            model: widget.model,
            cache: _cache,
            previewAspectRatio: widget.previewAspectRatio,
            safeArea: safeArea,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
