import 'json_codec.dart';

/// Every compromise the capture and stitch can report, as a closed set.
///
/// Phase 12 §2 asks for a plain-language sentence per warning and §5 asks for a
/// test proving a new warning cannot ship without one. A free-form string cannot
/// support either: nothing downstream can enumerate the set, so nothing can prove
/// the set is covered, and the sentence a site manager reads ends up being
/// whatever the engineer who found the condition happened to type at the site
/// that found it.
///
/// So the pipeline reports a **code** plus the numbers behind it, and
/// [StitchWarningMessages] turns that into the sentence. The sentence is written
/// once, in one file, where it can be reviewed as copy; the `switch` that produces
/// it has no `default`, so adding a value here without a message does not compile.
///
/// The names are the wire format. They match `svWarningCodeName` in
/// `src/sphere_stitch/sv_warnings.h` character for character, and
/// `test/warning_messages_test.dart` reads that header and fails if the two ever
/// disagree — which is what stops a native-side rename from silently degrading
/// into [unrecognised] on a device.
enum StitchWarningCode {
  // ── stage 5, exposure fusion (native) ─────────────────────────────────────
  /// Frames oversampled the output canvas, so they were decoded smaller.
  framesDownscaled('frames_downscaled'),

  /// One bracket could not be fused; its 0 EV exposure was used alone.
  bracketRefused('bracket_refused'),

  /// One bracket fused with a compromise — a dropped exposure, a substituted
  /// exposure ratio, a ghost-suppressed region.
  bracketCompromised('bracket_compromised'),

  /// Several brackets fell back to a single exposure.
  bracketsRejected('brackets_rejected'),

  /// The exposure ratios the camera reported disagree with its own pixels.
  exposureMetadataDisagrees('exposure_metadata_disagrees'),

  // ── stages 6-9, registration (native) ─────────────────────────────────────
  /// No lens distortion model was available, so undistortion was skipped.
  noDistortionModel('no_distortion_model'),

  /// An iOS distortion lookup table could not be fitted to a radial model.
  distortionLutUnfittable('distortion_lut_unfittable'),

  /// The device published no lens model, so one was solved from the photographs.
  distortionEstimated('distortion_estimated'),

  /// Intrinsics are on the weakest rung of R2's gradient.
  weakIntrinsics('weak_intrinsics'),

  /// Some frames had too few matched inliers and kept their IMU prior.
  imuOnlyFrames('imu_only_frames'),

  /// Most of the capture is positioned from the IMU alone.
  mostlyImuOnly('mostly_imu_only'),

  /// Nothing registered photometrically at all.
  nothingRegistered('nothing_registered'),

  /// The match graph split into disconnected components.
  matchGraphSplit('match_graph_split'),

  /// Bundle adjustment did not converge for one component.
  bundleAdjustmentPartialFailure('bundle_adjustment_partial_failure'),

  /// Bundle adjustment converged for no part of the capture.
  bundleAdjustmentFailed('bundle_adjustment_failed'),

  /// The headline S1 is dominated by the frames that never registered.
  imuOnlyDominatesResidual('imu_only_dominates_residual'),

  /// A large share of pairwise inliers turned out globally inconsistent.
  inconsistentInliersDiscarded('inconsistent_inliers_discarded'),

  /// The solver's refined focal was rejected as the rotation/focal degeneracy.
  focalRefinementRejected('focal_refinement_rejected'),

  /// The solved cameras spanned far less sphere than the capture swept, so the
  /// solution was discarded for the IMU priors.
  solutionCollapsed('solution_collapsed'),

  // ── stages 10-15, compositing (native) ────────────────────────────────────
  /// A frame warped entirely off the canvas.
  frameWarpedOffCanvas('frame_warped_off_canvas'),

  /// No frame reached a wrap pad, so the meridian was composited as a border.
  wrapPadUnreached('wrap_pad_unreached'),

  /// Exposure compensation threw; the panorama is blended without it.
  gainCompensationFailed('gain_compensation_failed'),

  /// Compensation had to move frames further than an AE lock should allow.
  gainRatioTooLarge('gain_ratio_too_large'),

  /// Graph-cut seam finding threw; the blender feathered the whole overlap.
  seamFindingFailed('seam_finding_failed'),

