import '../api/models/capture_bundle.dart';
import '../api/models/sphere_capture_config.dart';

/// The JSON payload handed to `sv_stitch` across the FFI boundary.
///
/// JSON rather than a packed struct because the ABI would otherwise break every
/// time a field is added — bracket count, distortion coefficients, quality
/// tier — and a struct layout mismatch between a Dart build and a native build
/// is a silent memory-corruption bug rather than an error (architecture §6.4).
/// Parsing a few KB of JSON once is irrelevant next to a 40-second stitch.
///
/// [schemaVersion] is the compatibility gate: the native side refuses a version
/// it does not know rather than reading fields into the wrong meaning.
class StitchRequest {
  /// Creates a request.
  const StitchRequest({
    required this.bundle,
    required this.tier,
    required this.outputPath,
    required this.wrapPadPx,
    this.registrationOnly = false,
    this.forceError,
  });

  /// Version of this payload's shape. Must match `sphere_stitch.h`.
  static const int schemaVersion = 1;

  /// Horizontal padding duplicated onto each side of the canvas before
  /// blending, then cropped.
  ///
  /// The equirect's left and right edges are the same meridian, but the blender
  /// treats them as image borders. Without this the output has a visible
  /// vertical seam at yaw ±180° — the single most common bug in hand-rolled 360
  /// stitchers (architecture §7).
  static const int defaultWrapPadPx = 256;

  /// The capture to stitch. Its directory is the root every shot path resolves
  /// against.
  final CaptureBundle bundle;

  /// Output size and strip count.
  final QualityTier tier;

  /// Absolute path to write the equirectangular JPEG to.
  final String outputPath;

  /// Wrap padding in pixels; see [defaultWrapPadPx].
  final int wrapPadPx;

  /// Stop after stage 9 and skip compositing. Diagnostic only — it is seconds
  /// rather than a minute, which is what makes a geometry question cheap to
  /// ask.
  final bool registrationOnly;

  /// Makes the native side throw at the ABI boundary. Tests only; see the
  /// `throwIfRequested` hook in `sphere_stitch.cpp` for why it exists.
  final String? forceError;

  /// Builds the request payload for [bundle].
  factory StitchRequest.from(
    CaptureBundle bundle, {
    required QualityTier tier,
    required String outputPath,
    int wrapPadPx = defaultWrapPadPx,
    bool registrationOnly = false,
    String? forceError,
  }) => StitchRequest(
    bundle: bundle,
    tier: tier,
    outputPath: outputPath,
    wrapPadPx: wrapPadPx,
    registrationOnly: registrationOnly,
    forceError: forceError,
  );

  /// Returns a copy at [tier]. Used by the single OOM retry.
  StitchRequest copyWithTier(QualityTier tier) => StitchRequest(
    bundle: bundle,
    tier: tier,
    outputPath: outputPath,
    wrapPadPx: wrapPadPx,
    registrationOnly: registrationOnly,
    forceError: forceError,
  );

  /// Serialises to the exact shape `sphere_stitch.cpp` parses.
  ///
  /// The bundle goes across **verbatim**. Poses stay as the raw device→world
  /// quaternions they were recorded as, and `sv_geometry.cpp` applies Math §2's
  /// conversion itself, because there must be exactly one implementation of
  /// that conversion and it has to be the one the C++ tests pin by hand. Doing
  /// it here as well would give the project two, which is the failure mode Math
  /// §0 is entirely about.
  ///
  /// Two things are deliberately **not** copied straight from the bundle:
  ///
  /// * `capture_quarter_turns` is lifted to the top level, because that is
  ///   where `registration.cpp` reads it from. It sits inside `bundle` in the
  ///   manifest and outside it in the request, and the synthetic harness cannot
  ///   see the difference because it always records 0 — so on a tablet whose
  ///   camera is mounted a quarter turn off the display, leaving it nested
  ///   would hand bundle adjustment a rolled seed and present as a stitcher
  ///   bug.
  /// * `output_width` is left unset, so the native tier table decides it.
  ///   `tools/replay` overrides it to match a ground truth; the device must
  ///   not, or the tier stops being the memory ceiling it exists to be
  ///   (architecture §6.5).
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'bundle_dir': bundle.directory.absolute.path,
    'output_path': registrationOnly ? '' : outputPath,
    'tier': tier.name,
    'registration_only': registrationOnly,
    'capture_quarter_turns': bundle.captureQuarterTurns,
    if (forceError != null) 'force_error': forceError,
    'compositing_options': {
      'wrap_pad': wrapPadPx,
      // The strip count is the memory ceiling and comes from the tier, but it
      // is sent explicitly so that a report showing 6 strips can be traced to a
      // request that asked for 6 rather than to a native default that happened
      // to agree.
      'strip_count': tier.stripCount,
      // 134 MB for the label map alone at `high`. The harness needs them to
      // measure S3 and S5; a device has nothing to measure them against and no
      // room to hold them.
      'emit_debug_maps': false,
    },
    'bundle': bundle.toJson(),
  };
}
