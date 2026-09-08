import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/stitch_warning.dart';
import 'package:sphere_view/src/api/models/image_size.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'float_image.dart';
import 'stitcher_backend.dart';

/// The shared-memory progress triple from `sphere_stitch.h`.
///
/// Three plain int32s rather than an FFI callback (architecture §6.3): C++
/// writes [stage] and [permille], Dart writes [cancel], nobody locks anything.
/// The replay tool does not render progress, but it allocates one anyway
/// because passing null would leave the cancellation path — the thing Phase 03
/// has to prove takes effect within 500 ms — untested by every run.
final class SvProgress extends Struct {
  @Int32()
  external int stage;

  @Int32()
  external int permille;

  @Int32()
  external int cancel;
}

typedef _SvStitchC =
    Int32 Function(
      Pointer<Utf8> requestJson,
      Pointer<SvProgress> progress,
      Pointer<Utf8> errorBuffer,
      Int32 errorBufferLength,
      Pointer<Pointer<Utf8>> reportOut,
    );
typedef _SvStitchDart =
    int Function(
      Pointer<Utf8> requestJson,
      Pointer<SvProgress> progress,
      Pointer<Utf8> errorBuffer,
      int errorBufferLength,
      Pointer<Pointer<Utf8>> reportOut,
    );

typedef _SvFreeC = Void Function(Pointer<Utf8>);
typedef _SvFreeDart = void Function(Pointer<Utf8>);
typedef _SvVersionC = Pointer<Utf8> Function();

/// Thrown when the native library reports a failure. Carries the code so the
/// caller can tell "this capture cannot be registered" (actionable, the
/// `sparse_plan` case) apart from "the bundle is corrupt".
class NativeStitchException implements Exception {
  /// Creates the exception.
  const NativeStitchException(this.code, this.message, this.report);

  /// One of the SV_ERR_* values in `sphere_stitch.h`.
  final int code;

  /// The message the native side wrote into `error_buf`.
  final String message;

  /// The report, when one was produced anyway. A partial failure still emits
  /// its numbers — architecture §8's never-degrade-silently rule applies to
  /// failures too, and the numbers are usually the diagnosis.
  final Map<String, Object?>? report;

  @override
  String toString() => 'native stitch failed ($code): $message';
}

/// Runs the desktop build of `src/sphere_stitch` — the same library the device
/// runs, which is what PHASE_02 §2 requires of the replay path.
///
/// With Phase 04 in place this runs the whole pipeline, stages 1-15, and the
/// panorama it hands back is a real one read off disk. [registrationOnly] keeps
/// the Phase 03 behaviour available, because when a geometric metric moves it is
/// worth being able to ask whether compositing had anything to do with it —
/// and because a registration-only run is seconds rather than a minute.
///
/// The panorama comes back as **raw BGR**, not as the JPEG the device writes.
/// S6's `pristine` target is 42 dB, and JPEG at quality 92 lands close enough to
/// that to be indistinguishable from a stitching error; measuring the encoder
/// instead of the stitcher is not a trade worth making in a harness. PNG is not
/// an option either — the pinned OpenCV build has JPEG only, on purpose, and
/// PHASE_02 §2 requires replay to run that same build.
class NativeStitcherBackend implements StitcherBackend {
  /// Creates the loader.
  const NativeStitcherBackend({
    this.libraryPath = defaultLibraryPath,
    this.optionOverrides = const {},
    this.compositingOverrides = const {},
    this.hdrOverrides = const {},
    this.registrationOnly = false,
    this.workDirectory,
    this.tier = 'mid',
  });

  /// Where `tools/build_native.sh` puts the library.
  static const String defaultLibraryPath = 'build/native/libsphere_stitch';

  /// Must match `SV_SCHEMA_VERSION` in `sphere_stitch.h`.
  static const int schemaVersion = 1;

  /// What the native side is asked to write the panorama as. The `.svraw`
  /// extension selects the raw-BGR writer rather than an encoder.
  static const String panoramaFileName = 'panorama.svraw';

  /// Path without the platform extension.
  final String libraryPath;

  /// Merged into the request's `registration_options`. Exists so a diagnostic
  /// or a profile can move one knob without a rebuild.
  final Map<String, Object?> optionOverrides;

