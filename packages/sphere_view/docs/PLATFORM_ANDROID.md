# Android plugin requirements

Camera2 and `SensorManager`, plus the CMake that builds
[`src/sphere_stitch`](../src/sphere_stitch) for the NDK. Scaffolding lands in
**Phase 06**; the `flutter: plugin:` block in `pubspec.yaml` is added at the
same time, since declaring it before the platform code exists breaks `pub get`
for consumers.

Camera2, not CameraX — R3 found CameraX 1.5 still has no bracketing, and
`ExtensionMode.HDR` returns a single pre-fused frame with no per-frame control,
which is the one thing the pipeline needs.

Non-negotiables for this side, from `phases/01_MATH_AND_CONVENTIONS.md` §4.1:

- Anchor every coordinate — crop region, principal point, distortion — to
  `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`.
- Always request `DISTORTION_CORRECTION_MODE_OFF`.
- Derive intrinsics from physics as the **primary** path; treat
  `LENS_INTRINSIC_CALIBRATION` as an optional override when non-null. It is
  reported null even on Pixel hardware.
- Reorder `LENS_DISTORTION` to OpenCV order `{κ1, κ2, κ4, κ5, κ3}` — a pure
  reorder, no value transform (R2, verified against AOSP).
- Use `TYPE_GAME_ROTATION_VECTOR`, never `TYPE_ROTATION_VECTOR`: the
  magnetometer is unusable indoors around rebar and steel studs.
- Frame timestamps must share a clock base with the sensor stream. Phase 07
  owns proving it.