  /// Strip blending did not match a full-canvas blend.
  stripBlendMismatch('strip_blend_mismatch'),

  /// Nothing was covered, so the poles had no colour to extrapolate from.
  nothingCovered('nothing_covered'),

  /// The panorama was written but its preview was not.
  previewNotWritten('preview_not_written'),

  /// A debug map could not be written.
  debugMapNotWritten('debug_map_not_written'),

  /// The capture plan cannot be registered; refused before stage 5.
  planCannotRegister('plan_cannot_register'),

  /// The run stopped after registration, so the photometric criteria are
  /// placeholders rather than measurements.
  registrationOnlyRun('registration_only_run'),

  // ── measured against a criterion (Dart, from the report's own fields) ─────
  /// S1 missed its 1.0 px target.
  reprojectionAboveTarget('reprojection_above_target'),

  /// S2 missed its 0.25° target.
  loopClosureAboveTarget('loop_closure_above_target'),

  /// S4 missed its 1.03 target — softer than [gainRatioTooLarge], which is the
  /// threshold above which the AE lock itself is the suspect.
  gainRatioAboveTarget('gain_ratio_above_target'),

  /// Math §7's residual tilt acceptance was missed.
  residualTiltAboveTarget('residual_tilt_above_target'),

  /// S5: less than the whole sphere is real photography.
  coverageIncomplete('coverage_incomplete'),

  /// Positions the pipeline could not use at all.
  positionsDropped('positions_dropped'),

  // ── the device and the session (Dart) ─────────────────────────────────────
  /// The pre-flight memory check chose a smaller output than the device's RAM
  /// suggests, because the app's own headroom was short.
  tierDowngradedBeforeStart('tier_downgraded_before_start'),

  /// The stitch ran out of memory and was retried one tier lower.
  tierDowngradedAfterOom('tier_downgraded_after_oom'),

  /// The platform would not say how much memory it has.
  memoryProbeUnavailable('memory_probe_unavailable'),

  /// The panorama was written but its 360° metadata was not.
  metadataNotWritten('metadata_not_written'),

  /// The heading came from the magnetometer, which is unreliable indoors.
  headingFromMagnetometer('heading_from_magnetometer'),

  /// The stitch paused because the device was too hot, then resumed.
  thermalPause('thermal_pause'),

  /// The session was bracketing-capable in principle but ran locked, so the
  /// panorama holds one exposure's worth of dynamic range.
  bracketingUnavailable('bracketing_unavailable'),

  /// Fewer photos were taken than the plan called for.
  positionsNotCaptured('positions_not_captured'),

  // ── the escape hatch ──────────────────────────────────────────────────────
  /// A code this build does not know, from a native library newer than it.
  ///
  /// Deliberately last, and deliberately not silent: it carries the native
  /// `detail` through so the user still learns something, and
  /// `warning_messages_test.dart` asserts no shipping native code can produce
  /// it. It exists so that a version mismatch degrades to a worse message rather
  /// than to a crash or — much worse — to a dropped warning, which architecture
  /// §8 forbids.
  unrecognised('unrecognised');

  const StitchWarningCode(this.wireName);

  /// The name used in JSON, shared with `sv_warnings.h`.
  final String wireName;

  /// The code called [wireName], or [unrecognised].
  static StitchWarningCode fromWireName(String wireName) {
    for (final code in values) {
      if (code.wireName == wireName) return code;
    }
    return unrecognised;
  }
}

/// One reported compromise: what it was, the numbers behind it, and the
/// technical detail the detecting stage wrote.
class StitchWarning {
  /// Creates a warning.
  const StitchWarning(
    this.code, {
    this.data = const {},
    this.detail = '',
  });

  /// What went wrong.
  final StitchWarningCode code;

  /// The numbers behind it, keyed as `sv_warnings.h` and the message table
  /// agree. Never shown raw to a user; interpolated into the sentence.
  final Map<String, Object?> data;

  /// The technical sentence the stage that noticed wrote, in English, aimed at
  /// whoever debugs this later.
  ///
  /// Kept alongside the user-facing sentence rather than replaced by it. The two
  /// have different jobs: [message] tells a site manager what to do differently,
  /// and this tells an engineer reading a bug report which of fifteen stages to
  /// look at. Throwing it away to avoid duplication would cost the only
  /// description of the failure written by the code that saw it.
  final String detail;

