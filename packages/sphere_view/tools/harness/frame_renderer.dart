import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';
import 'profiles.dart';
import 'rng.dart';

/// Renders one frame of one bracket: the eleven steps in §1 of the phase doc,
/// from a ground-truth equirect to something that looks like it came off a
/// sensor.
///
/// The steps run in a slightly different order than they are listed, and the
/// difference is deliberate. The doc lists gain (4), bracket (5), noise (6),
/// blur (7), rolling shutter (8); physically, blur and rolling shutter happen
/// *during* integration, while noise is added to the collected charge, and the
/// response curve acts last of all. Running them in the listed order would put
/// a blur kernel across already-quantised noise, which smooths the noise into
/// something no sensor produces and would flatter any denoising the pipeline
/// later does. So the actual order is:
///
/// > sample + rolling shutter → vignette → gain → EV bias → motion blur →
/// > shot and read noise → camera response and clip
///
/// Everything up to the response happens in **linear radiance**, where `1.0` is
/// the sensor's saturation point at 0 EV. That is what makes the clipping in
/// `hdr_interior` mean something.
class FrameRenderer {
  /// Creates a renderer over one scene's maps.
  FrameRenderer({
    required this.profile,
    required this.canvas,
    required this.groundTruth,
    this.depth,
    this.ev,
  });

  /// The profile whose knobs govern every step.
  final SynthProfile profile;

  /// Geometry of [groundTruth].
  final EquirectCanvas canvas;

  /// The display-referred ground-truth equirect.
  final FloatImage groundTruth;

  /// True depth in metres per direction; required when the profile has a lens
  /// offset, unused otherwise.
  final FloatImage? depth;

  /// Radiance offset in stops per direction; `null` when the scene fits in the
  /// 8-bit ground truth on its own.
  final FloatImage? ev;

  /// Renders one exposure.
  ///
  /// [camera] carries the **true** pose, intrinsics and lens — the perturbed
  /// versions exist only in `bundle.json` and never reach this method, which is
  /// what stops the rig from accidentally rendering the error it is supposed to
  /// be simulating.
  FloatImage render({
    required SyntheticCamera camera,
    required double evBias,
    required double gain,
    required Vector3 angularVelocity,
    required Vector3 lensOffset,
    required Rng rng,
  }) {
    final width = camera.intrinsics.imageSize.width.round();
    final height = camera.intrinsics.imageSize.height.round();
    final frame = FloatImage(width, height, 3);

    // Steps 1, 2, 3, 8 and 11 in one pass over the destination pixels.
    _sample(frame, camera, angularVelocity, lensOffset);

    // Steps 4 and 5: the AE lock that is not quite a lock, then the bracket.
    frame.scale(gain * math.pow(2.0, evBias).toDouble());

    _applyMotionBlur(frame, camera, angularVelocity);
    _applyNoise(frame, rng);
    _applyResponse(frame);
    return frame;
  }

