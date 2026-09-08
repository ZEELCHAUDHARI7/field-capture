import 'dart:math' as math;

import 'package:sphere_view/src/api/models/sphere_capture_config.dart';

import 'camera_model.dart';
import 'scene.dart';

/// One synthetic capture set: a scene, a plan, and a specific way for reality
/// to be unhelpful.
///
/// Nine of these exist, from the table in §1 of the phase doc, and they are
/// ordered by how much they are allowed to hurt. `pristine` is the control — if
/// it fails, the geometry or the conventions are wrong and no other number
/// means anything. `nominal` is the device we expect. The rest each isolate one
/// way a site walk goes wrong, so that when a metric moves there is exactly one
/// candidate explanation rather than seven.
class SynthProfile {
  /// Creates a profile. Every field has a `nominal`-shaped default so a profile
  /// declaration below reads as *only its own deviations*.
  const SynthProfile({
    required this.name,
    required this.purpose,
    this.sceneStyle = SceneStyle.constructionInterior,
    this.nearestSurfaceMetres = 3.0,
    this.dynamicRangeScale = 1.0,
    this.overlapFraction = defaultOverlap,
    this.captureNadir = true,
    this.sensorOrientationDegrees = 0,
    this.enforceCoverage = true,
    this.exposure = const ExposureStrategy.bracket3(evSpread: 2.0),
    this.meteredEvBias = 0.0,
    this.poseErrorRmsDegrees = 2.0,
    this.poseDriftDegreesPerMinute = 0.0,
    this.focalErrorFraction = 0.03,
    this.distortion = const Distorter(-0.085, 0.021, 0.0004, -0.0003, -0.004),
    this.vignetting = 1.0,
    this.gainRmsStops = 0.06,
    this.readNoiseElectrons = 4.0,
    this.fullWellElectrons = 9000.0,
    this.angularSpeedDegreesPerSecond = 1.5,
    this.exposureSeconds = 1 / 60,
    this.rollingShutterSeconds = 0.022,
    this.lensOffsetMetres = 0.0,
    this.completionFraction = 1.0,
  });

  /// The overlap the harness plans at — **the production default, deliberately**.
  ///
  /// This was 0.45, because the rasteriser showed 0.33 tops out near 80% double
  /// coverage against S5's then-stated ≥95%. That criterion turned out to be the
  /// thing that was wrong: the double-covered fraction is exactly `ω/(1−ω)`, so
  /// 95% is algebraically a demand for `ω = 0.487`, against a documented default
  /// of 0.33 — the two could never both hold. S5 is now S5a/b/c (Math §8), and
  /// 0.33 clears it.
  ///
  /// Holding the harness at 0.45 after that would have been worse than a stale
  /// comment: the stitcher would be tuned against 45% overlap and shipped
  /// against 33%, so every registration and seam metric would read better here
  /// than in the field, and the gap would surface only on a real site. The
  /// harness plans what the device plans.
  static const double defaultOverlap = 0.33;

  /// Directory and fixture name.
  final String name;

  /// One line on what this profile is for, printed by `--list`.
  final String purpose;

  /// Which room to build.
  final SceneStyle sceneStyle;

  /// Distance to the nearest surface, which with [lensOffsetMetres] sets how
  /// much parallax the frames actually contain.
  final double nearestSurfaceMetres;

  /// Multiplier on the scene's radiance range; `0` makes the room uniformly
  /// exposable, which is what lets `pristine` be a genuine control.
  final double dynamicRangeScale;

  /// Target overlap `ω` fed to the plan builder.
  final double overlapFraction;

  /// Whether the plan includes the nadir. The rig has no feet, so unlike a real
  /// session it normally does.
  final bool captureNadir;

  /// Whether the plan must pass S5. Off only for `sparse_plan`.
  final bool enforceCoverage;