  /// The plain-language sentence. See [StitchWarningMessages].
  String get message => StitchWarningMessages.of(this);

  /// An `int` from [data], or [fallback].
  int intValue(String key, [int fallback = 0]) {
    final value = data[key];
    return value is num ? value.round() : fallback;
  }

  /// A `double` from [data], or [fallback].
  double doubleValue(String key, [double fallback = 0]) {
    final value = data[key];
    return value is num ? value.toDouble() : fallback;
  }

  /// A `String` from [data], or `''`.
  String stringValue(String key) {
    final value = data[key];
    return value is String ? value : '';
  }

  /// Serialises to the shape `report.cpp` writes.
  Map<String, Object?> toJson() => {
    'code': code.wireName,
    if (detail.isNotEmpty) 'detail': detail,
    if (data.isNotEmpty) 'data': data,
  };

  /// Reads one entry of a report's `warnings` array.
  ///
  /// Accepts a bare string as well as an object, because that is what every
  /// report written before Phase 12 contains — and those reports are inside
  /// committed bundles and baselines that have to keep loading. A legacy string
  /// becomes [StitchWarningCode.unrecognised] carrying its own sentence as
  /// [detail], which is exactly what it is: a warning whose cause was never
  /// recorded in a machine-readable form.
  factory StitchWarning.fromJson(Object? entry) {
    if (entry is String) {
      return StitchWarning(StitchWarningCode.unrecognised, detail: entry);
    }
    if (entry is! Map) {
      throw SphereJsonFormatException(
        'StitchReport.warnings[]',
        'expected an object or a string, got ${entry.runtimeType}',
      );
    }
    final map = entry.cast<String, Object?>();
    final data = map['data'];
    return StitchWarning(
      StitchWarningCode.fromWireName(jsonString(map, 'code', context: 'StitchWarning')),
      detail: map['detail'] is String ? map['detail'] as String : '',
      data: data is Map ? data.cast<String, Object?>() : const {},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StitchWarning &&
      other.code == code &&
      other.detail == detail &&
      _mapEquals(other.data, data);

  @override
  int get hashCode => Object.hash(code, detail, data.length);

  @override
  String toString() => 'StitchWarning(${code.wireName}: $message)';

  static bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || b[key] != a[key]) return false;
    }
    return true;
  }
}