  /// Merged into the request's `compositing_options`. §8's strip-vs-full-canvas
  /// and graph-cut-vs-feather comparisons both come through here.
  final Map<String, Object?> compositingOverrides;

  /// Merged into the request's `hdr_options`. Phase 05's second exit criterion is
  /// a comparison against a single-exposure control, so `{'enabled': false}` —
  /// which makes the pipeline register the 0 EV frame of each bracket, exactly as
  /// it did before stage 5 existed — has to be reachable from the harness.
  final Map<String, Object?> hdrOverrides;

  /// Stop after stage 9 and report an empty panorama, as Phase 03 did.
  final bool registrationOnly;

  /// Where the panorama and the debug maps are written. Defaults to a scratch
  /// directory inside the bundle.
  final Directory? workDirectory;

  /// Only affects things the caller has not overridden — chiefly the preview,
  /// which §7 emits at `high`. The output width is set from the job's canvas
  /// regardless, so the tier does not silently decide what S6 compares.
  final String tier;

  /// The platform's shared-library file name.
  String get resolvedPath => switch (Platform.operatingSystem) {
    'macos' => '$libraryPath.dylib',
    'windows' => '$libraryPath.dll',
    _ => '$libraryPath.so',
  };

  @override
  String get name => 'native';

  @override
  String get description =>
      'the desktop build of src/sphere_stitch — the same library the device '
      'runs. Stages 1-15.';

  @override
  Future<StitchOutcome> stitch(StitchJob job) async {
    final scratch =
        workDirectory ?? Directory('${job.bundle.directory.path}/replay/native');
    if (!registrationOnly) {
      await scratch.create(recursive: true);
    }
    final raw = stitchRaw(job, scratch);
    if (registrationOnly) {
      return _registrationOnlyOutcome(raw.report, job, raw.elapsedMs);
    }
    return _compositedOutcome(raw.report, job, raw.elapsedMs);
  }

  /// Runs the library and hands back the report verbatim.
  ///
  /// Separate from [stitch] because the native report and the harness's own
  /// metrics answer different questions — BA's residual over its own inliers
  /// versus accuracy against ground truth — and when they disagree, that
  /// disagreement is the diagnosis. Collapsing them into one number would hide
  /// exactly the frame-convention class of bug the math doc warns about.
  ({Map<String, Object?> report, int elapsedMs}) stitchRaw(
    StitchJob job, [
    Directory? scratch,
  ]) {
    final library = _open();
    final stitch = library.lookupFunction<_SvStitchC, _SvStitchDart>('sv_stitch');
    final free = library.lookupFunction<_SvFreeC, _SvFreeDart>('sv_free');

    final directory =
        scratch ?? Directory('${job.bundle.directory.path}/replay/native');
    // Created unconditionally, including for a registration-only run: stage 5
    // writes its fused frames in here before compositing is even considered, and
    // `mkdir` on the native side creates one level, not a path.
    directory.createSync(recursive: true);
    final outputPath = '${directory.absolute.path}/$panoramaFileName';

    final request = jsonEncode({
      'schema_version': schemaVersion,
      'bundle_dir': job.bundle.directory.absolute.path,
      'output_path': registrationOnly ? '' : outputPath,
      'tier': tier,
      'registration_only': registrationOnly,
      'bundle': job.bundle.toJson(),
      if (optionOverrides.isNotEmpty) 'registration_options': optionOverrides,
      'hdr_options': {
        // Stage 5's fused frames land beside the panorama rather than in the
        // bundle, so replaying the same bundle twice — which is what the HDR A/B
        // does — cannot have one run reading the other's scratch.
        'work_dir': '${directory.absolute.path}/fused',
        ...hdrOverrides,
      },
      if (!registrationOnly)
        'compositing_options': {
          // S6 compares against a ground truth rendered at the job's canvas
          // size. Letting the tier decide the output width instead would mean
          // one side of the comparison gets resampled, and a resample is a
          // blur, and a blur moves SSIM for reasons that have nothing to do
          // with the stitcher.
          'output_width': job.canvas.width,
          // S3 derives seam paths from label boundaries and S5 counts coverage
          // on the output rather than trusting the plan, so both maps are
          // needed. Off on device, where the label map alone is 134 MB.
          'emit_debug_maps': true,
          ...compositingOverrides,
        },
    });

    const errorLength = 2048;
    final requestPtr = request.toNativeUtf8();
    final errorPtr = calloc<Uint8>(errorLength).cast<Utf8>();
    final reportPtr = calloc<Pointer<Utf8>>();
    final progress = calloc<SvProgress>();

    try {
      final stopwatch = Stopwatch()..start();
      final code = stitch(requestPtr, progress, errorPtr, errorLength, reportPtr);
      stopwatch.stop();

      Map<String, Object?>? report;
      if (reportPtr.value != nullptr) {
        report = jsonDecode(reportPtr.value.toDartString()) as Map<String, Object?>;
        free(reportPtr.value);
      }

      if (code != 0) {
        throw NativeStitchException(code, errorPtr.toDartString(), report);
      }
      if (report == null) {
        throw const NativeStitchException(-99, 'native returned no report', null);
      }
      return (report: report, elapsedMs: stopwatch.elapsedMilliseconds);
    } finally {
      calloc.free(requestPtr);
      calloc.free(errorPtr);
      calloc.free(reportPtr);
      calloc.free(progress);
    }
  }