  /// How the sensor is mounted relative to the portrait-locked screen, in
  /// degrees — 0 means square, 90 and 270 mean a quarter turn either way.
  ///
  /// **This is the harness's largest blind spot, closed.** A real Android phone
  /// almost always reports 90: it delivers landscape pixels behind a portrait
  /// screen, so the frame on disk and the pose that goes with it are a quarter
  /// turn apart, and `captureQuarterTurns` is what reconciles them —
  /// right-multiplied into every IMU seed by `sv_geometry.cpp`, where bundle
  /// adjustment's gauge freedom cannot absorb an error.
  ///
  /// The rig used to render and record in one frame throughout, so every bundle
  /// it wrote carried `captureQuarterTurns = 0` and that entire path was
  /// exercised **only on device**. It shipped inverted — 180° out on every phone
  /// reporting 90 — and nothing here could have caught it.
  ///
  /// Non-zero makes the rig behave like such a sensor: the pixels are turned into
  /// the capture frame before they are written, the intrinsics are turned with
  /// them, and the poses stay in the device frame, exactly as a device records
  /// them. A stitcher that mishandles the turn then fails S1 and S2 loudly here
  /// instead of quietly in somebody's office.
  final int sensorOrientationDegrees;

  /// Exposures per position.
  final ExposureStrategy exposure;

  /// What the metering pre-sweep chose, in stops, applied to **every** exposure
  /// of the bracket on top of its own bias.
  ///
  /// This models pipeline stage 3 — "2 s pre-sweep of the sphere, pick one EV,
  /// then hard-lock it" (architecture §4) — and without it the rig quietly makes
  /// that choice by construction: an exposure of `0` means the display-referred
  /// ground truth exposes to full scale, i.e. metered for the interior. That is a
  /// real choice with real consequences, and for a room with a bright window it is
  /// the *worst* one. Measured on `hdr_interior` before this field existed: the sky
  /// sits 7 stops over the interior, so it clipped in all three exposures — 18.5%
  /// of the window frames blown at 0 EV and 18.4% still blown at −3 EV — and no
  /// fusion algorithm could have recovered it. The bracket has to be centred on
  /// the scene's range, not on one end of it, and choosing where is metering's job
  /// rather than fusion's.
  final double meteredEvBias;

  /// RMS magnitude of the IMU error written into `bundle.json`, in degrees.
  final double poseErrorRmsDegrees;

  /// Gyro bias drift, in degrees per minute of capture, accumulated across the
  /// session in shooting order — the error that a per-frame random rotation
  /// cannot stand in for, because bundle adjustment sees it as a consistent
  /// story rather than as noise.
  final double poseDriftDegreesPerMinute;

  /// Fraction the recorded focal is wrong by. The panorama fails to close by
  /// roughly `360° · this`, so 0.03 is ~11° of loop error for BA to remove.
  final double focalErrorFraction;

  /// The lens the frames are rendered through. The bundle records **no**
  /// distortion model, matching the fleet reality R2 found, so the stitcher has
  /// to cope or measure it.
  final Distorter distortion;

  /// Vignetting strength: the falloff is `cos^(4·this)(θ)`, so `1.0` is
  /// textbook `cos⁴` and `0.0` is a perfect lens.
  final double vignetting;

  /// RMS per-frame exposure wobble in stops, simulating an AE lock that is not
  /// quite a lock. This is what S4 has to compensate away.
  final double gainRmsStops;

  /// Read noise floor, in electrons.
  final double readNoiseElectrons;

  /// Full-well capacity, in electrons; sets the shot-noise scale. A small well
  /// is a noisy sensor.
  final double fullWellElectrons;

  /// Angular speed at the shutter, driving both motion blur and the
  /// rolling-shutter skew.
  final double angularSpeedDegreesPerSecond;

  /// Shutter time, over which the motion blur smears.
  final double exposureSeconds;

  /// Sensor readout time top-to-bottom, over which the rolling shutter skews.
  final double rollingShutterSeconds;

  /// Entrance-pupil offset from the pivot, in metres. The physical limit
  /// architecture §3 says nothing can remove.
  final double lensOffsetMetres;

  /// Fraction of the plan actually shot, for the abandoned-session profile.
  final double completionFraction;

  /// [angularSpeedDegreesPerSecond] in radians.
  double get angularSpeedRadPerSec =>
      angularSpeedDegreesPerSecond * math.pi / 180;

  /// Whether this profile needs the depth equirect written alongside the image.
  bool get needsDepth => lensOffsetMetres != 0;

