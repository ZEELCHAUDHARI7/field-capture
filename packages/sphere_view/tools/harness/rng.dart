import 'dart:math' as math;

/// A seeded random source, and a hash-based value-noise field, both of which
/// must be **exactly reproducible** across runs and machines.
///
/// Reproducibility is not tidiness here. A profile is a regression fixture: if
/// `nominal` renders with different sensor noise on Tuesday than it did on
/// Monday, then every metric moves for reasons that have nothing to do with the
/// stitcher, and `quality_gate.sh` can no longer tell a regression from the
/// weather. So every stochastic quantity in the rig traces back to one of
/// these, seeded from the profile name and the frame index.
class Rng {
  /// Creates a source seeded by [seed].
  Rng(int seed) : _random = math.Random(seed);

  final math.Random _random;
  double? _spare;

  /// Uniform in `[0, 1)`.
  double next() => _random.nextDouble();

  /// Uniform in `[low, high)`.
  double range(double low, double high) => low + (high - low) * next();

  /// Standard normal, by Box–Muller. The second variate of each pair is kept
  /// rather than discarded, so a caller drawing `n` samples consumes `n/2`
  /// pairs and the stream stays reproducible under refactoring.
  double gaussian() {
    final spare = _spare;
    if (spare != null) {
      _spare = null;
      return spare;
    }
    double u, v, s;
    do {
      u = next() * 2 - 1;
      v = next() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);
    final f = math.sqrt(-2 * math.log(s) / s);
    _spare = v * f;
    return u * f;
  }

  /// A direction drawn uniformly from the unit sphere.
  List<double> unitVector() {
    final z = range(-1, 1);
    final t = range(0, 2 * math.pi);
    final r = math.sqrt(1 - z * z);
    return [r * math.cos(t), r * math.sin(t), z];
  }

  /// Deterministic 32-bit hash of three integers, used to seed per-frame
  /// streams from (profile, position, exposure) without a global counter.
  static int hashSeed(int a, int b, int c) {
    var h = 0x811c9dc5;
    for (final value in [a, b, c]) {
      h ^= value & 0xffff;
      h = (h * 0x01000193) & 0x7fffffff;
      h ^= (value >> 16) & 0xffff;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Deterministic seed from a string, so a profile name alone fixes a stream.
  static int seedFromString(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

/// Multi-octave value noise on a 2D lattice — the texture generator behind
/// every surface in the synthetic room.
///
/// Value noise rather than a photograph because a committed fixture has to be
/// small, and because the scene needs a *tunable* amount of high-frequency
/// detail: `low_texture` and `nominal` differ mainly in how much of this there
/// is, and that is exactly the axis Phase 03 has to degrade gracefully along.
class ValueNoise {
  /// Creates a field with the given [seed].
  const ValueNoise(this.seed);

  /// Chooses the lattice; two fields with different seeds are independent.
  final int seed;

  /// Value in `[0, 1)` at lattice point ([x], [y]).
  double atLattice(int x, int y) {
    var h = seed;
    h ^= x * 0x27d4eb2d;
    h = (h ^ (h >> 15)) & 0x7fffffff;
    h ^= y * 0x165667b1;
    h = (h ^ (h >> 13)) & 0x7fffffff;
    h = (h * 0x2545f491) & 0x7fffffff;
    return ((h ^ (h >> 16)) & 0xffffff) / 0x1000000;
  }

  /// Smoothly interpolated noise at continuous ([x], [y]).
  double sample(double x, double y) {
    final xi = x.floor();
    final yi = y.floor();
    final tx = _smoothstep(x - xi);
    final ty = _smoothstep(y - yi);
    final a = atLattice(xi, yi);
    final b = atLattice(xi + 1, yi);
    final c = atLattice(xi, yi + 1);
    final d = atLattice(xi + 1, yi + 1);
    return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty;
  }

  /// Sum of [octaves] doublings, each at half the amplitude — normalised so the
  /// result stays in `[0, 1)` whatever the octave count.
  double fractal(double x, double y, int octaves) {
    var value = 0.0;
    var amplitude = 1.0;
    var total = 0.0;
    var frequency = 1.0;
    for (var i = 0; i < octaves; i++) {
      value += sample(x * frequency, y * frequency) * amplitude;
      total += amplitude;
      amplitude *= 0.5;
      frequency *= 2;
    }
    return value / total;
  }

  static double _smoothstep(double t) => t * t * (3 - 2 * t);
}
