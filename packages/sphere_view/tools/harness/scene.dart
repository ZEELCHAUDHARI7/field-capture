import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';
import 'rng.dart';

/// What kind of room to build.
enum SceneStyle {
  /// A fitted-out construction interior: brick, block, taped drywall, pipes,
  /// stencilled markings, a tiled slab. Feature-rich on every surface, which is
  /// the *easy* case for registration and therefore the right default.
  constructionInterior,

  /// Bare drywall and a raw slab, with the high-frequency detail turned almost
  /// all the way off. This is the site condition architecture §6.1 says stock
  /// OpenCV fails on, and the whole point of the `low_texture` profile.
  bareDrywall,

  /// The construction interior with real windows: 14 EV between the deepest
  /// corner and the sky outside. What Phase 05's bracket path exists for.
  hdrInterior,
}

/// What the scene has at one direction.
class SceneSample {
  /// Creates a sample.
  const SceneSample(this.red, this.green, this.blue, this.depth, this.evOffset);

  /// Display-referred red in `[0, 1]`.
  final double red;

  /// Display-referred green in `[0, 1]`.
  final double green;

  /// Display-referred blue in `[0, 1]`.
  final double blue;

  /// Distance from the room's centre to the surface, in metres. This is what
  /// makes honest parallax possible — §3 of the phase doc's option (a) needs a
  /// depth equirect, and a box room gives an exact one for free rather than a
  /// hand-painted approximation.
  final double depth;

  /// Stops of radiance above or below the display-referred value, i.e. the
  /// dynamic range the 8-bit ground truth cannot itself hold.
  final double evOffset;
}

/// A textured axis-aligned box room, sampled by ray casting from its centre.
///
/// A box rather than a photograph, for three reasons that all matter more than
/// realism. It is **exactly reproducible** from a seed, so a fixture is a few
/// hundred lines of code rather than megabytes of committed JPEG. It has
/// **analytic depth**, which is what the parallax profiles need and what a
/// depth-estimation model would only have approximated. And its texture
/// richness is a **dial**, so `low_texture` and `nominal` can differ in exactly
/// the one property Phase 03 has to degrade gracefully along, with nothing else
/// moving.
class RoomScene {
  /// Creates a room. The camera sits at the origin, so [floorY] is negative and
  /// [ceilingY] positive.
  RoomScene({
    required this.style,
    required this.halfX,
    required this.floorY,
    required this.ceilingY,
    required this.halfZ,
    this.dynamicRangeScale = 1.0,
    int seed = 0x5eed,
  }) : _coarse = ValueNoise(seed),
       _fine = ValueNoise(seed ^ 0x9e3779b9),
       _grain = ValueNoise(seed ^ 0x7f4a7c15);

  /// A room sized for the profile family that uses it.
  ///
  /// [nearestSurfaceMetres] drives the whole box: the `parallax_1m` profile is
  /// defined by its nearest wall being 1 m away, because that is what turns a
  /// 10 cm lens offset into the ~5.7° of irreducible disparity architecture §3
  /// tabulates. Everything else scales with it so the room stays a room.
  factory RoomScene.forStyle(
    SceneStyle style, {
    double nearestSurfaceMetres = 3.0,
    double dynamicRangeScale = 1.0,
    int seed = 0x5eed,
  }) {
    final s = nearestSurfaceMetres / 3.0;
    return RoomScene(
      style: style,
      halfX: 3.0 * s,
      floorY: -1.45 * s,
      ceilingY: 1.55 * s,
      halfZ: 4.2 * s,
      dynamicRangeScale: dynamicRangeScale,
      seed: seed,
    );
  }

  /// Which room this is.
  final SceneStyle style;

  /// Half the room's width, in metres. The `+X` wall carries the windows.
  final double halfX;

  /// Floor height relative to the camera, negative.
  final double floorY;

  /// Ceiling height relative to the camera, positive.
  final double ceilingY;