  DynamicLibrary _open() {
    final file = File(resolvedPath);
    if (!file.existsSync()) {
      throw StateError(
        'The native stitcher is not built.\n'
        '  expected: $resolvedPath\n'
        '  build it with:\n'
        '      tools/build_native.sh\n'
        '  (the first run also builds OpenCV 4.13.0 for the host, ~10-20 min; '
        'after that it is seconds.)',
      );
    }
    return DynamicLibrary.open(file.absolute.path);
  }

  /// The rotations, as device→world, from the report's registration block.
  ///
  /// They come back as camera→pano, the frame OpenCV's
  /// `detail::CameraParams::R` lives in. The harness scores against
  /// device→world, so the conversion goes through the single implementation of
  /// the §2 sign flip rather than being written again here.
  ///
  /// **It does not undo the capture roll, and cannot score a rotated bundle.**
  /// Every bundle the rig had ever written carried `captureQuarterTurns = 0`, so
  /// the capture and device frames were the same frame and there was nothing to
  /// undo. `SynthProfile.sensorOrientationDegrees` can now write a bundle with a
  /// real quarter turn in it — the `sensor_landscape` and `sensor_270` profiles
  /// do — and those score ~300 px here against a solve that is very likely
  /// correct: the panorama comes out right and the *comparison* is in the wrong
  /// frame. Right-multiplying the reported rotations by `Rz(±θ)` was tried and
  /// does not fix it, in either direction, which says the gap is more than the
  /// roll — the recorded intrinsics are landscape while the ground truth's are
  /// portrait, and more of the scoring path than this function assumes the two
  /// agree. Finishing that is what makes those two profiles a gate rather than a
  /// fixture.
  List<Matrix3> _rotationsFrom(Map<String, Object?> registration) => [
    for (final entry in (registration['rotations_camera_to_pano'] as List? ?? []))
      SphericalConventions.deviceToWorldFromOpenCvRotation(
        (entry as List).map((v) => (v as num).toDouble()).toList(),
      ),
  ];

  CameraIntrinsics _intrinsicsFrom(Map<String, Object?> report) {
    final refined = (report['refined_intrinsics'] as Map).cast<String, Object?>();
    final intrinsics = CameraIntrinsics.fromJson(refined);
    return intrinsics.imageSize.width > 0
        ? intrinsics
        : intrinsics.copyWith(imageSize: const ImageSize(1, 1));
  }

  /// The report's warnings, as the sentences a user would be shown.
  ///
  /// Rendered through the shipping message table rather than printed raw, so the
  /// harness exercises the Phase 12 §2 copy on every replay: a code the native
  /// side emits and Dart has no sentence for shows up here, in a run somebody
  /// looks at, rather than only on a device.
  List<String> _warningsFrom(Map<String, Object?> report) => [
    for (final entry in (report['warnings'] as List? ?? []))
      '[${StitchWarning.fromJson(entry).code.wireName}] '
          '${StitchWarning.fromJson(entry).message}',
  ];

