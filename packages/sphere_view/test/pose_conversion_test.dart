import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/quaternion_utils.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'pose_fixtures.dart';

/// Pins the Phase 07 §2 platform→world conversion.
///
/// The phase doc is unusually direct about this one: it walks through a
/// derivation, notices the result has determinant −1 — a reflection, which
/// would mirror the panorama — and then says not to trust the derivation at
/// all, because "the sign conventions in both platform docs are ambiguous
/// enough that reasoning alone is unreliable".
///
/// So the tests below are split along exactly that line.
///
/// * **What algebra can settle** is settled here: that the matrix is a proper
///   rotation, that it carries the platform's vertical onto our up, that the
///   quaternion and the matrix say the same thing, and — the important one —
///   that a device turning *right* produces a *decreasing* yaw when driven
///   with attitudes built forwards from the documented platform conventions.
/// * **What only hardware can settle** is the conventions themselves. That
///   lives in `example/integration_test/pose_device_test.dart`.
///
/// The reflection is tested for explicitly rather than merely avoided, so that
/// anyone who later "fixes" the conversion back to the phase doc's own
/// derivation fails a test that tells them why.
void main() {
  const degrees = math.pi / 180;
  const frames = PoseReferenceFrame.values;

  Vector3 applyRowMajor(List<double> m, Vector3 v) => Vector3(
    m[0] * v.x + m[1] * v.y + m[2] * v.z,
    m[3] * v.x + m[4] * v.y + m[5] * v.z,
    m[6] * v.x + m[7] * v.y + m[8] * v.z,
  );

  double determinant(List<double> m) =>
      m[0] * (m[4] * m[8] - m[5] * m[7]) -
      m[1] * (m[3] * m[8] - m[5] * m[6]) +
      m[2] * (m[3] * m[7] - m[4] * m[6]);

  group('the conversion matrix A', () {
    test('is a proper rotation — this is the whole hazard', () {
      expect(
        determinant(PoseFrameConversion.referenceToWorldRowMajor),
        closeTo(1.0, 1e-12),
        reason:
            'a determinant of −1 is a reflection, and a reflection mirrors the '
            'panorama while leaving every seam closed and every drift test '
            'passing. It is the one failure in this phase that no numeric check '
            'downstream would notice',
      );
    });

    test("the phase doc's own derivation is the reflection it warns about", () {
      // §2 derives `Y_ours = Z_a`, `Z_ours = Y_a`, `X_ours = X_a`, then notices
      // the determinant. Reproduced here so that restoring it fails loudly
      // rather than quietly mirroring every panorama the package produces.
      const derived = <double>[1, 0, 0, 0, 0, 1, 0, 1, 0];
      expect(determinant(derived), closeTo(-1.0, 1e-12));
    });

    test('carries the platform vertical onto world up', () {
      // The one physical constraint. Both platforms' reference frames are
      // Z-vertical; Math §1.1 defines +Y_w as up.
      final up = applyRowMajor(
        PoseFrameConversion.referenceToWorldRowMajor,
        Vector3(0, 0, 1),
      );
      expect(up.x, closeTo(0, 1e-12));
      expect(up.y, closeTo(1, 1e-12));
      expect(up.z, closeTo(0, 1e-12));
    });

    test('the quaternion form reproduces the matrix entry for entry', () {
      // Two statements of A — an axis-angle quaternion and a literal matrix —
      // and they must not drift apart. The quaternion is built from an axis
      // rather than converted from the matrix because a 180° rotation has
      // trace −1, the degenerate branch of every matrix→quaternion routine.
      final m = PoseFrameConversion.referenceToWorldRotation.asRotationMatrix();
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          expect(
            m.entry(i, j),
            closeTo(PoseFrameConversion.referenceToWorldRowMajor[i * 3 + j], 1e-12),
            reason: 'entry ($i,$j)',
          );
        }
      }
    });
  });

  group('the device frame needs no conversion (§2)', () {
    for (final frame in frames) {
      test('${frame.name}: a level device at bearing 0 lands on yaw 0', () {
        final world = PoseFrameConversion.deviceToWorldUnoffset(
          frame,
          platformAttitude(0),
        );
        // Math §1.2 says both platforms' device frames already match ours, so
        // the only conversion is world→world. If that were false — if a device
        // axis needed flipping too — this is where it would show, because the
        // result would not be the aiming pose the shot plan builds for the
        // same direction.
        final expected = SphericalConventions.aimingOrientation(0, 0);
        for (final v in [
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
          Vector3(0, 0, 1),
        ]) {
          final a = QuaternionUtils.rotate(world, v);
          final b = QuaternionUtils.rotate(expected, v);
          expect(a.x, closeTo(b.x, 1e-12));
          expect(a.y, closeTo(b.y, 1e-12));
          expect(a.z, closeTo(b.z, 1e-12));
        }
      });
    }
  });

  group('THE sign test — turning right must decrease yaw', () {
    // The §5 acceptance criterion, run against attitudes constructed forwards
    // from the documented platform conventions rather than read off the
    // implementation. `platformAttitudeMatrix` builds the rotation a Z-up
    // platform would report for a device physically aimed at a compass
    // bearing; turning right is a *larger* bearing, by construction.
    for (final frame in frames) {
      test('${frame.name}: yaw = −bearing across a full turn', () {
        for (var bearingDeg = -170.0; bearingDeg <= 180.0; bearingDeg += 10) {
          final bearing = bearingDeg * degrees;
          final world = PoseFrameConversion.deviceToWorldUnoffset(
            frame,
            platformAttitude(bearing),
          );
          final yaw = SphericalConventions.yawOf(
            QuaternionUtils.rotate(world, Vector3(0, 0, -1)),
          );
          expect(
            yaw,
            closeTo(-bearing, 1e-9),
            reason:
                'at bearing ${bearingDeg.toStringAsFixed(0)}°, yaw should be '
                '${(-bearingDeg).toStringAsFixed(0)}°. Math §3: turning right '
                'decreases yaw, which is what keeps content moving right in the '
                'image instead of mirroring it',
          );
        }
      });

      test('${frame.name}: a 30° turn to the right lowers yaw by 30°', () {
        double yawAt(double bearingDeg) => SphericalConventions.yawOf(
          QuaternionUtils.rotate(
            PoseFrameConversion.deviceToWorldUnoffset(
              frame,
              platformAttitude(bearingDeg * degrees),
            ),
            Vector3(0, 0, -1),
          ),
        );
        expect(yawAt(30) - yawAt(0), closeTo(-30 * degrees, 1e-9));
        expect(yawAt(0) - yawAt(-30), closeTo(-30 * degrees, 1e-9));
      });
    }

    test('the reflection would flip that sign — which is why it is fatal', () {
      // Same input, the phase doc's determinant −1 matrix instead of ours.
      // Yaw comes out as +bearing: every panorama mirrored, and nothing else
      // in the pipeline any the wiser.
      const reflection = <double>[1, 0, 0, 0, 0, 1, 0, 1, 0];
      final attitude = platformAttitudeMatrix(40 * degrees);
      // forward_ref = R·(0,0,−1), then into world through the reflection.
      final forwardRef = Vector3(
        -attitude.entry(0, 2),
        -attitude.entry(1, 2),
        -attitude.entry(2, 2),
      );
      final mirrored = applyRowMajor(reflection, forwardRef);
      expect(
        SphericalConventions.yawOf(mirrored),
        closeTo(40 * degrees, 1e-9),
        reason:
            'the reflection makes turning right *increase* yaw. Both matrices '
            'send the platform vertical to world up, so no gravity check can '
            'tell them apart — only the sign of a turn can',
      );
    });
  });

  group('pitch survives the conversion', () {
    for (final frame in frames) {
      test('${frame.name}: aiming above the horizon reads as positive pitch', () {
        for (final pitchDeg in [-80.0, -46.0, 0.0, 46.0, 80.0]) {
          final world = PoseFrameConversion.deviceToWorldUnoffset(
            frame,
            platformAttitude(25 * degrees, pitch: pitchDeg * degrees),
          );
          final forward = QuaternionUtils.rotate(world, Vector3(0, 0, -1));
          expect(
            SphericalConventions.pitchOf(forward),
            closeTo(pitchDeg * degrees, 1e-9),
            reason: 'pitch at $pitchDeg°',
          );
          expect(
            SphericalConventions.yawOf(forward),
            closeTo(-25 * degrees, 1e-9),
            reason: 'yaw should not depend on pitch, at $pitchDeg°',
          );
        }
      });
    }
  });

  group('measured up rotates to world up', () {
    // The detectable half of the reflection hazard, and the check
    // `PlatformAhrsPoseSource` runs on every sample. It catches an upside-down
    // conversion or a platform gravity sign that is not what the plugin
    // boundary assumed — but, as the test above shows, never a mirror.
    for (final frame in frames) {
      test('${frame.name}: across bearings and tilts', () {
        for (var bearingDeg = -180.0; bearingDeg < 180; bearingDeg += 45) {
          for (final pitchDeg in [-70.0, -20.0, 0.0, 20.0, 70.0]) {
            final world = PoseFrameConversion.deviceToWorldUnoffset(
              frame,
              platformAttitude(bearingDeg * degrees, pitch: pitchDeg * degrees),
            );
            final up = QuaternionUtils.rotate(world, 
              platformUpDevice(bearingDeg * degrees, pitch: pitchDeg * degrees),
            );
            expect(up.y, closeTo(1.0, 1e-9), reason: '$bearingDeg°/$pitchDeg°');
          }
        }
      });
    }
  });

  group('the session-start yaw offset (Math §1.1)', () {
    test('puts the first sample at yaw 0, whatever it was aimed at', () {
      for (var bearingDeg = -180.0; bearingDeg < 180; bearingDeg += 17) {
        final first = PoseFrameConversion.deviceToWorldUnoffset(
          PoseReferenceFrame.androidGameRotationVector,
          platformAttitude(bearingDeg * degrees),
        );
        final offset = PoseFrameConversion.yawOffsetFor(first);
        final zeroed = PoseFrameConversion.applyYawOffset(offset, first);
        expect(
          SphericalConventions.yawOf(QuaternionUtils.rotate(zeroed, Vector3(0, 0, -1))),
          closeTo(0, 1e-9),
          reason: 'starting at bearing $bearingDeg°',
        );
      }
    });

    test('is a rotation about world up, so it cannot disturb the gravity lock', () {
      final first = PoseFrameConversion.deviceToWorldUnoffset(
        PoseReferenceFrame.androidGameRotationVector,
        platformAttitude(53 * degrees, pitch: 31 * degrees),
      );
      final offset = PoseFrameConversion.yawOffsetFor(first);
      final up = QuaternionUtils.rotate(offset, Vector3(0, 1, 0));
      expect(up.x, closeTo(0, 1e-12));
      expect(up.y, closeTo(1, 1e-12));
      expect(up.z, closeTo(0, 1e-12));

      // Pitch is therefore untouched by the datum, which is what makes it safe
      // to latch the datum from whatever the user happened to be aiming at.
      final zeroed = PoseFrameConversion.applyYawOffset(offset, first);
      expect(
        SphericalConventions.pitchOf(QuaternionUtils.rotate(zeroed, Vector3(0, 0, -1))),
        closeTo(31 * degrees, 1e-9),
      );
    });

    test('preserves relative turns exactly', () {
      const startDeg = 118.0;
      final first = PoseFrameConversion.deviceToWorldUnoffset(
        PoseReferenceFrame.androidGameRotationVector,
        platformAttitude(startDeg * degrees),
      );
      final offset = PoseFrameConversion.yawOffsetFor(first);
      for (final turnDeg in [-90.0, -33.0, 0.0, 33.0, 90.0]) {
        final later = PoseFrameConversion.applyYawOffset(
          offset,
          PoseFrameConversion.deviceToWorldUnoffset(
            PoseReferenceFrame.androidGameRotationVector,
            platformAttitude((startDeg + turnDeg) * degrees),
          ),
        );
        expect(
          SphericalConventions.yawOf(QuaternionUtils.rotate(later, Vector3(0, 0, -1))),
          closeTo(-turnDeg * degrees, 1e-9),
          reason: 'turning right by $turnDeg° from the datum',
        );
      }
    });

    test('a session that begins pointed at the zenith still gets a datum', () {
      // Not hypothetical: the plan contains two zenith shots, and nothing stops
      // a user from starting there. At the pole the optical axis is ±Y_w and
      // its yaw is atan2(0, 0) — so the heading comes from the screen-up
      // direction instead, offset by π, the same limit the shot plan takes.
      for (final poleDeg in [90.0, -90.0]) {
        final first = PoseFrameConversion.deviceToWorldUnoffset(
          PoseReferenceFrame.androidGameRotationVector,
          platformAttitude(64 * degrees, pitch: poleDeg * degrees),
        );
        final offset = PoseFrameConversion.yawOffsetFor(first);
        expect(offset.x.isFinite && offset.w.isFinite, isTrue);

        // Then bring the tablet down to the horizon at the same bearing: the
        // heading it was started on must now read as yaw 0.
        final horizon = PoseFrameConversion.applyYawOffset(
          offset,
          PoseFrameConversion.deviceToWorldUnoffset(
            PoseReferenceFrame.androidGameRotationVector,
            platformAttitude(64 * degrees),
          ),
        );
        expect(
          SphericalConventions.yawOf(QuaternionUtils.rotate(horizon, Vector3(0, 0, -1))),
          closeTo(0, 1e-6),
          reason:
              'starting at the ${poleDeg > 0 ? 'zenith' : 'nadir'} should still '
              'pin yaw 0 to the bearing the tablet was facing',
        );
      }
    });
  });

  group('the whole conversion composes with Math §2', () {
    test('a level frame at the datum produces the OpenCV rotation §2 predicts', () {
      // End to end: platform attitude → world → OpenCV camera→pano. Math §2
      // says a level camera looking along the session-start heading has
      // R_opencv = M·R_wd·N, and this is where the two phases meet. If the
      // Phase 07 conversion were mirrored, the OpenCV rotation would come out
      // with determinant −1 and OpenCV's warper would silently flip the frame.
      final world = PoseFrameConversion.deviceToWorldUnoffset(
        PoseReferenceFrame.androidGameRotationVector,
        platformAttitude(0),
      );
      final r = SphericalConventions.openCvRotationFromDeviceToWorld(world);
      expect(determinant(r), closeTo(1.0, 1e-12));

      // OpenCV camera forward (0,0,1)_c must land on the pano frame's +Z,
      // which is the session-start heading (Math §2's own verification step).
      final forward = applyRowMajor(r, Vector3(0, 0, 1));
      expect(forward.x, closeTo(0, 1e-9));
      expect(forward.y, closeTo(0, 1e-9));
      expect(forward.z, closeTo(1, 1e-9));

      // OpenCV camera up (0,−1,0)_c must land on pano-frame up, which is
      // −Y_p in that Y-down frame.
      final up = applyRowMajor(r, Vector3(0, -1, 0));
      expect(up.x, closeTo(0, 1e-9));
      expect(up.y, closeTo(-1, 1e-9));
      expect(up.z, closeTo(0, 1e-9));
    });
  });

  /// The capture frame is not the device frame, and the number that reconciles
  /// them was wrong by 180° for every Android phone that reports
  /// `SENSOR_ORIENTATION = 90` — which is most of them.
  ///
  /// Nothing caught it. The C++ test asserts the correction *is* a roll about the
  /// optical axis and that it is applied on the right, both of which are equally
  /// true of the correct turn and of its 180° opposite. The synthetic harness
  /// never set `captureQuarterTurns` at all, so it rendered and scored at zero
  /// turns and the whole path was exercised only on device.
  ///
  /// So this group tests the one thing that distinguishes 1 from 3: that the same
  /// physical pixel, projected through the capture intrinsics and rolled, and
  /// projected through the device intrinsics unrolled, names the **same direction
  /// in the panorama**. That is the only property the stitcher actually needs, and
  /// it is false for the other turn.
  group('the device→capture quarter turn', () {
    // A landscape 4:3 capture frame with a deliberately off-centre principal
    // point and unequal focal lengths: a symmetric camera would pass a mirrored
    // or transposed convention just as happily.
    final capture = CameraIntrinsics(
      fx: 3210,
      fy: 3250,
      cx: 2000,
      cy: 1480,
      imageSize: const ImageSize(4032, 3024),
      source: IntrinsicsSource.platformCalibration,
    );

    /// The OpenCV camera-frame ray for a pixel: `((x−cx)/fx, (y−cy)/fy, 1)`,
    /// Math §4's pinhole with `Y` down and `Z` forward.
    Vector3 openCvRay(CameraIntrinsics k, double x, double y) =>
        Vector3((x - k.cx) / k.fx, (y - k.cy) / k.fy, 1);

    /// Where a capture pixel lands in the device frame:
    /// `rotatedQuarterTurn(clockwise: true)` sends `(x, y)` to `(H − y, x)`.
    ({double x, double y}) toDevicePixel(double x, double y) => (
      x: capture.imageSize.height - y,
      y: x,
    );

    Vector3 normalised(Vector3 v) => v.normalized();

    for (final sensorOrientation in [0, 90, 180, 270]) {
      test(
        'at a $sensorOrientation° mounting it is the inverse of the intrinsics turn',
        () {
          final forward = SphericalConventions.captureToDeviceQuarterTurns(
            landscapeCapture: true,
            sensorOrientationDegrees: sensorOrientation,
          );
          final back = SphericalConventions.deviceToCaptureQuarterTurns(
            landscapeCapture: true,
            sensorOrientationDegrees: sensorOrientation,
          );
          expect(
            (forward + back) % 4,
            0,
            reason:
                'the two turns have to compose to the identity; returning the '
                'forward turn for both is the 180° bug that shipped',
          );
        },
      );
    }

    test('a portrait capture frame needs no turn either way', () {
      expect(
        SphericalConventions.captureToDeviceQuarterTurns(
          landscapeCapture: false,
          sensorOrientationDegrees: 90,
        ),
        0,
      );
      expect(
        SphericalConventions.deviceToCaptureQuarterTurns(
          landscapeCapture: false,
          sensorOrientationDegrees: 90,
        ),
        0,
      );
    });

    test('is 3, not 1, for the ordinary Android phone', () {
      expect(
        SphericalConventions.deviceToCaptureQuarterTurns(
          landscapeCapture: true,
          sensorOrientationDegrees: 90,
        ),
        3,
        reason:
            'derived in the doc comment: C = Rz(θ)·N·D with X_c = Y_d and '
            'Y_c = −X_d forces sin θ = −1, so θ = −90° ≡ 3 quarter turns',
      );
    });

    test(
      'rolls a capture-frame ray onto the direction the device frame names',
      () {
        // A level camera, so the pano rotation is the constant M·N and anything
        // wrong with the roll cannot hide behind the pose.
        final pose = SphericalConventions.aimingOrientation(0, 0);
        final unrolled = SphericalConventions.openCvRotationFromDeviceToWorld(pose);
        final device = capture.rotatedQuarterTurn(clockwise: true);
        final turns = SphericalConventions.deviceToCaptureQuarterTurns(
          landscapeCapture: true,
          sensorOrientationDegrees: 90,
        );
        final roll = SphericalConventions.captureRollRowMajor(turns);

        // Not just the centre: the centre is fixed by every candidate turn. These
        // are spread over the frame, including two corners, so a 90° error and a
        // 180° error both show up.
        const pixels = [
          (0.0, 0.0),
          (4031.0, 0.0),
          (0.0, 3023.0),
          (4031.0, 3023.0),
          (1000.0, 800.0),
          (3500.0, 2500.0),
        ];

        for (final (x, y) in pixels) {
          // Through the capture frame: project with the capture intrinsics, then
          // apply the roll on the right exactly as sv_geometry.cpp does.
          final rolled = applyRowMajor(
            unrolled,
            applyRowMajor(roll, openCvRay(capture, x, y)),
          );

          // Through the device frame: the same physical pixel, projected with the
          // rotated intrinsics and no roll at all.
          final mapped = toDevicePixel(x, y);
          final direct = applyRowMajor(
            unrolled,
            openCvRay(device, mapped.x, mapped.y),
          );

          final a = normalised(rolled);
          final b = normalised(direct);
          expect(
            a.dot(b),
            closeTo(1.0, 1e-9),
            reason:
                'capture pixel ($x, $y) points somewhere different depending on '
                'which frame it is projected through — the two frames disagree '
                'by ${(math.acos(a.dot(b).clamp(-1.0, 1.0)) / degrees).toStringAsFixed(1)}°',
          );
        }
      },
    );

    test('and the turn that shipped gets it wrong by 180°', () {
      final pose = SphericalConventions.aimingOrientation(0, 0);
      final unrolled = SphericalConventions.openCvRotationFromDeviceToWorld(pose);
      final device = capture.rotatedQuarterTurn(clockwise: true);

      // The old value: the forward turn, used where its inverse was needed.
      final wrong = SphericalConventions.captureRollRowMajor(1);
      final rolled = applyRowMajor(
        unrolled,
        applyRowMajor(wrong, openCvRay(capture, 1000, 800)),
      );
      final mapped = toDevicePixel(1000, 800);
      final direct = applyRowMajor(
        unrolled,
        openCvRay(device, mapped.x, mapped.y),
      );

      final separation =
          math.acos(
            normalised(rolled).dot(normalised(direct)).clamp(-1.0, 1.0),
          ) /
          degrees;
      // Not a subtle miss. This is the whole upside-down panorama, in degrees.
      expect(
        separation,
        greaterThan(20),
        reason:
            'if this passes with a small separation then the pixel map, the '
            'roll or the derivation has changed and the sign needs re-deriving',
      );
    });
  });
}