  /// Steps 1, 2, 3, 8 and 11, fused into one pass.
  ///
  /// The doc describes sampling and distortion as separate stages, and they are
  /// separate *mathematically*; composing them into a single lookup is the same
  /// mapping with one interpolation instead of two, which is strictly better —
  /// a second bicubic pass would add its own softening to every frame and eat
  /// into the very PSNR margin criterion S6 is asking about.
  ///
  /// Vignetting joins them for a blunter reason: it needs the angle between the
  /// pixel's ray and the optical axis, and the ray is already in hand here. Run
  /// as its own pass it has to reconstruct every ray from scratch, and
  /// reconstructing a ray means inverting the distortion again — which is the
  /// single most expensive thing this file does. Folding it in roughly halves
  /// the cost of rendering a frame.
  void _sample(
    FloatImage frame,
    SyntheticCamera camera,
    Vector3 angularVelocity,
    Vector3 lensOffset,
  ) {
    final width = frame.width;
    final height = frame.height;
    final rgb = List<double>.filled(3, 0);
    final scalar = List<double>.filled(1, 0);
    final evMap = ev;
    final parallax = lensOffset.length2 > 0 ? depth : null;
    final readout = profile.rollingShutterSeconds;
    final speed = angularVelocity.length;
    final vignetteExponent = 4 * profile.vignetting;
    final vignetting = profile.vignetting != 0;
    // `cos⁴` is the textbook case and is three multiplies; `pow` is not, and at
    // 300k pixels a frame the difference is measurable.
    final plainCos4 = profile.vignetting == 1.0;

    for (var y = 0; y < height; y++) {
      // Step 8, rolling shutter: each row is exposed at a different instant, so
      // each row sees a different rotation. Rows are read top-to-bottom, and
      // the pose the bundle records belongs to the middle of the frame, so the
      // offset is centred — otherwise the skew would masquerade as a constant
      // pose bias that bundle adjustment would happily absorb.
      final rowCamera = readout <= 0 || speed == 0
          ? camera
          : SyntheticCamera(
              deviceToWorld:
                  _rotationAbout(
                    angularVelocity / speed,
                    speed * readout * ((y + 0.5) / height - 0.5),
                  ) *
                  camera.deviceToWorld,
              intrinsics: camera.intrinsics,
              distortion: camera.distortion,
            );

      for (var x = 0; x < width; x++) {
        // Steps 1 and 2: which world ray reaches this *distorted* pixel.
        var direction = rowCamera.rayForPixel(x + 0.5, y + 0.5);
        if (parallax != null) {
          direction = _reprojectThroughDepth(
            direction,
            lensOffset,
            parallax,
            scalar,
          );
        }

        // Step 3: `cos⁴θ` falloff. The cosine is the dot product with the
        // optical axis — no `acos` then `cos` round trip.
        var falloff = 1.0;
        if (vignetting) {
          final c = rowCamera.cosineFromAxis(direction).clamp(0.0, 1.0);
          falloff = plainCos4
              ? c * c * c * c
              : math.pow(c, vignetteExponent).toDouble();
        }

        final p = canvas.pixelForDirection(direction);
        groundTruth.sampleBicubic(p.x - 0.5, p.y - 0.5, rgb);

        var stops = 0.0;
        if (evMap != null) {
          evMap.sampleBilinear(p.x - 0.5, p.y - 0.5, scalar);
          stops = scalar[0];
        }
        final radiance = stops == 0 ? 1.0 : math.pow(2.0, stops).toDouble();

        final scale = radiance * falloff;
        final o = frame.offset(x, y);
        frame.data[o] = ToneCurve.toLinear(rgb[0].clamp(0.0, 1.0)) * scale;
        frame.data[o + 1] = ToneCurve.toLinear(rgb[1].clamp(0.0, 1.0)) * scale;
        frame.data[o + 2] = ToneCurve.toLinear(rgb[2].clamp(0.0, 1.0)) * scale;
      }
    }
  }

  /// Step 11: parallax, by option (a) of §3 — reproject through the depth
  /// equirect from a displaced entrance pupil.
  ///
  /// The ground truth is a panorama seen from one point; a camera whose pupil
  /// has moved to `C` sees, along its ray `d`, whatever surface is at the
  /// distance `s` where the ray meets the depth surface:
  ///
  /// ```
  /// ‖C + s·d‖ = depth( direction of C + s·d )
  /// ```
  ///
  /// Squaring the left side turns each step into a quadratic in `s` with the
  /// current depth estimate held fixed, so the iteration is closed-form rather
  /// than a march, and converges in a handful of steps because the offset is
  /// centimetres against metres of depth. Where it does not converge — a
  /// genuine disocclusion, a surface the original viewpoint never saw — the
  /// undisplaced sample stands in, which is the background-layer fill §3 asks
  /// for and is exactly as honest as the situation allows: that content does
  /// not exist anywhere in the ground truth.
  Vector3 _reprojectThroughDepth(
    Vector3 direction,
    Vector3 offset,
    FloatImage depthMap,
    List<double> scalar,
  ) {
    final b = offset.dot(direction);
    final c = offset.length2;
    var current = direction;
    for (var i = 0; i < 6; i++) {
      final p = canvas.pixelForDirection(current);
      depthMap.sampleBilinear(p.x - 0.5, p.y - 0.5, scalar);
      final d = scalar[0];
      final discriminant = b * b - c + d * d;
      if (discriminant <= 0) return direction;
      final s = -b + math.sqrt(discriminant);
      if (s <= 0) return direction;
      current = (offset + direction * s).normalized();
    }
    return current;
  }

