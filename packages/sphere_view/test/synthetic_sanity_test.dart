@Tags(['synthetic'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/image_size.dart';
import 'package:vector_math/vector_math_64.dart';

import '../tools/harness/camera_model.dart';
import '../tools/harness/float_image.dart';
import '../tools/harness/frame_renderer.dart';
import '../tools/harness/legacy_dart_stitcher.dart';
import '../tools/harness/profiles.dart';
import '../tools/harness/rng.dart';
import '../tools/harness/stitcher_backend.dart';
import '../tools/harness/synth_runner.dart';

/// The test that stops the mirrored-panorama class of bug.
///
/// §4 of `phases/PHASE_02_synthetic_rig.md` states the hazard exactly: the
/// forward renderer and the stitcher share the mapping formulas, so **a sign
/// error in both would cancel and every other test would pass on garbage.** It
/// is worth being precise about how complete that cancellation is. Suppose the
/// equirect mapping `M` were mirrored to some wrong `M'`. The renderer would
/// sample the ground truth at `M'(d)` instead of `M(d)`; the stitcher would
/// then map an output pixel `q` back through `M'⁻¹`, look up that same frame
/// pixel, and write it to `q`. The output would equal the input, exactly, at
/// every pixel. SSIM 1.0. PSNR infinite. The panorama mirrored, and the harness
/// calling it perfect.
///
/// So a round trip cannot be the test. Two things break the symmetry, and this
/// file does both.
///
/// 1. **The expected pixel positions are computed inline, by hand, from
///    Math §3.** Nothing in this file imports `SphericalConventions`, and
///    nothing calls the production mapping to decide where a marker belongs.
///    The markers are *painted* at hand-computed coordinates.
/// 2. **The decisive assertion is on a single rendered frame, not on the
///    panorama.** A camera aimed at (yaw, pitch) must see that direction's
///    marker on its own principal point. That routes through the pose
///    construction, the intrinsics and the equirect mapping in **one direction
///    only**, so there is no inverse for an error to cancel against. A sign
///    error puts the marker elsewhere in the frame, or out of it entirely.
///
/// The round trip is asserted second, because it catches the other failure a
/// one-way check cannot: a mapping that is right but an inverse that is not.
///
/// Ten directions, covering the eight the phase doc requires — both poles, both
/// sides of the ±180° wrap seam, and headings in between — plus a marker
/// sitting *astride* the seam and two off-axis diagonals.
void main() {
  // ---------------------------------------------------------------------
  // The mapping, written out by hand from Math §3. Do not replace these with
  // calls into lib/ — that is the entire point of the file.
  //
  //     x_img = W · ( ½ − yaw   / 2π )
  //     y_img = H · ( ½ − pitch / π  )
  //
  // Consequences worth re-deriving rather than trusting, also from Math §3:
  //   image centre x = W/2  is yaw 0, the session-start heading
  //   left edge   x = 0     is yaw +π          right edge x = W is yaw −π
  //   top row     y = 0     is pitch +π/2      bottom row y = H is pitch −π/2
  // ---------------------------------------------------------------------

  const width = 1024;
  const height = 512;

  double expectedX(double yawRadians) =>
      width * (0.5 - yawRadians / (2 * math.pi));
  double expectedY(double pitchRadians) =>
      height * (0.5 - pitchRadians / math.pi);

  // Sanity on the sanity check: pin the landmarks the document names, so a typo
  // in the two lines above cannot silently define a wrong "truth".
  test('the hand-written mapping reproduces the landmarks of Math §3', () {
    expect(expectedX(0), width / 2, reason: 'yaw 0 sits at the image centre');
    expect(expectedX(math.pi), 0, reason: 'yaw +pi sits at the left edge');
    expect(
      expectedX(-math.pi),
      width,
      reason: 'yaw -pi sits at the right edge — the same meridian',
    );
    expect(expectedY(math.pi / 2), 0, reason: 'the zenith is the top row');
    expect(
      expectedY(-math.pi / 2),
      height,
      reason: 'the nadir is the bottom row',
    );
    expect(expectedY(0), height / 2, reason: 'the horizon is the middle row');

    // Turning right — yaw decreasing — must move content right in the image,
    // i.e. the panorama is not mirrored.
    expect(
      expectedX(-0.1),
      greaterThan(expectedX(0.0)),
      reason: 'decreasing yaw must increase x, or the output is mirrored',
    );
  });

  // Each marker gets its own colour. A shared colour would be a real bug in the
  // *test*: the seam markers are close enough together to share a frame, and a
  // centroid taken over both of them lands between them and passes nothing
  // useful.
  const directions = <_Direction>[
    _Direction('centre', 0, 0, 0.95, 0.06, 0.06),
    _Direction('quarter left', 90, 0, 0.06, 0.92, 0.10),
    _Direction('quarter right', -90, 0, 0.10, 0.25, 0.95),
    // The wrap seam gets three markers, not two. One *astride* ±180°, which is
    // the only direction that exercises a sampler's horizontal wrap on both
    // sides of a single feature; and one on each side of it, far enough apart
    // to be told apart but close enough that a seam defect cannot hide.
    _Direction('astride +/-180', 180, 0, 0.95, 0.88, 0.06),
    _Direction('left of the seam', 168, 0, 0.95, 0.06, 0.88),
    _Direction('right of the seam', -168, 0, 0.06, 0.88, 0.95),
    _Direction('upper diagonal', 45, 40, 0.97, 0.52, 0.04),
    _Direction('lower diagonal', -135, -40, 0.55, 0.06, 0.95),
    _Direction('zenith', 0, 90, 0.06, 0.95, 0.55),
    _Direction('nadir', 0, -90, 0.85, 0.85, 0.85),
  ];

  /// Paints the markers into a ground truth, using **only** the hand-written
  /// formulas above.
  ///
  /// A marker is the set of pixels within [_markerRadius] of the hand-computed
  /// position, widened horizontally by `1/cos(pitch)` because that is what an
  /// equirectangular projection does to a circle on the sphere. At a pole the
  /// widening is unbounded and the marker becomes a full-width band, which is
  /// the faithful realisation of "the zenith is the top row": every column of
  /// that row *is* the zenith.
  FloatImage paintMarkers() {
    final image = FloatImage(width, height, 3);
    // Mid-grey background: far from every marker colour, and something for the
    // frames to expose against.
    for (var i = 0; i < image.data.length; i++) {
      image.data[i] = 0.45;
    }
    for (final direction in directions) {
      final cx = expectedX(direction.yawRadians);
      final cy = expectedY(direction.pitchRadians);
      final stretch = 1 / math.max(math.cos(direction.pitchRadians), 1e-3);
      final halfWidth = math.min(_markerRadius * stretch, width / 2 - 1);
      for (var y = 0; y < height; y++) {
        if ((y + 0.5 - cy).abs() > _markerRadius) continue;
        for (var x = 0; x < width; x++) {
          if (_wrappedDelta(x + 0.5, cx, width).abs() > halfWidth) continue;
          final o = image.offset(x, y);
          image.data[o] = direction.red;
          image.data[o + 1] = direction.green;
          image.data[o + 2] = direction.blue;
        }
      }
    }
    return image;
  }

  final markers = paintMarkers();

  // -------------------------------------------------------------------
  // 1. The independent check: one frame, aimed at one direction.
  // -------------------------------------------------------------------

  group('a camera aimed at a direction sees that marker on its axis', () {
    // `pristine`: no distortion, no vignetting, no noise, no motion. The frame
    // is a pure resample of the ground truth, so the centroid is limited only
    // by the resampler.
    final profile = SynthProfile.byName('pristine');
    final canvas = EquirectCanvas(width, height);
    final intrinsics = _frameIntrinsics();

    for (final direction in directions) {
      test(direction.name, () {
        final frame = FrameRenderer(
          profile: profile,
          canvas: canvas,
          groundTruth: markers,
        ).render(
          camera: SyntheticCamera.aimedAt(
            yaw: direction.yawRadians,
            pitch: direction.pitchRadians,
            intrinsics: intrinsics,
          ),
          evBias: 0,
          gain: 1,
          angularVelocity: _zero,
          lensOffset: _zero,
          rng: Rng(1),
        );

        final found = _centroidOf(frame, direction, directions, wrapX: false);
        expect(
          found,
          isNotNull,
          reason:
              'the "${direction.name}" marker is not in a frame aimed straight '
              'at it — the pose construction, the intrinsics or the equirect '
              'mapping disagrees with Math §3',
        );
        expect(
          found!.x,
          closeTo(intrinsics.cx, _framePixelTolerance),
          reason: 'the marker must sit on the principal point in x',
        );
        expect(
          found.y,
          closeTo(intrinsics.cy, _framePixelTolerance),
          reason: 'the marker must sit on the principal point in y',
        );
      });
    }
  });

  // -------------------------------------------------------------------
  // 2. The round trip: synth -> stitch -> compare.
  // -------------------------------------------------------------------

  group('synth -> stitch puts every marker back where Math §3 says', () {
    late StitchOutcome outcome;
    late Directory workspace;

    setUpAll(() async {
      workspace = await Directory.systemTemp.createTemp('sphere_sanity_');
      final bundle = await SynthRunner(
        profile: SynthProfile.byName('pristine'),
        groundTruthWidth: width,
        frameSize: _frameIntrinsics().imageSize,
        groundTruthOverride: markers,
      ).run(workspace);

      // The *reference* backend, not the control group: this test asks whether
      // the conventions are right, and the control group's deliberate 4% focal
      // error would move a marker several pixels for a reason that has nothing
      // to do with conventions.
      outcome = await const ReferenceDartStitcher().stitch(
        StitchJob(bundle: bundle, canvas: EquirectCanvas(width, height)),
      );
    });

    tearDownAll(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });

    for (final direction in directions) {
      test(direction.name, () {
        final found = _centroidOf(
          outcome.equirect,
          direction,
          directions,
          wrapX: true,
        );
        expect(
          found,
          isNotNull,
          reason:
              'the "${direction.name}" marker did not survive the round trip',
        );

        final wantY = expectedY(direction.pitchRadians);
        if (direction.isPole) {
          // A marker centred on the top or bottom row is necessarily cut in
          // half by the edge of the canvas — there are no rows beyond the pole
          // — so its centroid sits half a radius inside. Assert that it is hard
          // against the pole row rather than pretending the truncation is not
          // there.
          expect(
            (found!.y - wantY).abs(),
            lessThanOrEqualTo(_markerRadius),
            reason:
                'the ${direction.name} marker must lie against row '
                '${wantY.toStringAsFixed(0)}, half-truncated by the canvas '
                'edge; found ${found.y.toStringAsFixed(1)}',
          );
          // x carries no information at a pole — every column is the same
          // direction — so asserting it would be asserting an accident.
          return;
        }

        expect(
          found!.y,
          closeTo(wantY, _canvasPixelTolerance),
          reason: 'y must be H(1/2 - pitch/pi) = ${wantY.toStringAsFixed(1)}',
        );
        final wantX = expectedX(direction.yawRadians);
        expect(
          _wrappedDelta(found.x, wantX, width).abs(),
          lessThanOrEqualTo(_canvasPixelTolerance),
          reason:
              'x must be W(1/2 - yaw/2pi) = ${wantX.toStringAsFixed(1)}, '
              'found ${found.x.toStringAsFixed(1)}',
        );
      });
    }

    test('the seam markers keep their true angular separation', () {
      // The assertion no per-marker check can make. The three seam markers sit
      // at opposite ends of the canvas but are neighbours in the world: 168°,
      // 180° and −168° are 12° apart on the sphere. If the ±180° meridian is
      // handled as an image border rather than as a join, one of them is
      // duplicated, clipped, or has drifted across — and every one of those
      // still passes a tolerance check taken on the others.
      double xOf(int index) =>
          _centroidOf(outcome.equirect, directions[index], directions,
              wrapX: true)!.x;

      final astride = xOf(3);
      final left = xOf(4);
      final right = xOf(5);

      expect(
        _wrappedDelta(astride, left, width).abs() / width * 360,
        closeTo(12.0, 0.5),
        reason: 'the astride marker is 12 degrees from the one at yaw +168',
      );
      expect(
        _wrappedDelta(right, astride, width).abs() / width * 360,
        closeTo(12.0, 0.5),
        reason: 'and 12 degrees from the one at yaw -168',
      );
    });
  });
}

/// Radius of a painted marker, in ground-truth pixels.
const double _markerRadius = 5;

/// Tolerance on the frame-centre assertion, in frame pixels.
///
/// A marker of five ground-truth pixels is magnified by the frame's tighter
/// angular sampling, so its centroid inherits the resampler's smoothing at a
/// larger scale. Still orders of magnitude tighter than any convention error,
/// which moves a marker across the frame or out of it.
const double _framePixelTolerance = 3.0;

/// Tolerance on the round-trip assertion, in canvas pixels — the phase doc's
/// "within 2 px".
const double _canvasPixelTolerance = 2.0;

/// No rotation and no lens offset: this test is about geometry, not motion.
final Vector3 _zero = Vector3.zero();

/// The frame the markers are rendered into. Small and portrait, matching the
/// rig's shape, at the rig's true 50° horizontal field of view.
CameraIntrinsics _frameIntrinsics() => CameraIntrinsics.fromHorizontalFov(
  hfovRadians: 50 * math.pi / 180,
  imageSize: ImageSize.fromInts(240, 320),
);

/// One marker: a direction, and the colour that identifies it.
class _Direction {
  const _Direction(
    this.name,
    this.yawDegrees,
    this.pitchDegrees,
    this.red,
    this.green,
    this.blue,
  );

  final String name;
  final double yawDegrees;
  final double pitchDegrees;
  final double red;
  final double green;
  final double blue;

  double get yawRadians => yawDegrees * math.pi / 180;
  double get pitchRadians => pitchDegrees * math.pi / 180;

  bool get isPole => pitchDegrees.abs() == 90;

  /// Squared RGB distance from a pixel to this marker's colour.
  double distanceTo(double r, double g, double b) {
    final dr = r - red;
    final dg = g - green;
    final db = b - blue;
    return dr * dr + dg * dg + db * db;
  }
}

/// Centroid of the pixels belonging to [direction], or `null` if none.
///
/// A pixel counts only when [direction] is the *nearest* marker colour and the
/// pixel is close enough to it to not be a blend with the background. Nearest-
/// colour classification rather than a per-colour threshold because the
/// stitcher averages overlapping frames, so a marker's border is a gradient
/// towards grey and a fixed threshold would either clip the marker
/// asymmetrically or bleed into its neighbour.
///
/// [wrapX] makes the horizontal mean circular, which matters for exactly the
/// marker this test is most careful about: one sitting astride `x = 0` has
/// samples at both edges, and an arithmetic mean of those is the middle of the
/// image — a confidently wrong answer.
({double x, double y})? _centroidOf(
  FloatImage image,
  _Direction direction,
  List<_Direction> all, {
  required bool wrapX,
}) {
  const acceptance = 0.06; // squared RGB distance, i.e. ~0.25 per channel
  var sumY = 0.0;
  var sumSin = 0.0;
  var sumCos = 0.0;
  var sumX = 0.0;
  var weight = 0.0;

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final o = image.offset(x, y);
      final r = image.data[o];
      final g = image.data[o + 1];
      final b = image.data[o + 2];

      final distance = direction.distanceTo(r, g, b);
      if (distance > acceptance) continue;
      var nearest = true;
      for (final other in all) {
        if (identical(other, direction)) continue;
        if (other.distanceTo(r, g, b) < distance) {
          nearest = false;
          break;
        }
      }
      if (!nearest) continue;

      final w = acceptance - distance;
      final angle = 2 * math.pi * (x + 0.5) / image.width;
      sumSin += math.sin(angle) * w;
      sumCos += math.cos(angle) * w;
      sumX += (x + 0.5) * w;
      sumY += (y + 0.5) * w;
      weight += w;
    }
  }
  if (weight <= 0) return null;

  final x = wrapX
      ? (math.atan2(sumSin / weight, sumCos / weight) /
                    (2 * math.pi) *
                    image.width +
                image.width) %
            image.width
      : sumX / weight;
  return (x: x, y: sumY / weight);
}

/// Signed difference `a − b` on a circle of circumference [span].
double _wrappedDelta(double a, double b, int span) {
  var d = (a - b) % span;
  if (d > span / 2) d -= span;
  if (d < -span / 2) d += span;
  return d;
}