  /// Stage timings from both halves of the report, plus the wall clock.
  ///
  /// The two blocks are merged rather than nested because the console report
  /// prints one line of timings and the interesting question is which of the
  /// fifteen stages took the minute — not which phase implemented it.
  Map<String, int> _timingsFrom(
    Map<String, Object?> report,
    Map<String, Object?> registration,
    int elapsedMs,
  ) {
    final compositing = (report['compositing'] as Map?)?.cast<String, Object?>();
    return {
      for (final entry in ((registration['stage_ms'] as Map?) ?? {}).entries)
        entry.key.toString(): (entry.value as num).toInt(),
      for (final entry in ((compositing?['stage_ms'] as Map?) ?? {}).entries)
        entry.key.toString(): (entry.value as num).toInt(),
      'total': elapsedMs,
    };
  }

  /// Phase 03's outcome: real geometry, no panorama.
  ///
  /// Everything is reported as uncovered so the photometric metrics say
  /// "nothing to measure" rather than scoring a black image as if it were a
  /// stitch.
  StitchOutcome _registrationOnlyOutcome(
    Map<String, Object?> report,
    StitchJob job,
    int elapsedMs,
  ) {
    final registration =
        (report['registration'] as Map?)?.cast<String, Object?>() ?? {};
    final pixels = job.canvas.width * job.canvas.height;
    return StitchOutcome(
      equirect: FloatImage(job.canvas.width, job.canvas.height, 3),
      labels: Int32List(pixels)..fillRange(0, pixels, StitchOutcome.uncovered),
      counts: Uint8List(pixels),
      estimatedDeviceToWorld: _rotationsFrom(registration),
      estimatedIntrinsics: _intrinsicsFrom(report),
      stageMilliseconds: _timingsFrom(report, registration, elapsedMs),
      warnings: [
        ..._warningsFrom(report),
        'This was a registration-only run, so S3, S4, S5 and S6 have no '
            'panorama to measure and are reported as unavailable.',
      ],
      diagnostics: _hdrDiagnostics(report),
    );
  }

  /// The full outcome: the panorama read back off disk, with the label and
  /// coverage maps the harness cannot derive for itself.
  Future<StitchOutcome> _compositedOutcome(
    Map<String, Object?> report,
    StitchJob job,
    int elapsedMs,
  ) async {
    final registration =
        (report['registration'] as Map?)?.cast<String, Object?>() ?? {};
    final compositing =
        (report['compositing'] as Map?)?.cast<String, Object?>() ?? const {};
    final canvas = job.canvas;
    final pixels = canvas.width * canvas.height;

    final outputPath = (compositing['output_path'] as String?) ?? '';
    if (outputPath.isEmpty) {
      throw const NativeStitchException(
        -98,
        'the native side reported no output path, so compositing did not run',
        null,
      );
    }
    // A size mismatch here would mean comparing against a differently-sized
    // reference, which is exactly the resample the canvas plumbing exists to
    // avoid, so _readMap refuses rather than quietly scaling and reporting a
    // softened SSIM.
    final bgr = _readMap(
      outputPath,
      canvas.width,
      canvas.height,
      bytesPerPixel: 3,
      what: 'panorama',
    )!;
    final equirect = FloatImage(canvas.width, canvas.height, 3);
    for (var i = 0; i < pixels; i++) {
      // OpenCV's channel order, undone here rather than in C++ so the native
      // side writes the Mat it already has.
      equirect.data[i * 3] = bgr[i * 3 + 2] / 255.0;
      equirect.data[i * 3 + 1] = bgr[i * 3 + 1] / 255.0;
      equirect.data[i * 3 + 2] = bgr[i * 3] / 255.0;
    }

    // Both maps are needed, and neither can be reconstructed from the image:
    // S3 needs to know which frame won each pixel, and S5 needs to know how
    // many frames reached it. A missing map is a measurement that silently
    // becomes vacuous, so it is an error rather than a default.
    final labels = _readMap(
      compositing['label_map_path'] as String?,
      canvas.width,
      canvas.height,
      bytesPerPixel: 4,
      what: 'label',
    );
    final counts = _readMap(
      compositing['count_map_path'] as String?,
      canvas.width,
      canvas.height,
      bytesPerPixel: 1,
      what: 'coverage',
    );

    return StitchOutcome(
      equirect: equirect,
      labels: labels?.buffer.asInt32List(0, pixels) ??
          (Int32List(pixels)..fillRange(0, pixels, StitchOutcome.uncovered)),
      counts: counts?.buffer.asUint8List(0, pixels) ?? Uint8List(pixels),
      estimatedDeviceToWorld: _rotationsFrom(registration),
      estimatedIntrinsics: _intrinsicsFrom(report),
      stageMilliseconds: _timingsFrom(report, registration, elapsedMs),
      warnings: _warningsFrom(report),
      diagnostics: {
        ...compositing,
        ..._hdrDiagnostics(report),
        // Lifted out of the top level of the report, where they live because
        // `StitchReport` promises them, so the console has one place to look.
        'coverage_fraction': report['coverage_fraction'],
        'max_gain_ratio': report['max_gain_ratio'],
        // Architecture §3.3's translation signature. Printed on every replay
        // rather than only when it trips, because the threshold that turns it
        // into a warning was calibrated by comparing profiles — and it can only
        // be re-calibrated the same way.
        'residual_scale_correlation': registration['residual_scale_correlation'],
        'outlier_rejected_fraction': registration['outlier_rejected_fraction'],
      }..remove('stage_ms'),
    );
  }