/// The failure-UX table of Phase 12 §2: one plain-language sentence per code.
///
/// Two rules govern every sentence here, and they are the difference between a
/// feature a site team trusts and one they work around:
///
/// 1. **Name the cause and what to do differently.** "Stitching may be
///    imperfect" teaches nothing and reads as a shrug — the user cannot tell
///    whether to re-shoot, stand further back, or ignore it. Every sentence
///    below names *what* happened, *how much*, and where there is an action,
///    what it is. Where there is genuinely nothing the user can do, the sentence
///    says who can (this is a camera problem, this is one for the developers)
///    rather than implying the user failed.
/// 2. **Never hide a compromise.** A manager who later discovers that a panorama
///    was silently degraded stops trusting all of them, which costs far more
///    than the one bad panorama. So a smaller output, a frame positioned from
///    the IMU, a bracket that fell back to one exposure — each of them says so,
///    in the report and in the UI.
///
/// A third rule is about the writing rather than the policy: these are read on a
/// tablet, outdoors, by someone holding it in one hand. Short sentences, no
/// jargon that is not load-bearing, and the number first where there is one.
abstract final class StitchWarningMessages {
  /// The sentence for [warning].
  ///
  /// A `switch` **expression** over the enum with no `default`, which is what
  /// makes the coverage a compile-time property: adding a code to
  /// [StitchWarningCode] without a case here fails `dart analyze` with a
  /// non-exhaustive-switch error, before any test runs.
  static String of(StitchWarning warning) => switch (warning.code) {
    // ── stage 5 ────────────────────────────────────────────────────────────
    StitchWarningCode.framesDownscaled =>
      'The photos were used at '
          '${warning.intValue('decoded_width')} pixels wide rather than full '
          'size. At this panorama size that is all the detail the result can '
          'hold, so nothing visible was lost and the stitch was faster. No '
          'action needed.',
    StitchWarningCode.bracketRefused =>
      'At photo ${warning.intValue('position') + 1} the three exposures did not '
          'line up with each other, so only the middle one was used. Bright '
          'windows and dark corners there may lose detail. The tablet moved '
          'between the three shots — holding still for a moment longer after '
          'the shutter fires prevents it.',
    StitchWarningCode.bracketCompromised =>
      'Photo ${warning.intValue('position') + 1} was combined from its '
          'exposures with a compromise: ${_lowerFirst(warning.stringValue('reason'))}. '
          'That area holds slightly less bright-to-dark range than the rest. '
          'Pausing half a second longer before moving on keeps all three '
          'exposures usable.',
    StitchWarningCode.bracketsRejected =>
      '${warning.intValue('rejected')} of '
          '${warning.intValue('positions')} photos used a single exposure '
          'instead of three, because the three did not line up. Those parts of '
          'the panorama hold less detail in bright windows and dark corners. '
          'Pausing a moment longer at each position fixes it.',
    StitchWarningCode.exposureMetadataDisagrees =>
      'The camera reported exposures it did not actually take — up to '
          '${warning.doubleValue('stops').toStringAsFixed(1)} stops out. The '
          'brightness was measured from the photos themselves instead, so the '
          'panorama is correct, but this tablet\'s bracketing is not doing what '
          'it claims. Worth reporting with the model name.',

    // ── registration ───────────────────────────────────────────────────────
    StitchWarningCode.noDistortionModel =>
      'This tablet does not publish its lens distortion, so straight edges near '
          'the edge of each photo bend slightly and the joins are a little less '
          'exact. Normal for single-camera tablets and nothing to do about it on '
          'this device.',
    StitchWarningCode.distortionLutUnfittable =>
      'This tablet published lens data the stitcher could not use, so it '
          'stitched without a distortion correction. Joins may be slightly less '
          'exact near the edges of each photo. Worth reporting with the model '
          'name — this is one for the developers, not for the site.',
    StitchWarningCode.distortionEstimated =>
      'This tablet publishes no lens calibration, so the lens was measured from '
          'the photographs themselves — the same point seen by several photos at '
          'different distances from the centre is enough to solve for it. The '
          'joins are more exact than they would be without it. No action '
          'needed.',
    StitchWarningCode.weakIntrinsics =>
      'This tablet does not report a measured lens calibration, so the field of '
          'view had to be derived from its physical specification. The panorama '
          'is correct but its geometric accuracy is limited by that estimate '
          'rather than by the stitching. Nothing to do differently on this '
          'device.',
    StitchWarningCode.imuOnlyFrames =>
      '${warning.intValue('frames')} of ${warning.intValue('total')} photos had '
          'too little detail to align precisely — bare drywall, a poured slab, a '
          'plain ceiling. They are still in the panorama, positioned from the '
          'tablet\'s motion sensors, so those areas may be slightly offset. '
          'Including a corner, a fitting or a marked line in the frame gives the '
          'stitcher something to lock onto.',
    StitchWarningCode.mostlyImuOnly =>
      '${(warning.doubleValue('fraction') * 100).round()}% of this panorama is '
          'positioned from the tablet\'s motion sensors rather than from the '
          'photos, because the surfaces had almost no detail to match. Expect '
          'visible misalignment. This is a scene the method cannot do better on: '
          'shoot from a spot that includes some structure — a doorway, '
          'scaffolding, a service run — rather than facing blank walls.',
    StitchWarningCode.nothingRegistered =>
      'None of these photos could be matched to each other, so the panorama is '
          'assembled from the tablet\'s motion sensors alone and will be visibly '
          'misaligned. Almost always a scene with no detail at all, or a capture '
          'taken while walking. Re-shoot standing still, pivoting on the spot, '
          'with some structure in view.',
    StitchWarningCode.matchGraphSplit =>
      'The photos formed ${warning.intValue('components')} separate groups that '
          'could not be matched to each other. Each group is internally accurate '
          'but the alignment between groups relies on the motion sensors, so '
          'there may be a step where two groups meet. A gap in the coverage is '
          'the usual cause — completing every prompted position prevents it.',
    StitchWarningCode.bundleAdjustmentPartialFailure =>
      'A group of ${warning.intValue('frames')} photos could not be solved '
          'precisely and kept its sensor-based position, so that part of the '
          'panorama may be slightly offset. Usually low detail or too little '
          'overlap in that direction — re-shooting that part of the ring, '
          'pausing at each prompt rather than sweeping past it, fixes it.',
    StitchWarningCode.bundleAdjustmentFailed =>
      'The precise alignment step failed everywhere, so every photo is placed '
          'from the tablet\'s motion sensors. Expect misalignment of degrees '
          'rather than pixels: treat this panorama as a record of what was '
          'there, not as something to measure off. Re-shoot pivoting on the spot '
          'with more overlap.',
    StitchWarningCode.imuOnlyDominatesResidual =>
      'The photos that could be matched line up to '
          '${warning.doubleValue('rms_registered_px').toStringAsFixed(1)} '
          'pixels, but ${warning.intValue('imu_only_frames')} could not be '
          'matched at all and pull the overall figure to '
          '${warning.doubleValue('rms_all_px').toStringAsFixed(1)} pixels. The '
          'panorama is accurate where it registered and approximate where it did '
          'not, so check the unmatched directions before reading a measurement '
          'off it. Including a corner or a fitting in frame is what lets those '
          'directions register next time.',
    StitchWarningCode.inconsistentInliersDiscarded =>
      '${(warning.doubleValue('fraction') * 100).round()}% of the matches '
          'between photos disagreed with the overall solution and were '
          'discarded. This is the signature of repeated structure — rows of '
          'identical studs, ceiling tiles, formwork — where the stitcher can '
          'match the wrong copy. Check the joins in those areas rather than '
          'trusting the accuracy figure; re-shooting with something distinctive '
          'in frame is what breaks the ambiguity.',
    StitchWarningCode.focalRefinementRejected =>
      'The stitcher tried to revise this lens\'s field of view by more than '
          '${((warning.doubleValue('max_ratio') - 1) * 100).round()}% and was '
          'overruled — that is not a correction, it is the solver trading focal '
          'length against camera angle, two things it cannot tell apart on its '
          'own. Your tablet\'s own figure was used instead, so the panorama is '
          'built at the right scale. Nothing to do differently: this is the '
          'stitcher catching itself.',
    StitchWarningCode.solutionCollapsed =>
      'The precise alignment step placed all the photos within '
          '${warning.doubleValue('solved_spread_degrees').round()}° of each '
          'other when the tablet actually swept '
          '${warning.doubleValue('measured_spread_degrees').round()}°, so it had '
          'made them agree by moving them somewhere they were never taken. That '
          'was thrown away and the tablet\'s motion sensors were used instead: '
          'the panorama covers the right directions but joins less precisely. '
          'Too little overlap or too little detail is the usual cause — '
          're-shoot pausing at each prompt.',

    // ── compositing ────────────────────────────────────────────────────────
    StitchWarningCode.frameWarpedOffCanvas =>
      'One photo ended up outside the panorama entirely and contributed '
          'nothing. That should not be possible and is one for the developers — '
          'please report it with this panorama.',
    StitchWarningCode.wrapPadUnreached =>
      'No photo crossed the back of the panorama, so it does not close into a '
          'full circle. Expected if the capture was stopped early; otherwise '
          'complete the ring of prompted positions.',
    StitchWarningCode.gainCompensationFailed =>
      'The brightness could not be evened out between photos, so wide surfaces '
          'like a sky or a long wall may show banding. The panorama is otherwise '
          'complete. One for the developers — please report it.',
    StitchWarningCode.gainRatioTooLarge =>
      'The photos differ in brightness by up to '
          '${warning.doubleValue('max_gain_ratio').toStringAsFixed(2)}x — more '
          'than lens shading explains, so the camera\'s exposure lock did not '
          'hold during the capture. The panorama has been evened out and should '
          'look right, but the underlying photos disagree. This is a camera '
          'fault on this tablet rather than a capture mistake: worth reporting '
          'with the model name.',
    StitchWarningCode.seamFindingFailed =>
      'The stitcher could not choose where to cut between overlapping photos, '
          'so it blended across the whole overlap instead. Anything close to the '
          'camera may appear doubled or ghosted. One for the developers — please '
          'report it with this panorama.',
    StitchWarningCode.stripBlendMismatch =>
      'The panorama was blended in strips to fit in memory, and the strips did '
          'not join exactly — up to '
          '${warning.intValue('levels')} levels of difference. Faint vertical '
          'bands may be visible. One for the developers: the strip padding is '
          'too small for the band count.',
    StitchWarningCode.nothingCovered =>
      'No usable photos reached the panorama, so it is blank. Nothing was '
          'recoverable from this capture — it needs re-shooting.',
    StitchWarningCode.previewNotWritten =>
      'The panorama was saved but its small preview could not be, so lists and '
          'thumbnails will load the full image instead. The panorama itself is '
          'unaffected.',
    StitchWarningCode.debugMapNotWritten =>
      'A diagnostic file could not be written. No action needed — the panorama '
          'is unaffected; it only makes a later investigation of this station '
          'harder.',
    // Named `planCannotRegister` for wire compatibility with bundles already in
    // the replay corpus, but it no longer means the stitch was refused — it is
    // a grade on the capture geometry, and the panorama is always produced.
    // Which half is weak decides the sentence, because the two have completely
    // different remedies: thin overlap wants more positions, a hole wants the
    // operator to aim somewhere they did not.
    StitchWarningCode.planCannotRegister => switch ((
      warning.doubleValue('minimum_pairwise_overlap') < 0.25,
      warning.doubleValue('fraction_covered_once') < 0.995,
    )) {
      (true, true) =>
        'These photos overlap by only '
            '${(warning.doubleValue('minimum_pairwise_overlap') * 100).round()}% '
            '(the stitcher wants 25% or more) and cover '
            '${(warning.doubleValue('fraction_covered_once') * 100).toStringAsFixed(1)}% '
            'of the sphere. The panorama was still built — unmatched photos are '
            'placed using the tablet\'s motion sensors and the gap is filled in '
            'from its surroundings — but expect visible misalignment and a soft '
            'patch. Re-shooting and visiting every prompted position fixes both.',
      (true, false) =>
        'These photos overlap by only '
            '${(warning.doubleValue('minimum_pairwise_overlap') * 100).round()}%, '
            'and the stitcher wants 25% or more to find matching detail between '
            'them. The panorama was still built: photos that could be matched '
            'were, and the rest are placed using the tablet\'s motion sensors. '
            'Expect some visible misalignment at the joins.',
      _ =>
        '${(warning.doubleValue('fraction_covered_once') * 100).toStringAsFixed(1)}% '
            'of the sphere was photographed. The rest — usually straight down, '
            'underneath you — is filled in from the pixels around it, so the '
            'panorama is complete, but that part is invented rather than '
            'photographed.',
    },
    StitchWarningCode.registrationOnlyRun =>
      'This was a diagnostic run that stopped after the alignment step, so the '
          'brightness and coverage figures are placeholders rather than '
          'measurements. Not a panorama to keep: re-stitching this capture '
          'normally produces a real one.',

    // ── criteria measured against the report's own fields ──────────────────
    StitchWarningCode.reprojectionAboveTarget =>
      'The photos line up to about '
          '${warning.doubleValue('rms_px').toStringAsFixed(1)} pixels rather '
          'than the 1 pixel this is built for. Edges may not meet exactly where '
          'something was close to the camera. Standing further from the nearest '
          'wall, or pivoting on the lens instead of swinging the tablet round '
          'your body, is what closes this gap.',
    StitchWarningCode.loopClosureAboveTarget =>
      'Going all the way round, the panorama came back '
          '${warning.doubleValue('degrees').toStringAsFixed(2)}° away from where '
          'it started, so the join at the back may be visible. Nothing to do '
          'differently: this is the lens field-of-view figure being slightly off '
          'on this device rather than anything the operator did. Worth reporting '
          'with the model name if it is large or getting worse.',
    StitchWarningCode.gainRatioAboveTarget =>
      'Brightness varies by up to '
          '${((warning.doubleValue('max_gain_ratio') - 1) * 100).round()}% '
          'between photos, which can show as banding across a sky or a large '
          'wall. Usually a light being switched during the capture, so leaving '
          'the lighting alone for the ninety seconds a station takes is what '
          'prevents it.',
    StitchWarningCode.residualTiltAboveTarget =>
      'The horizon in this panorama is off level by '
          '${warning.doubleValue('degrees').toStringAsFixed(1)}°. It will look '
          'tilted when panned. Holding the tablet upright rather than leaning it '
          'while turning keeps it level.',
    StitchWarningCode.coverageIncomplete =>
      'This panorama covers '
          '${(warning.doubleValue('fraction') * 100).round()}% of the sphere; '
          'the rest is filled in from the surrounding image rather than '
          'photographed. Those areas are an approximation and should not be read '
          'for detail. Completing every prompted position covers the whole '
          'sphere.',
    StitchWarningCode.positionsDropped =>
      warning.intValue('count') == 1
          ? '1 photo was too blurry or too poorly overlapped to use, so the '
                'panorama has a soft patch where it should have been. Re-shooting '
                'that position replaces it.'
          : '${warning.intValue('count')} photos were too blurry or too poorly '
                'overlapped to use, so the panorama has soft patches where they '
                'should have been. Re-shooting those positions replaces them.',

    // ── the device and the session ─────────────────────────────────────────
    StitchWarningCode.tierDowngradedBeforeStart =>
      'This panorama was made at '
          '${warning.intValue('width')}x${warning.intValue('height')} instead of '
          '${warning.intValue('requested_width')}x'
          '${warning.intValue('requested_height')}, because only '
          '${warning.intValue('available_mb')} MB of memory was free to this app '
          'when it started. Closing other apps before stitching gives a sharper '
          'result on this tablet.',
    StitchWarningCode.tierDowngradedAfterOom =>
      'This panorama was reduced to '
          '${warning.intValue('width')}x${warning.intValue('height')} — the '
          'tablet ran out of memory at '
          '${warning.intValue('requested_width')}x'
          '${warning.intValue('requested_height')} and the stitch was retried '
          'one size down. It is complete and correct, just less detailed. '
          'Closing other apps first avoids the retry.',
    StitchWarningCode.memoryProbeUnavailable =>
      'This tablet would not report how much memory it has, so the panorama was '
          'made at the smallest size rather than risking running out of memory '
          'partway through. Worth reporting with the model name.',
    StitchWarningCode.metadataNotWritten =>
      'The panorama was saved but its 360° tag could not be written, so other '
          'apps will open it as a wide flat photo instead of a sphere. The image '
          'itself is complete. Re-saving from this app fixes the tag.',
    StitchWarningCode.headingFromMagnetometer =>
      'North in this panorama comes from the tablet\'s compass, which steel and '
          'rebar bend by tens of degrees indoors — so the direction it opens '
          'facing may be well out. The panorama itself is unaffected. Capturing '
          'from a marked point on the plan gives a reliable heading.',
    StitchWarningCode.thermalPause =>
      'Paused — the tablet is too hot to keep stitching. It will carry on by '
          'itself once it cools, and nothing is lost. Out of direct sun and off '
          'charge is the fastest way back.',
    StitchWarningCode.bracketingUnavailable =>
      'This tablet\'s camera cannot take a bracket of three exposures, so each '
          'photo is a single one. Bright windows will be white and deep shadows '
          'will be dark, and no amount of stitching recovers that. The geometry '
          'is unaffected. A device with a full camera stack is the only fix.',
    StitchWarningCode.positionsNotCaptured =>
      '${warning.intValue('missing')} of ${warning.intValue('planned')} photos '
          'were not taken. The panorama is made from what is here and the gaps '
          'are filled in rather than invented — those areas are an '
          'approximation. Resuming the station and finishing the prompts '
          'replaces them with real photographs.',

    // ── escape hatch ───────────────────────────────────────────────────────
    // Carries the native detail rather than a generic sentence: a warning with
    // no message is a hidden compromise, which is the one thing architecture §8
    // rules out. It should be unreachable — `warning_messages_test.dart` proves
    // no shipping code emits it — so if a user ever sees this, the version of
    // the native library does not match the version of the app.
    StitchWarningCode.unrecognised =>
      warning.detail.isNotEmpty
          ? warning.detail
          : 'Something was recorded about this panorama that this version of '
                'the app cannot describe. The panorama is unaffected. Please '
                'report it — the app and its stitching library are out of step.',
  };

  /// Lowercases the first character, for interpolating a sentence fragment
  /// written by the native side into the middle of one written here.
  static String _lowerFirst(String text) => text.isEmpty
      ? text
      : text[0].toLowerCase() + text.substring(1);
}