  /// Half the room's length, in metres.
  final double halfZ;

  /// Multiplier on every radiance offset, so a profile can flatten the scene's
  /// dynamic range to nothing.
  ///
  /// `pristine` sets this to zero, and needs to. Its promise is that the frames
  /// are an exact resample of the ground truth, so that any error in the output
  /// is the stitcher's — and a window sitting 1.5 stops above the interior
  /// breaks that promise before the stitcher is even involved, because a single
  /// exposure clips it and the frame simply does not contain what the reference
  /// says is there. Every other profile keeps its range: for them, a stitcher
  /// that ignores the bracket and uses only the 0 EV frame *should* be
  /// penalised for it.
  final double dynamicRangeScale;

  final ValueNoise _coarse;
  final ValueNoise _fine;
  final ValueNoise _grain;

  /// How much high-frequency detail the surfaces carry; the `low_texture`
  /// dial.
  double get _detail => style == SceneStyle.bareDrywall ? 0.06 : 1.0;

  /// Whether the room has windows to the outside.
  bool get _hasWindows => style != SceneStyle.bareDrywall;

  /// Stops the windows sit above the interior. 7 up and 7 down across the room
  /// is the 14 EV the phase doc names for `hdr_interior`.
  double get _windowStops => style == SceneStyle.hdrInterior ? 7.0 : 1.5;

  /// Casts a ray from the room's centre and shades where it lands.
  SceneSample sample(Vector3 direction) {
    // Exit distance of a ray from inside an axis-aligned box: the nearest
    // positive plane crossing on any axis.
    var t = double.infinity;
    var face = 3;
    void consider(double distance, int candidate) {
      if (distance > 0 && distance < t) {
        t = distance;
        face = candidate;
      }
    }

    if (direction.x.abs() > 1e-12) {
      consider(
        (direction.x > 0 ? halfX : -halfX) / direction.x,
        direction.x > 0 ? 0 : 1,
      );
    }
    if (direction.y.abs() > 1e-12) {
      consider(
        (direction.y > 0 ? ceilingY : floorY) / direction.y,
        direction.y > 0 ? 2 : 3,
      );
    }
    if (direction.z.abs() > 1e-12) {
      consider(
        (direction.z > 0 ? halfZ : -halfZ) / direction.z,
        direction.z > 0 ? 4 : 5,
      );
    }
    if (!t.isFinite) t = halfZ;

    final hit = direction * t;
    final (u, v) = switch (face) {
      0 || 1 => (hit.z, hit.y),
      2 || 3 => (hit.x, hit.z),
      _ => (hit.x, hit.y),
    };
    return _shade(face, u, v, t);
  }

  SceneSample _shade(int face, double u, double v, double depth) {
    var ev = 0.0;
    late double r, g, b;

    switch (face) {
      case 0:
        (r, g, b, ev) = _windowWall(u, v);
      case 1:
        (r, g, b) = _serviceWall(u, v);
      case 2:
        (r, g, b, ev) = _ceiling(u, v);
      case 3:
        (r, g, b) = _slab(u, v);
      case 4:
        (r, g, b) = _brickWall(u, v);
      default:
        (r, g, b) = _drywall(u, v);
    }

    // A dark end to the room, so `hdr_interior` has a genuine shadow side and
    // not just a blown highlight. Ramped rather than stepped: a hard edge in
    // the EV map would show up as a ghost seam that no stitcher caused.
    if (style == SceneStyle.hdrInterior) {
      final darkness = ((-u - halfZ * 0.1) / (halfZ * 0.9)).clamp(0.0, 1.0);
      ev -= 7.0 * darkness * darkness;
    }

    // Ambient occlusion towards the floor–wall junctions, which gives the
    // matcher a smooth low-frequency gradient to disagree about and makes a
    // gain error visible to the eye in the diff image.
    final shade = 1.0 - 0.18 * ((v - ceilingY).abs() / (ceilingY - floorY));
    final k = face == 2 || face == 3 ? 1.0 : shade;
    return SceneSample(
      (r * k).clamp(0.0, 1.0),
      (g * k).clamp(0.0, 1.0),
      (b * k).clamp(0.0, 1.0),
      depth,
      ev * dynamicRangeScale,
    );
  }