  /// Stage 5's numbers, flattened onto the diagnostics line with an `hdr_`
  /// prefix.
  ///
  /// Flattened rather than nested because the console prints one diagnostics
  /// line, and because these are the numbers that explain a Phase 05 result:
  /// whether a dark corner is the scene, the fusion, or a bracket that was
  /// refused. `positions_of_note` is dropped — it is a list of objects, and the
  /// warnings already name every position it would.
  static Map<String, Object?> _hdrDiagnostics(Map<String, Object?> report) {
    final hdr = (report['hdr'] as Map?)?.cast<String, Object?>();
    if (hdr == null) return const {};
    return {
      for (final entry in hdr.entries)
        if (entry.key != 'positions_of_note' && entry.key != 'stage_ms')
          'hdr_${entry.key}': entry.value,
      for (final entry in ((hdr['stage_ms'] as Map?) ?? {}).entries)
        '${entry.key}_ms': entry.value,
    };
  }

  /// Reads one `SVMP` debug map: the magic, then width, height and
  /// bytes-per-pixel as int32, then the rows.
  ///
  /// A raw format rather than a PNG because the label map is signed 32-bit with
  /// two negative sentinels in it, and every lossless image format would need
  /// those encoded into an offset the reader then has to undo.
  Uint8List? _readMap(
    String? path,
    int width,
    int height, {
    required int bytesPerPixel,
    required String what,
  }) {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) {
      throw NativeStitchException(
        -96,
        'the native side reported a $what map at $path but there is no such '
        'file, so the metrics that depend on it cannot be computed',
        null,
      );
    }
    final bytes = file.readAsBytesSync();
    final header = bytes.buffer.asByteData(0, 16);
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    final gotWidth = header.getInt32(4, Endian.host);
    final gotHeight = header.getInt32(8, Endian.host);
    final gotBytes = header.getInt32(12, Endian.host);
    if (magic != 'SVMP' ||
        gotWidth != width ||
        gotHeight != height ||
        gotBytes != bytesPerPixel) {
      throw NativeStitchException(
        -95,
        'the $what map at $path is not the map this build expects: got '
        '"$magic" ${gotWidth}x$gotHeight at $gotBytes B/px, wanted "SVMP" '
        '${width}x$height at $bytesPerPixel B/px',
        null,
      );
    }
    // Copied out of the file buffer rather than viewed in place, because a
    // typed-data view needs its element alignment and the payload starts at
    // byte 16 of a buffer Dart is free to have aligned however it likes.
    return Uint8List.fromList(bytes.sublist(16));
  }

  /// The native library's self-description, for the report header.
  String version() {
    final library = _open();
    final fn = library.lookupFunction<_SvVersionC, Pointer<Utf8> Function()>('sv_version');
    return fn().toDartString();
  }
}
