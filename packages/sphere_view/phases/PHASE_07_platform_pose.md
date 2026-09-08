# Phase 07 — Platform pose source and shutter-time interpolation

**Goal:** a drift-resistant device→world quaternion, and the ability to say what
the orientation was *at the exact microsecond the shutter fired*.

**Duration:** 3–4 days. **Depends on:** 01, 06.

Small phase, outsized consequences. The pose attached to each frame is the seed
for bundle adjustment and the gravity reference for levelling. If it is wrong by
a few degrees, BA still recovers (Phase 03 proves that with `harsh_imu`). If it is
*mistimed*, nothing recovers, because the error is unbiased noise rather than a
consistent offset.

---

## 1. Replacing the hand-rolled filter

Delete `lib/src/sensors/orientation_tracker.dart`. It integrates the raw
gyroscope and nudges tilt toward the accelerometer — a textbook complementary
filter, correctly implemented, and still the wrong choice:

- it does not estimate or remove **gyro bias**, so yaw drifts;
- it does not correct **gyro scale-factor error**, so a 90° turn reads as 88°;
- it re-derives what both platforms already compute with a properly tuned Kalman
  filter, using calibration data we cannot access from Dart.

Both OS filters are strictly better. Use them.

| Platform | Source | Why |
|---|---|---|
| Android | `Sensor.TYPE_GAME_ROTATION_VECTOR` | gyro + accel fusion, bias-corrected, **no magnetometer** — immune to the rebar/steel problem |
| iOS | `CMMotionManager.deviceMotion` with `.xArbitraryCorrectedZVertical` | gyro + accel, Z locked to vertical, yaw arbitrary but drift-corrected |

Both give exactly what §1.1 of [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md)
specifies: gravity-locked pitch/roll and a yaw that is relative to session start.
Neither uses the compass. That is the correct trade for indoor construction.

**Do not use** `TYPE_ROTATION_VECTOR` (Android) or `.xTrueNorthZVertical` (iOS) —
both pull in the magnetometer, which is the failure mode the current code's own
comments correctly describe.

---

## 2. Frame conversion

### Android

`TYPE_GAME_ROTATION_VECTOR` gives `[x, y, z, w]` in the Android world frame:
X ≈ east, **Y ≈ up... in the *tangential* sense**, Z away from the ground; and the
*device* frame is X right, Y up the screen, **Z out of the screen toward the
user** — so the camera looks along **−Z_d**, which matches our device frame `D`
directly.

The Android world frame is Z-up, ours is Y-up. Conversion (world→world):

```
R_ours = A · R_android ,     A maps Android world → our world
                             (Android X,Y,Z) → (ours ?, ?, ?)
```

Derive `A` by asserting that our `+Y_w` is up: Android's up is `+Z_a`, so
`Y_ours = Z_a`. Pick `Z_ours = Y_a`, `X_ours = X_a`; then
`A = [[1,0,0],[0,0,1],[0,1,0]]`, whose determinant is **−1** — a reflection, not a
rotation. That would mirror the panorama. Use `A = [[-1,0,0],[0,0,1],[0,1,0]]`
(det = +1) and **verify empirically** with the §5 test rather than trusting this
derivation.

Then apply the session-start yaw offset so that yaw = 0 is the initial heading
(§1.1). Store the offset quaternion once, at `start()`.

### iOS

`CMDeviceMotion.attitude.quaternion` is device→reference. The reference frame for
`.xArbitraryCorrectedZVertical` is Z-vertical, so the same class of conversion
applies. Apple's device frame is X right, Y up the screen, Z out of the screen —
again matching `D`.

**Both conversions must be proven by the §5 test, not by derivation.** The sign
conventions in both platform docs are ambiguous enough that reasoning alone is
unreliable, and a mirrored panorama is the failure mode.

---

## 3. `PoseBuffer` — interpolation to shutter time

```dart
class PoseBuffer {
  /// Ring buffer of ~4 s at 100 Hz.
  void add(DevicePose p);

  /// SLERP between the two samples bracketing [timestampUs].
  /// Returns null if the timestamp is outside the buffer.
  DevicePose? at(int timestampUs);
}
```

