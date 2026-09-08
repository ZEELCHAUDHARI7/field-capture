import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/quaternion_utils.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

/// Pins `phases/01_MATH_AND_CONVENTIONS.md` §2 and §3 against values computed
/// by hand, not against the implementation.
///
/// That document opens by saying mismatched conventions are the single most
/// common cause of mirrored, upside-down and 90°-rotated panoramas, and that
/// the bugs are maddening because each component looks correct on its own. The
/// only defence is a test that knows the right answers independently — so every
/// expectation below is derived in a comment from the document, and none of it
/// is read off the code.
void main() {
  group('§2 — the OpenCV rotation conversion', () {
    // R_opencv = M · R_wd · N
    //   N = diag( 1, −1, −1)   device D → OpenCV camera C   (180° about X)
    //   M = diag(−1, −1,  1)   world  W → OpenCV pano   P   (180° about Z)
    // Both have det = +1, so both are proper rotations.
    //
    // Because both are diagonal, the product is a pure sign flip:
    //   R_opencv[i][j] = s_i · R_wd[i][j] · t_j,  s = (−1,−1,+1), t = (+1,−1,−1)

    /// Multiplies a row-major 3×3 by a column vector, so the test never depends
    /// on `vector_math`'s matrix layout.
    Vector3 apply(List<double> m, Vector3 v) => Vector3(
      m[0] * v.x + m[1] * v.y + m[2] * v.z,
      m[3] * v.x + m[4] * v.y + m[5] * v.z,
      m[6] * v.x + m[7] * v.y + m[8] * v.z,
    );

    void expectVector(Vector3 actual, Vector3 expected, {String? reason}) {
      expect(actual.x, closeTo(expected.x, 1e-12), reason: reason);
      expect(actual.y, closeTo(expected.y, 1e-12), reason: reason);
      expect(actual.z, closeTo(expected.z, 1e-12), reason: reason);
    }

    test('the identity device pose gives diag(-1, 1, -1), hand-computed', () {
      // R_wd = I, so R_opencv[i][j] = s_i · δ_ij · t_j, i.e. diag(s_i · t_i)
      //   = diag(−1·1, −1·−1, 1·−1) = diag(−1, +1, −1).
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(
        Quaternion.identity(),
      );
      expect(r, hasLength(9));
      final expected = <double>[-1, 0, 0, 0, 1, 0, 0, 0, -1];
      for (var i = 0; i < 9; i++) {
        expect(r[i], closeTo(expected[i], 1e-12), reason: 'element $i');
      }
    });

    test('OpenCV camera forward (0,0,1)_c maps to the device optical axis', () {
      // Document's verification, first bullet:
      //   N·(0,0,1) = (0,0,−1)_d — the device's optical axis ✓
      //   R_wd·(0,0,−1)_d = the world heading
      //   M· that lands in P ✓
      //
      // Concretely, for R_wd = I: the camera looks along −Z_w, and since
      // z_p = z_w, that is (0,0,−1)_p.
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(
        Quaternion.identity(),
      );
      expectVector(
        apply(r, Vector3(0, 0, 1)),
        Vector3(0, 0, -1),
        reason: 'camera forward must be −Z in the pano frame when level',
      );
    });

    test('OpenCV camera up (0,-1,0)_c maps to world up', () {
      // Document's verification, second bullet:
      //   N·(0,−1,0) = (0,1,0)_d — up the screen ✓
      //   held level that is world up (0,1,0)_w
      //   M·(0,1,0)_w = (0,−1,0)_p, which in a Y-down frame is up ✓
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(
        Quaternion.identity(),
      );
      expectVector(
        apply(r, Vector3(0, -1, 0)),
        Vector3(0, -1, 0),
        reason: 'camera up must be −Y in the Y-down pano frame',
      );
    });

    test('a +90° rotation about world Y sends camera forward to +X in P', () {
      // Rotation by +90° about Y takes (0,0,−1) to (−1,0,0):
      //   x' = x·cosθ + z·sinθ = −1,   z' = −x·sinθ + z·cosθ = 0.
      // So the optical axis, −Z_d, lands on world −X; and x_p = −x_w, so in
      // the pano frame P that is (+1, 0, 0).
      final q = Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2);
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(q);
      expectVector(apply(r, Vector3(0, 0, 1)), Vector3(1, 0, 0));
    });

    test('the conversion stays a proper rotation: orthonormal, det +1', () {
      // M and N are both proper, so M·R·N must be too. If this ever fails, the
      // pipeline is mirroring the panorama.
      final q = Quaternion.euler(0.3, -0.7, 1.1)..normalize();
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(q);
      final rows = [
        Vector3(r[0], r[1], r[2]),
        Vector3(r[3], r[4], r[5]),
        Vector3(r[6], r[7], r[8]),
      ];
      for (var i = 0; i < 3; i++) {
        expect(rows[i].length, closeTo(1.0, 1e-12), reason: 'row $i unit');
        for (var j = i + 1; j < 3; j++) {
          expect(
            rows[i].dot(rows[j]),
            closeTo(0.0, 1e-12),
            reason: 'rows $i,$j orthogonal',
          );
        }
      }
      final det =
          r[0] * (r[4] * r[8] - r[5] * r[7]) -
          r[1] * (r[3] * r[8] - r[5] * r[6]) +
          r[2] * (r[3] * r[7] - r[4] * r[6]);
      expect(det, closeTo(1.0, 1e-12), reason: 'det +1, not a reflection');
    });

    test('DevicePose.toOpenCvRotation agrees with the conversion', () {
      final q = Quaternion.axisAngle(Vector3(0, 1, 0), 0.42)..normalize();
      final pose = DevicePose(
        deviceToWorld: q,
        gravityWorld: Vector3(0, 1, 0),
        timestampUs: 1,
        angularSpeedRadPerSec: 0,
      );
      expect(
        pose.toOpenCvRotation(),
        SphericalConventions.openCvRotationFromDeviceToWorld(q),
      );
    });
  });

  group('§3 — the equirectangular mapping', () {
    // x_img = W · (½ − yaw   / 2π)
    // y_img = H · (½ − pitch /  π)
    const w = 6144.0;
    const h = 3072.0;

    test('the consequences table, hand-computed', () {
      // | image centre x = W/2 | yaw 0 = session-start heading |
      expect(SphericalConventions.xForYaw(0, w), closeTo(w / 2, 1e-9));
      // | left edge x = 0 | yaw +π (behind you) |
      expect(SphericalConventions.xForYaw(math.pi, w), closeTo(0, 1e-9));
      // | right edge x = W | yaw −π (same meridian) |
      expect(SphericalConventions.xForYaw(-math.pi, w), closeTo(w, 1e-9));
      // | top row y = 0 | pitch +π/2 = zenith |
      expect(SphericalConventions.yForPitch(math.pi / 2, h), closeTo(0, 1e-9));
      // | bottom row y = H | pitch −π/2 = nadir |
      expect(SphericalConventions.yForPitch(-math.pi / 2, h), closeTo(h, 1e-9));
      // | equator |
      expect(SphericalConventions.yForPitch(0, h), closeTo(h / 2, 1e-9));
    });

    test('turning right moves content right — the not-mirrored check', () {
      // Turning right is yaw decreasing. At yaw −π/2:
      //   x = 6144 · (0.5 + 0.25) = 4608, i.e. right of centre.
      expect(
        SphericalConventions.xForYaw(-math.pi / 2, w),
        closeTo(4608.0, 1e-9),
      );
      // And at yaw +π/2, left of centre.
      expect(
        SphericalConventions.xForYaw(math.pi / 2, w),
        closeTo(1536.0, 1e-9),
      );
    });

    test('a 45° up-and-left direction lands where hand arithmetic says', () {
      // yaw = +π/4 → x = 6144 · (0.5 − 0.125) = 2304
      // pitch = +π/4 → y = 3072 · (0.5 − 0.25) = 768
      expect(
        SphericalConventions.xForYaw(math.pi / 4, w),
        closeTo(2304.0, 1e-9),
      );
      expect(
        SphericalConventions.yForPitch(math.pi / 4, h),
        closeTo(768.0, 1e-9),
      );
    });

    test('the stated inverses really are inverses', () {
      for (final yaw in [-3.0, -1.0, 0.0, 0.5, 2.5, math.pi]) {
        expect(
          SphericalConventions.yawForX(
            SphericalConventions.xForYaw(yaw, w),
            w,
          ),
          closeTo(yaw, 1e-9),
        );
      }
      for (final pitch in [-1.5, -0.3, 0.0, 0.9, math.pi / 2]) {
        expect(
          SphericalConventions.pitchForY(
            SphericalConventions.yForPitch(pitch, h),
            h,
          ),
          closeTo(pitch, 1e-9),
        );
      }
    });

    test('matches the OpenCV SphericalProjector it was derived from', () {
      // The document derives the two formulas from OpenCV's mapForward:
      //   u = scale · atan2(x_p, z_p)      v = scale · (π − acos(ŷ_p))
      // with scale = W/2π, x_img = u + W/2, y_img = v, and the frame change
      // x_p = −x_w, y_p = −y_w, z_p = z_w. Recompute that path independently
      // and require the same pixels.
      final scale = SphericalConventions.sphericalWarperScale(w);
      expect(scale, closeTo(w / (2 * math.pi), 1e-12));

      for (final yaw in [-2.2, -0.4, 0.0, 1.3, 3.0]) {
        for (final pitch in [-1.2, -0.2, 0.0, 0.6, 1.4]) {
          final d = SphericalConventions.directionOf(yaw, pitch);
          final xp = -d.x, yp = -d.y, zp = d.z;

          final u = scale * math.atan2(xp, zp);
          final v = scale * (math.pi - math.acos(yp.clamp(-1.0, 1.0)));

          expect(
            u + w / 2,
            closeTo(SphericalConventions.xForYaw(yaw, w), 1e-9),
            reason: 'x at yaw $yaw',
          );
          expect(
            v,
            closeTo(SphericalConventions.yForPitch(pitch, h), 1e-9),
            reason: 'y at pitch $pitch',
          );
        }
      }
    });
  });

  group('§3 — direction ↔ angles', () {
    test('yaw = atan2(d.x, d.z), pitch = asin(d.y)', () {
      // +Z_w is the session-start heading, so it must be yaw 0, pitch 0.
      expect(SphericalConventions.yawOf(Vector3(0, 0, 1)), closeTo(0, 1e-12));
      expect(SphericalConventions.pitchOf(Vector3(0, 0, 1)), closeTo(0, 1e-12));
      // +Y_w is up, so pitch +π/2.
      expect(
        SphericalConventions.pitchOf(Vector3(0, 1, 0)),
        closeTo(math.pi / 2, 1e-12),
      );
      // +X_w is to the observer's left when looking along +Z, i.e. yaw +π/2.
      expect(
        SphericalConventions.yawOf(Vector3(1, 0, 0)),
        closeTo(math.pi / 2, 1e-12),
      );
    });

    test('directionOf round-trips through yawOf/pitchOf', () {
      for (final yaw in [-2.9, -1.0, 0.0, 0.7, 3.0]) {
        for (final pitch in [-1.4, -0.5, 0.0, 0.8, 1.5]) {
          final d = SphericalConventions.directionOf(yaw, pitch);
          expect(d.length, closeTo(1.0, 1e-12));
          expect(SphericalConventions.yawOf(d), closeTo(yaw, 1e-9));
          expect(SphericalConventions.pitchOf(d), closeTo(pitch, 1e-9));
        }
      }
    });

    test('DevicePose.forward is the device −Z axis in world coordinates', () {
      // A level device looking along +Z_w has yaw 0 and pitch 0.
      final level = DevicePose(
        deviceToWorld: Quaternion.identity(),
        gravityWorld: Vector3(0, 1, 0),
        timestampUs: 0,
        angularSpeedRadPerSec: 0,
      );
      expect(level.forward.x, closeTo(0, 1e-12));
      expect(level.forward.y, closeTo(0, 1e-12));
      expect(level.forward.z, closeTo(-1, 1e-12));
      // Which, per §3, is yaw π — directly behind the session-start heading —
      // because the device frame's optical axis is −Z_d, and the identity pose
      // means −Z_d coincides with −Z_w.
      expect(level.yaw.abs(), closeTo(math.pi, 1e-12));
      expect(level.pitch, closeTo(0, 1e-12));
    });

    test('DevicePose.yaw agrees with the rotation it hands the stitcher', () {
      // The identity pose above cannot catch this, because a symmetric matrix
      // is its own transpose. `vector_math` is internally inconsistent about
      // which way a quaternion turns things — `q.rotated(v)` applies the
      // *inverse* of `q.asRotationMatrix()` — and this class uses the
      // quaternion form for `yaw`/`pitch` and the matrix form for
      // `toOpenCvRotation`. Mixing them gives a package whose on-screen yaw and
      // whose stitched panorama disagree about which way the user turned:
      // exactly the mirrored-panorama family this document opens by warning
      // about, and invisible because each half is self-consistent.
      const yaw = 30 * math.pi / 180;
      final pose = DevicePose(
        deviceToWorld: SphericalConventions.aimingOrientation(yaw, 0),
        gravityWorld: Vector3(0, 1, 0),
        timestampUs: 0,
        angularSpeedRadPerSec: 0,
      );
      expect(
        pose.yaw,
        closeTo(yaw, 1e-9),
        reason:
            'the pose was built to aim at +30°, so DevicePose.yaw must read '
            '+30° and not −30°',
      );

      // And the same pose, through the OpenCV conversion, must put the camera
      // at the same heading. `M = diag(−1,−1,1)` takes the pano frame back to
      // ours (§2), so this is the same direction expressed twice.
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(
        pose.deviceToWorld,
      );
      // R·(0,0,1) is the third column of the row-major 3×3.
      final inPano = Vector3(r[2], r[5], r[8]);
      final inWorld = Vector3(-inPano.x, -inPano.y, inPano.z);
      expect(SphericalConventions.yawOf(inWorld), closeTo(yaw, 1e-9));
    });

    test('vector_math Quaternion.rotated is the inverse of asRotationMatrix', () {
      // Pinned so that a `vector_math` upgrade which quietly fixes (or further
      // breaks) this shows up here rather than as a mirrored panorama. If this
      // test starts failing, `QuaternionUtils.rotate` and its callers are what
      // need re-checking.
      final q = Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2);
      // Right-hand rule about +Y by +90° carries +Z to +X.
      final correct = q.asRotationMatrix().transformed(Vector3(0, 0, 1));
      expect(correct.x, closeTo(1, 1e-12));
      expect(QuaternionUtils.rotate(q, Vector3(0, 0, 1)).x, closeTo(1, 1e-12));
      expect(
        q.rotated(Vector3(0, 0, 1)).x,
        closeTo(-1, 1e-12),
        reason: 'this is the trap; use QuaternionUtils.rotate instead',
      );
    });
  });

  group('CaptureTarget.direction uses the same convention', () {
    test('agrees with SphericalConventions.directionOf', () {
      const target = CaptureTarget(
        index: 3,
        ringIndex: 1,
        indexInRing: 3,
        yaw: 0.9,
        pitch: -0.4,
        ringLabel: 'lower row',
      );
      final expected = SphericalConventions.directionOf(0.9, -0.4);
      expect(target.direction.x, closeTo(expected.x, 1e-15));
      expect(target.direction.y, closeTo(expected.y, 1e-15));
      expect(target.direction.z, closeTo(expected.z, 1e-15));
    });
  });
}