  /// Fine surface grain, the term `low_texture` turns down.
  double _texture(double u, double v, double scale) =>
      (_fine.fractal(u * scale, v * scale, 4) - 0.5) * 0.30 * _detail +
      (_grain.fractal(u * scale * 6, v * scale * 6, 2) - 0.5) * 0.14 * _detail;

  /// 1 inside a line of half-width [half] on the lattice of period [period].
  static double _line(double x, double period, double half) {
    final phase = (x / period - (x / period).floor()) * period;
    return phase < half || phase > period - half ? 1.0 : 0.0;
  }

  static bool _inRect(
    double u,
    double v,
    double u0,
    double v0,
    double u1,
    double v1,
  ) => u >= u0 && u <= u1 && v >= v0 && v <= v1;

  (double, double, double) _drywall(double u, double v) {
    var base = 0.62 + _texture(u, v, 2.2);
    // Taped board joints every 1.2 m, and screw dimples along them.
    base -= 0.05 * _line(u + 0.3, 1.2, 0.012);
    base -= 0.04 * _line(v, 2.4, 0.010);
    if (style != SceneStyle.bareDrywall) {
      // A door opening and a pair of back boxes.
      if (_inRect(u, v, -0.45, floorY, 0.45, floorY + 2.05)) {
        base = 0.30 + _texture(u, v, 9.0);
        if (_line(u + 0.45, 0.9, 0.03) > 0) base = 0.52;
      }
      if (_inRect(u, v, 1.4, floorY + 0.25, 1.55, floorY + 0.40)) base = 0.20;
      if (_inRect(u, v, -1.9, floorY + 1.15, -1.75, floorY + 1.30)) base = 0.20;
      // Stencilled setting-out marks.
      base -= 0.20 * _line(u - 0.6, 3.0, 0.008) * _line(v - 1.0, 6.0, 0.30);
    }
    return (base * 1.00, base * 0.99, base * 0.94);
  }

  (double, double, double) _brickWall(double u, double v) {
    if (style == SceneStyle.bareDrywall) return _drywall(u, v);
    const course = 0.0755;
    const brick = 0.24;
    final row = (v / course).floor();
    final offset = row.isEven ? 0.0 : brick / 2;
    final mortar =
        _line(v, course, 0.008) > 0 || _line(u + offset, brick, 0.008) > 0;
    if (mortar) {
      final m = 0.66 + _texture(u, v, 14.0) * 0.5;
      return (m, m * 0.99, m * 0.96);
    }
    // Per-brick colour jitter is what makes this a feature-rich surface rather
    // than a repeating pattern the matcher would happily mismatch.
    final id = _coarse.atLattice(((u + offset) / brick).floor(), row);
    final t = 0.44 + id * 0.20 + _texture(u, v, 20.0) * 0.6;
    return (t * 1.00, t * 0.62, t * 0.50);
  }

  (double, double, double) _serviceWall(double u, double v) {
    var (r, g, b) = _drywall(u, v);
    if (style == SceneStyle.bareDrywall) return (r, g, b);
    // Vertical service risers with a horizontal rail across them.
    for (final at in [-2.6, -1.1, 0.9, 2.7]) {
      final d = (u - at).abs();
      if (d < 0.055) {
        final round = math.sqrt(1 - (d / 0.055) * (d / 0.055));
        final t = 0.30 + 0.45 * round + _texture(v, u, 30.0) * 0.4;
        return (t * 0.92, t * 0.95, t);
      }
    }
    if (_inRect(u, v, -halfZ, 0.55, halfZ, 0.63)) {
      final t = 0.58 + _texture(u, v, 24.0);
      return (t, t * 0.96, t * 0.86);
    }
    return (r, g, b);
  }