The camera reports each captured frame's sensor timestamp (Phase 06 §2.5 / §3.5).
The pose stream arrives at ~100 Hz, i.e. every 10 ms. Nearest-sample lookup gives
up to 5 ms of error; at a realistic 60°/s pan that is 0.3°. SLERP between the
bracketing samples reduces it to well under 0.05°. Cheap, so do it.

Interpolate **quaternions with SLERP**, not Euler angles — Euler interpolation is
wrong near the poles, which is exactly where the zenith shot lives.

For a bracket, attach the pose interpolated to the **0 EV shot's** timestamp; that
is the frame Phase 05 uses as the fusion reference, so it is the one whose
geometry the fused frame inherits.

Also record `gravityWorld` at the same instant, for the levelling step
(§7 of the math doc), and `angularSpeedRadPerSec` for the steadiness gate.

---

## 4. Sampling rate

Request the fastest rate the platform will give without excessive battery cost:

- Android: `SENSOR_DELAY_GAME` (~50 Hz) minimum; request 100 Hz via
  `registerListener(..., samplingPeriodUs: 10000)`.
- iOS: `motionManager.deviceMotionUpdateInterval = 1.0 / 100.0`.

100 Hz is enough given SLERP. Higher rates add battery and thermal load for no
measurable accuracy gain — worth confirming once, then leaving alone.

---

## 5. The test that actually matters

**Timestamp alignment test.** Everything else in this phase is mechanical; this is
the one that catches the expensive bug.

Point the device at a high-contrast vertical edge. Pan at a known, roughly
constant angular rate while capturing frames. For each frame, compare:

- the yaw predicted by `PoseBuffer.at(frameTimestampUs)`, and
- the yaw implied by the edge's measured pixel position and the known focal length.

Plot the difference against pan rate. A **timestamp offset shows up as a slope**
proportional to angular velocity; a frame-conversion error shows up as a constant
or sign-flipped offset. Both are unmistakable on the plot and nearly invisible
otherwise.

Acceptance: fitted slope corresponds to **< 3 ms** of residual timestamp offset,
across pan rates from 20°/s to 120°/s.

### Other tests

- rotate the device physically through a measured 90° (against a wall corner);
  reported yaw change within 1°
- hold still for 3 minutes; yaw drift **< 1.5°** total
- hold still; pitch/roll drift **≈ 0** (gravity-locked, so this should be flat)
- `PoseBuffer.at()` for a timestamp between two samples returns a SLERP result,
  verified against a hand-computed value
- `PoseBuffer.at()` outside the buffer returns null and the capture is rejected
  rather than using a stale pose
- mirroring check: point at a scene with an obvious left/right asymmetry, capture
  two frames 30° apart, and confirm the yaw *sign* moves in the direction the math
  doc specifies (turning right decreases yaw)

That last one is the cheap guard against the reflection hazard in §2.

---

## 6. Pitfalls

1. **`SensorEvent.timestamp` base varies by device.** Usually
   `elapsedRealtimeNanos`, but not universally. Cross-check against the camera's
   `SENSOR_INFO_TIMESTAMP_SOURCE` (Phase 06 §2.5) and estimate the offset when
   they disagree.
2. **iOS `CMDeviceMotion` needs ~1–2 s to converge** after `startDeviceMotionUpdates`.
   Discard early samples and do not let the session start until
   `attitude` is stable.
3. **Android requires the gyroscope to exist.** Some cheap tablets ship without
   one, so `TYPE_GAME_ROTATION_VECTOR` is absent. Detect at probe time and refuse
   the feature with a clear message — this pipeline cannot work without a gyro,
   and pretending otherwise wastes the user's time on site.
4. **Quaternion sign ambiguity.** `q` and `−q` are the same rotation; SLERP must
   take the shorter path (negate one input if their dot product is negative), or
   you get a 360° spin between adjacent samples.
5. **Do not reset the buffer between targets.** Continuous history is needed for
   interpolation and for the steadiness gate.

---

## Exit criteria

- [ ] The timestamp-alignment test passes: residual offset < 3 ms
- [ ] The mirroring check passes on both platforms
- [ ] 3-minute yaw drift < 1.5°, pitch/roll drift flat
- [ ] `orientation_tracker.dart` and `sensors_plus` are gone
- [ ] Missing-gyroscope devices are detected and refused with a clear reason