  /// The nine profiles, in the order the phase doc tabulates them.
  static const List<SynthProfile> all = [
    SynthProfile(
      name: 'pristine',
      purpose:
          'zero noise, exact poses, exact intrinsics — output must be '
          'near-pixel-perfect, and if it is not, nothing else matters',
      // Every source of error is off, including the ones that are normally
      // facts of optics rather than faults. That is the point: this profile
      // asks one question — do the renderer and the stitcher agree about the
      // mapping — and any second source of error would blur the answer.
      dynamicRangeScale: 0,
      exposure: ExposureStrategy.locked(),
      poseErrorRmsDegrees: 0,
      focalErrorFraction: 0,
      distortion: Distorter.identity,
      vignetting: 0,
      gainRmsStops: 0,
      readNoiseElectrons: 0,
      fullWellElectrons: double.infinity,
      angularSpeedDegreesPerSecond: 0,
      rollingShutterSeconds: 0,
    ),
    SynthProfile(
      name: 'nominal',
      purpose:
          'a realistic tablet: 2° IMU error, 3% focal error, mild distortion '
          'and vignetting, small exposure drift, no parallax',
    ),
    // ── two ablations of `nominal`, for attributing its RMS reprojection ──────
    //
    // `nominal` fails S1 by nearly nine pixels while `pristine` passes it by a
    // factor of six, and the gap has four candidate causes at once: pose error,
    // focal error, distortion the bundle does not declare, and sensor noise.
    // These two turn off one candidate each, so the difference between them and
    // `nominal` *is* that candidate's contribution — which is what makes it a
    // measurement rather than an argument.
    //
    // The distortion one matters most. The rig renders through a real
    // Brown–Conrady lens and then writes a bundle with **no distortion model**,
    // because R2 found that is what the fleet actually reports. So the stitcher is
    // handed frames whose straight lines are bent by a lens it is not told about,
    // and no amount of bundle adjustment recovers a parameter that is not in the
    // model. If that is most of the nine pixels, the fix is to estimate the
    // distortion rather than to keep tuning the solver.
    SynthProfile(
      name: 'nominal_no_distortion',
      purpose:
          'nominal with a perfect lens — the S1 difference against nominal is '
          'exactly what undeclared distortion costs',
      distortion: Distorter.identity,
    ),
    // ── the sensor mounting, which used to be exercised only on device ───────
    //
    // `pristine` with a quarter turn, both ways. Everything else about them is
    // perfect, so anything they show is the capture-frame roll and nothing else.
    //
    // **They are fixtures, not a gate yet.** The rig half is done and verified —
    // the bundles they write carry landscape JPEGs, landscape intrinsics, device
    // -frame poses and `captureQuarterTurns` of 3 and 1 respectively, which is
    // exactly what an Android phone records and what the harness had never once
    // produced. What is not done is the *scoring*: ground truth is device→world
    // and the solved rotations describe the capture frame, so both currently
    // score ~300 px against a solve that is very likely correct. Undoing the roll
    // on the reported rotations was tried, in both directions, and does not close
    // it — see `NativeStitcher._rotationsFrom`. Until that is finished, run them
    // to look at the panorama, not at the number.
    SynthProfile(
      name: 'sensor_landscape',
      purpose:
          'pristine from a sensor mounted 90 deg off the screen — the ordinary '
          'Android phone, and the case captureQuarterTurns exists for',
      sensorOrientationDegrees: 90,
      dynamicRangeScale: 0,
      exposure: ExposureStrategy.auto(),
      poseErrorRmsDegrees: 0,
      focalErrorFraction: 0,
      distortion: Distorter.identity,
      vignetting: 0,
      gainRmsStops: 0,
      readNoiseElectrons: 0,
      fullWellElectrons: double.infinity,
      angularSpeedDegreesPerSecond: 0,
      rollingShutterSeconds: 0,
    ),
    SynthProfile(
      name: 'sensor_270',
      purpose:
          'pristine from a sensor mounted the other way — proves the turn is '
          'derived from the mounting rather than assumed',
      sensorOrientationDegrees: 270,
      dynamicRangeScale: 0,
      exposure: ExposureStrategy.auto(),
      poseErrorRmsDegrees: 0,
      focalErrorFraction: 0,
      distortion: Distorter.identity,
      vignetting: 0,
      gainRmsStops: 0,
      readNoiseElectrons: 0,
      fullWellElectrons: double.infinity,
      angularSpeedDegreesPerSecond: 0,
      rollingShutterSeconds: 0,
    ),
    SynthProfile(
      name: 'nominal_auto_exposure',
      purpose:
          'nominal shot the way the product actually ships — one automatically '
          'metered exposure per position, not a three-shot bracket',
      exposure: ExposureStrategy.auto(),
    ),
    SynthProfile(
      name: 'nominal_no_vignetting',
      purpose:
          'nominal with a lens that does not fall off — the S4 difference '
          'against nominal is exactly what uncorrected vignetting costs',
      vignetting: 0,
    ),
    SynthProfile(
      name: 'nominal_exact_focal',
      purpose:
          'nominal with the true focal in the bundle — the S1 difference '
          'against nominal is exactly what the 3% focal seed error costs',
      focalErrorFraction: 0,
    ),
    SynthProfile(
      name: 'harsh_imu',
      purpose:
          '6° IMU error with 1.5°/min of bias drift — proves bundle '
          'adjustment recovers from a bad prior rather than following it',
      poseErrorRmsDegrees: 6.0,
      poseDriftDegreesPerMinute: 1.5,
    ),
    SynthProfile(
      name: 'low_texture',
      purpose:
          'bare drywall and a raw slab — proves graceful degradation, not '
          'just success on a scene that was always going to work',
      sceneStyle: SceneStyle.bareDrywall,
    ),
    SynthProfile(
      name: 'hdr_interior',
      purpose:
          'a dark interior with blown windows, 12 EV corner to sky, metered 3 '
          'stops down — validates the whole Phase 05 bracket path',
      sceneStyle: SceneStyle.hdrInterior,
      exposure: ExposureStrategy.bracket3(evSpread: 3.0),
      // 12 EV rather than the scene's full 14, and metered 3 stops below the
      // interior. Both numbers come from arithmetic rather than taste, and the
      // arithmetic is the whole reason this profile can test anything.
      //
      // A phone JPEG holds ~10 EV between clipping and its read-noise floor
      // (here: a 4500 e- well against 6 e- of read noise, i.e. 9.6 EV). Three
      // shots 3 stops apart therefore reach 9.6 + 6 = 15.6 EV — but only if the
      // bracket is centred on the scene. At the scene's full 14 EV that leaves
      // 1.6 EV of centring slack, which is a knife edge no metering pre-sweep
      // could be expected to hit; at 12 EV it leaves 3.6 EV, and −3 sits in the
      // middle of the window it has to land in ([−3.4, −2.6] for this scene).
      // The result is a fixture where **both** ends are genuinely at stake: the
      // 0 EV frame clips the sky and crushes the dark end, the −3 EV frame holds
      // the sky, the +3 EV frame holds the dark end, and a stitcher that ignores
      // the bracket loses both. 12 EV is still squarely inside the 12–16 EV band
      // Phase 05 §1 describes.
      dynamicRangeScale: 0.85,
      meteredEvBias: -3.0,
      fullWellElectrons: 4500.0,
      readNoiseElectrons: 6.0,
    ),
    SynthProfile(
      name: 'parallax_1m',
      purpose:
          'nearest surface at 1 m with a 10 cm lens offset — expected to be '
          'imperfect; the job is to pin down how imperfect',
      nearestSurfaceMetres: 1.0,
      lensOffsetMetres: 0.10,
    ),
    SynthProfile(
      name: 'motion_blur',
      purpose:
          'shot while still moving: 25°/s at a 1/15 s shutter — tests the '
          'sharpness gate, not the stitcher',
      angularSpeedDegreesPerSecond: 25.0,
      exposureSeconds: 1 / 15,
      rollingShutterSeconds: 0.033,
    ),
    SynthProfile(
      name: 'sparse_plan',
      purpose:
          "today's 15%-overlap plan, 21 positions — must fail loudly rather "
          'than silently produce mush',
      overlapFraction: 0.15,
      enforceCoverage: false,
    ),
    SynthProfile(
      name: 'partial',
      purpose:
          'the user quit after 60% of the targets — must emit a valid partial '
          'panorama with an honest coverage number',
      completionFraction: 0.6,
    ),
  ];

  /// The profile called [name].
  static SynthProfile byName(String name) => all.firstWhere(
    (p) => p.name == name,
    orElse: () => throw ArgumentError.value(
      name,
      'profile',
      'unknown; expected one of ${all.map((p) => p.name).join(', ')}',
    ),
  );
}