  /// Step 7: directional blur along the image motion the shutter integrated
  /// over.
  ///
  /// The direction and length are *measured*, not assumed: the frame centre is
  /// projected under the pose at the start and at the end of the exposure, and
  /// the pixel difference between them is the smear. That keeps the blur
  /// consistent with the rolling shutter above, which is driven by the same
  /// angular velocity, instead of being a second unrelated knob that could
  /// disagree with it.
  void _applyMotionBlur(
    FloatImage frame,
    SyntheticCamera camera,
    Vector3 angularVelocity,
  ) {
    final speed = angularVelocity.length;
    if (speed == 0 || profile.exposureSeconds <= 0) return;

    final centre = camera.rayForPixel(
      camera.intrinsics.cx,
      camera.intrinsics.cy,
    );
    final rotated =
        _rotationAbout(
          angularVelocity / speed,
          speed * profile.exposureSeconds,
        ).transformed(centre);
    final from = camera.pixelForRay(centre);
    final to = camera.pixelForRay(rotated);
    if (from == null || to == null) return;

    final dx = to.x - from.x;
    final dy = to.y - from.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 0.75) return;

    final taps = math.max(2, length.ceil());
    final stepX = dx / (taps - 1);
    final stepY = dy / (taps - 1);
    final source = frame.clone();
    final rgb = List<double>.filled(3, 0);

    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        var r = 0.0, g = 0.0, b = 0.0;
        for (var t = 0; t < taps; t++) {
          final k = t - (taps - 1) / 2;
          source.sampleBilinear(x + k * stepX, y + k * stepY, rgb);
          r += rgb[0];
          g += rgb[1];
          b += rgb[2];
        }
        final o = frame.offset(x, y);
        frame.data[o] = r / taps;
        frame.data[o + 1] = g / taps;
        frame.data[o + 2] = b / taps;
      }
    }
  }

  /// Step 6: Poisson shot noise scaled by the collected charge, plus Gaussian
  /// read noise.
  ///
  /// The Poisson draw is approximated by a Gaussian of matching variance, which
  /// is accurate above a few dozen electrons and wrong only where read noise
  /// dominates anyway. What matters for the harness is the *structure*: noise
  /// that grows as the square root of the signal is what makes a `−2 EV` frame
  /// genuinely worse in the shadows than a `0 EV` one, which is the whole
  /// reason Mertens fusion has something to prefer.
  void _applyNoise(FloatImage frame, Rng rng) {
    final well = profile.fullWellElectrons;
    final read = profile.readNoiseElectrons;
    if (!well.isFinite && read == 0) return;
    for (var i = 0; i < frame.data.length; i++) {
      final electrons = frame.data[i] * well;
      var noisy = electrons;
      if (well.isFinite && electrons > 0) {
        noisy += rng.gaussian() * math.sqrt(electrons);
      }
      if (read > 0) noisy += rng.gaussian() * read;
      frame.data[i] = noisy / well;
    }
  }

  /// Step 5's second half: the camera response, and the clip that makes a blown
  /// window blown.
  void _applyResponse(FloatImage frame) {
    for (var i = 0; i < frame.data.length; i++) {
      frame.data[i] = ToneCurve.toDisplay(frame.data[i]).clamp(0.0, 1.0);
    }
  }

  /// Rotation of [angle] radians about the unit [axis], by Rodrigues.
  static Matrix3 _rotationAbout(Vector3 axis, double angle) {
    final c = math.cos(angle);
    final s = math.sin(angle);
    final t = 1 - c;
    final x = axis.x, y = axis.y, z = axis.z;
    return Matrix3(
      // Matrix3's positional constructor is column-major, so this is the
      // transpose of how Rodrigues is usually written out.
      t * x * x + c, t * x * y + s * z, t * x * z - s * y,
      t * x * y - s * z, t * y * y + c, t * y * z + s * x,
      t * x * z + s * y, t * y * z - s * x, t * z * z + c,
    );
  }

  /// Exposed for the pose perturbation in `synth_runner`, which needs exactly
  /// this rotation and must not grow a second copy of it.
  static Matrix3 rotationAbout(Vector3 axis, double angle) =>
      _rotationAbout(axis, angle);

  /// Encodes a rendered frame to 8-bit RGB bytes, ready for PNG.
  static Uint8List toBytes(FloatImage frame) {
    final out = Uint8List(frame.width * frame.height * 3);
    for (var i = 0; i < out.length; i++) {
      out[i] = (frame.data[i] * 255).round().clamp(0, 255);
    }
    return out;
  }
}