  (double, double, double, double) _windowWall(double u, double v) {
    final (r, g, b) = _drywall(u, v);
    if (!_hasWindows) return (r, g, b, 0.0);
    for (final centre in [-1.9, 1.9]) {
      if (!_inRect(u, v, centre - 1.0, floorY + 0.9, centre + 1.0, ceilingY - 0.25)) {
        continue;
      }
      // Frame and mullions read as dark against the sky, which is exactly the
      // edge a gain error or a ghost shows up on.
      final frame =
          _line(u - centre + 1.0, 2.0, 0.05) > 0 ||
          _line(v - floorY - 0.9, ceilingY - 0.25 - floorY - 0.9, 0.05) > 0 ||
          (u - centre).abs() < 0.035;
      if (frame) return (0.16, 0.16, 0.17, 0.0);
      // Sky, with a hint of cloud so the highlight is not a flat plateau.
      final cloud = _coarse.fractal(u * 0.9, v * 0.9, 3);
      final sky = 0.86 + 0.12 * cloud;
      return (sky * 0.93, sky * 0.97, sky, _windowStops);
    }
    return (r, g, b, 0.0);
  }

  (double, double, double, double) _ceiling(double u, double v) {
    var base = 0.72 + _texture(u, v, 1.8);
    base -= 0.06 * _line(u, 0.6, 0.010);
    base -= 0.06 * _line(v, 0.6, 0.010);
    if (style != SceneStyle.bareDrywall) {
      for (final at in [-1.8, 1.8]) {
        if (_inRect(u, v, -0.30, at - 0.62, 0.30, at + 0.62)) {
          return (0.97, 0.96, 0.92, style == SceneStyle.hdrInterior ? 3.5 : 1.0);
        }
      }
    }
    return (base, base, base * 0.98, 0.0);
  }

  (double, double, double) _slab(double u, double v) {
    var base = 0.40 + _texture(u, v, 2.6);
    // Saw-cut control joints, and the aggregate that makes a slab a slab.
    base -= 0.10 * _line(u + 0.4, 1.5, 0.010);
    base -= 0.10 * _line(v + 0.7, 1.5, 0.010);
    if (style != SceneStyle.bareDrywall) {
      base += 0.30 * (_grain.fractal(u * 60, v * 60, 1) - 0.62).clamp(0.0, 1.0);
      // A painted walkway line: a long, high-contrast, straight feature, which
      // is the kind of structure a mis-registered stitch bends visibly.
      if (_inRect(u, v, -0.10, -halfZ, 0.10, halfZ)) base = 0.78;
    }
    return (base * 0.98, base, base * 0.96);
  }

  /// Renders the room to the three equirectangular maps the rig runs on.
  ///
  /// One pass rather than three, because all three come off the same ray cast
  /// and re-casting would be both slower and — if the box arithmetic ever
  /// changed — a way for the depth map to disagree with the image it belongs
  /// to.
  ({FloatImage image, FloatImage depth, FloatImage ev}) render(
    EquirectCanvas canvas,
  ) {
    final image = FloatImage(canvas.width, canvas.height, 3);
    final depth = FloatImage(canvas.width, canvas.height, 1);
    final ev = FloatImage(canvas.width, canvas.height, 1);
    for (var y = 0; y < canvas.height; y++) {
      for (var x = 0; x < canvas.width; x++) {
        final s = sample(canvas.directionForPixel(x + 0.5, y + 0.5));
        final o = (y * canvas.width + x) * 3;
        image.data[o] = s.red;
        image.data[o + 1] = s.green;
        image.data[o + 2] = s.blue;
        depth.data[y * canvas.width + x] = s.depth;
        ev.data[y * canvas.width + x] = s.evOffset;
      }
    }
    return (image: image, depth: depth, ev: ev);
  }
}
