import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../camera/camera_platform.dart';
import '../metadata/gpano_writer.dart';
import '../metadata/panorama_metadata.dart';
import '../stitch/memory_tier.dart';
import '../stitch/native_stitcher.dart';
import '../stitch/stitch_isolate.dart';
import '../stitch/stitch_progress_mapper.dart';
import '../stitch/stitch_request.dart';
import 'models/capture_bundle.dart';
import 'models/sphere_capture_config.dart';
import 'models/stitch_progress.dart';
import 'models/stitch_result.dart';
import 'models/stitch_warning.dart';

/// Thrown when a stitch stops because the caller asked it to.
///
/// An exception rather than a null result, because a cancelled stitch and a
/// failed one need different handling all the way up: cancellation is not
/// something to report to the user, log, or retry — they already know, they did
/// it — and a caller that cannot tell the two apart ends up showing an error
/// dialog to somebody who pressed Cancel.
class StitchCancelledException implements Exception {
  /// Creates the exception.
  const StitchCancelledException([this.stage]);

  /// The stage the pipeline had reached, when it is known.
  final StitchStage? stage;

  @override
  String toString() =>
      'the stitch was cancelled'
      '${stage == null ? '' : ' during ${stage!.name}'}';
}

/// Turns a [CaptureBundle] into an equirectangular panorama.
///
/// Takes a bundle rather than a live session on purpose. That one signature is
/// what makes the desktop replay tool and the on-device path *the same code*:
/// `tools/replay` hands it a directory copied off a tablet and gets the
/// identical pipeline, so a real-world failure becomes a permanent regression
/// test and stitcher iteration takes seconds instead of a site visit
/// (architecture §6.6).
///
/// It also means stitching is decoupled from capture in time, which is what
/// lets the work sit on a background queue while the manager walks to the next
/// station — 30 stations × 60 s of standing still would not be acceptable
/// (Phase 10 §5). This class is the **immediate** path: it stitches the bundle
/// you hand it, now, and the caller waits. `StitchQueue` is the background one
/// and is the default for a capture session; it drives this class underneath.
class SphereStitcher {
  /// Creates a stitcher. [tier] overrides the RAM probe; leave it `null` for
  /// the deterministic per-device default (architecture §6.5).
  ///
  /// [platform] and [libraryPath] exist for tests and for `tools/replay`; on a
  /// device both defaults are correct.
  SphereStitcher({this.tier, this.platform, this.libraryPath});

  /// The forced output tier, or `null` to probe.
  final QualityTier? tier;

  /// Where the RAM probe asks. `null` uses the real platform channel.
  final SphereCameraPlatform? platform;

  /// Overrides the native library location. `null` uses the platform default.
  final String? libraryPath;

  /// How often the shared-memory counter is read.
  ///
  /// 100 ms, and no faster. Phase 10 §7.4: this timer runs on the **main**
  /// isolate and competes with the UI the isolate exists to keep smooth, and
  /// 10 Hz is already far finer than a person perceives on a progress bar that
  /// will be up for a minute.
  static const Duration pollInterval = Duration(milliseconds: 100);

  /// The default panorama file name, written beside the bundle.
  static const String defaultOutputFileName = 'panorama.jpg';

  Pointer<SvProgress>? _running;

  /// Whether a stitch is in flight on this stitcher.
  bool get isStitching => _running != null;

  /// The `force_error` value to send with attempt [attempt] at [tier], or
  /// `null` for a real run. Always `null` here.
  ///
  /// A seam for the tests, and the alternative to it is worse. The single OOM
  /// retry (architecture §8) is the code path that matters most on the worst
  /// device we support and runs least often anywhere else, so it needs to be
  /// exercised deterministically — and the only other way to do that is to
  /// actually exhaust a machine's memory, which is a test that cannot be
  /// written, only hoped for. The native side's matching hook is inert unless
  /// this returns a name (`throwIfRequested` in `sphere_stitch.cpp`).
  String? forceErrorFor(QualityTier tier, int attempt) => null;

  /// Stitches [bundle] and returns the panorama with its measured quality.
  ///
  /// [onProgress] is called at ~10 Hz from a shared-memory counter, not an FFI
  /// callback (architecture §6.3). [outputPath] defaults to a file beside the
  /// bundle.
  ///
  /// [metadata] overrides what would otherwise be derived from [bundle]. It is
  /// the hook the site-walk integration uses to supply the heading the manager
  /// drew on the plan, which Phase 11 §2 ranks above the magnetometer — the
  /// plan's north is surveyed and the drawn path gives the facing direction, so
  /// it is good to a degree or two where the compass indoors is good to tens.
  /// Its width and height are ignored in favour of the tier that was actually
  /// used, because those describe the file and the caller cannot know them
  /// before the stitch runs.
  ///
  /// Throws [StitchCancelledException] if [cancel] was called, and
  /// [NativeStitchException] for a pipeline failure — except an out-of-memory
  /// one, which is retried a tier lower before it becomes an error.
  Future<StitchResult> stitch(
    CaptureBundle bundle, {
    void Function(StitchProgress progress)? onProgress,
    String? outputPath,
    PanoramaMetadata? metadata,
  }) async {
    if (_running != null) {
      // Two concurrent stitches will OOM (Phase 10 §5), and the shared progress
      // struct has one writer per field, so a second one would also make the
      // progress bar meaningless. Refusing is the honest answer; the queue is
      // the supported way to run more than one.
      throw StateError(
        'this SphereStitcher is already running a stitch. Stitches are serial '
        'by design — two at once will run the device out of memory. Use a '
        'StitchQueue, or wait for this one.',
      );
    }

    final warnings = <StitchWarning>[];
    final QualityTier startingTier;
    if (tier != null) {
      startingTier = tier!;
    } else {
      final probe = await MemoryTier.probeDetailed(platform: platform);
      startingTier = probe.tier;
      if (probe.warning != null) warnings.add(probe.warning!);
    }

    final resolvedOutput =
        outputPath ??
        '${bundle.directory.absolute.path}/$defaultOutputFileName';
    var tierForAttempt = startingTier;

    // Allocated on the MAIN isolate, and freed here, whatever happens
    // (Phase 10 §2.2). If the worker owned this, a crash there would leak it
    // and the poller below would go on reading memory that had been handed
    // back — a use-after-free whose symptom is a plausible-looking progress
    // bar rather than anything traceable.
    //
    // `calloc`, never `malloc` (Phase 10 §7.3). An uninitialised `cancel`
    // holding garbage cancels the stitch on the first poll, and what the user
    // sees is that pressing Stitch does nothing at all.
    final progress = calloc<SvProgress>();
    _running = progress;
    try {
      for (var attempt = 0; ; attempt++) {
        // Zeroed before each attempt so the retry's progress bar starts at the
        // beginning rather than resuming from where the failed one died.
        progress.ref
          ..stage = 0
          ..permille = 0
          ..cancel = 0;

        final request = StitchRequest.from(
          bundle,
          tier: tierForAttempt,
          outputPath: resolvedOutput,
          forceError: forceErrorFor(tierForAttempt, attempt),
        );
        final outcome = await _runOnce(request, progress, onProgress);
        final reachedStage = StitchStage.values[progress.ref.stage.clamp(
          0,
          StitchStage.values.length - 1,
        )];

        // Read before anything below resets it. A cancel that arrived while the
        // attempt was failing for some *other* reason still has to win: without
        // this, pressing Cancel on a run that then hits an allocation failure
        // would be answered by starting a second stitch the user has just asked
        // to stop.
        if (outcome.isCancelled || progress.ref.cancel != 0) {
          throw StitchCancelledException(reachedStage);
        }

        if (SvStatus.isOutOfMemory(outcome.code) && attempt == 0) {
          final lower = MemoryTier.degrade(tierForAttempt);
          if (lower != null) {
            // Architecture §8: degrade once, finish, and say so. Not twice —
            // a device that cannot hold `mid` after failing `high` is not
            // going to be rescued by a third guess, and each attempt costs the
            // user another minute.
            warnings.add(
              StitchWarning(
                StitchWarningCode.tierDowngradedAfterOom,
                data: {
                  'width': lower.outputWidth,
                  'height': lower.outputHeight,
                  'requested_width': tierForAttempt.outputWidth,
                  'requested_height': tierForAttempt.outputHeight,
                },
                detail:
                    'sv_stitch returned SV_OUT_OF_MEMORY at '
                    '${tierForAttempt.name}; retried once at ${lower.name}',
              ),
            );
            tierForAttempt = lower;
            continue;
          }
        }

        if (!outcome.isOk) {
          throw NativeStitchException(
            outcome.code,
            outcome.message,
            outcome.reportJson,
          );
        }
        final result = _resultFrom(
          outcome,
          tierForAttempt,
          resolvedOutput,
          warnings,
        );
        return _withMetadata(result, bundle, outcome.reportJson, metadata);
      }
    } finally {
      // Cleared *before* the free, so a `cancel()` racing this writes into
      // memory that is still ours rather than into a freed page.
      _running = null;
      calloc.free(progress);
    }
  }

  /// Requests cancellation of the running stitch.
  ///
  /// Sets the shared cancel flag, which the native side polls between
  /// positions, between exposures within a position, between frames, between
  /// seam pairs and between blend tiles. This is real cancellation rather than
  /// an ignored request, and it is the main reason progress goes through shared
  /// memory in the first place (architecture §6.3).
  ///
  /// Safe to call when nothing is running, and safe to call twice.
  void cancel() {
    final progress = _running;
    if (progress == null) return;
    progress.ref.cancel = 1;
  }

  /// Runs one attempt and pumps progress while it does.
  Future<NativeStitchOutcome> _runOnce(
    StitchRequest request,
    Pointer<SvProgress> progress,
    void Function(StitchProgress)? onProgress,
  ) async {
    final mapper = StitchProgressMapper();
    Timer? poll;
    if (onProgress != null) {
      // Emitted immediately as well as on the timer, so the UI has something
      // to show for the first 100 ms rather than an empty bar.
      onProgress(mapper.read(progress));
      poll = Timer.periodic(pollInterval, (_) => onProgress(mapper.read(progress)));
    }
    try {
      final outcome = await StitchIsolate.run(
        jsonEncode(request.toJson()),
        // The address, not the pointer — Phase 10 §2.1. Pointers are not
        // sendable; an int is, and both isolates share one process address
        // space, so the worker's `Pointer.fromAddress` refers to exactly this
        // allocation. That is the whole trick the design rests on.
        progress.address,
        libraryPath: libraryPath,
      );
      if (onProgress != null && outcome.isOk) onProgress(mapper.completed);
      return outcome;
    } finally {
      poll?.cancel();
    }
  }

  /// Writes XMP GPano and EXIF into the finished panorama, and into the preview
  /// beside it.
  ///
  /// This is criterion S10, and it happens here rather than in C++ for a reason
  /// worth stating: the metadata's most valuable field is the heading, its best
  /// source is the *plan* (Phase 11 §2), and the plan is a Dart-side fact the
  /// native pipeline has never heard of. Pushing the writer across the FFI
  /// boundary would mean pushing the heading priority order across it too, and
  /// the C++ side would then hold a rule about a drawing it cannot see.
  ///
  /// The preview gets the same block. It is a 2048-wide equirect of the same
  /// scene, it is the file a UI is most likely to share because it is small,
  /// and a preview that opens flat while the full file opens as a sphere is a
  /// difference nobody would predict from the file names.
  ///
  /// A failure here does **not** fail the stitch. A panorama with no metadata
  /// is a worse artefact but it is still a real one, and the alternative —
  /// discarding a minute of work and every frame behind it because a `write`
  /// call failed — is not a trade anybody would choose. It lands in
  /// `report.warnings` instead, per architecture §8.
  Future<StitchResult> _withMetadata(
    StitchResult result,
    CaptureBundle bundle,
    String? reportJson,
    PanoramaMetadata? override,
  ) async {
    final metadata = (override ??
            PanoramaMetadata.forCapture(
              fullWidth: result.width,
              fullHeight: result.height,
              sessionId: bundle.sessionId,
              heading: bundle.heading,
              capturedAt: bundle.capturedAt,
              location: bundle.location,
              deviceInfo: bundle.deviceInfo,
            ))
        .copyWith(fullWidth: result.width, fullHeight: result.height);

    final warnings = <StitchWarning>[];
    const writer = GPanoWriter();
    try {
      await writer.write(File(result.equirectPath), metadata);
      final preview = _previewPathFrom(reportJson);
      if (preview != null && await File(preview).exists()) {
        // The preview describes the same sphere, so it carries the same
        // FullPano dimensions as the full file rather than its own 2048×1024.
        // That is what GPano's Cropped/Full distinction is for, and it is what
        // makes the small file open at the right zoom instead of appearing to
        // be a sixth of a panorama.
        await writer.write(File(preview), metadata);
      }
    } on Object catch (e) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.metadataNotWritten,
          detail: 'GPanoWriter.write threw: $e',
        ),
      );
    }

    final headingWarning = metadata.heading.warning;
    if (headingWarning != null) warnings.add(headingWarning);
    if (warnings.isEmpty) return result;

    return StitchResult(
      equirectPath: result.equirectPath,
      width: result.width,
      height: result.height,
      report: result.report.copyWithWarnings([
        ...result.report.warnings,
        ...warnings,
      ]),
    );
  }

  /// The preview path the native compositor recorded, or `null`.
  ///
  /// Read out of the raw report JSON rather than off [StitchReport] because the
  /// preview is a compositing detail the typed report does not model, and
  /// architecture §6.4's reason for a JSON ABI is precisely that a field can be
  /// read without every layer in between having to know about it.
  static String? _previewPathFrom(String? reportJson) {
    if (reportJson == null) return null;
    try {
      final map = jsonDecode(reportJson);
      if (map is! Map) return null;
      final compositing = map['compositing'];
      if (compositing is! Map) return null;
      final path = compositing['preview_path'];
      return path is String && path.isNotEmpty ? path : null;
    } on FormatException {
      return null;
    }
  }

  StitchResult _resultFrom(
    NativeStitchOutcome outcome,
    QualityTier tier,
    String outputPath,
    List<StitchWarning> extraWarnings,
  ) {
    final json = outcome.reportJson;
    if (json == null) {
      throw const NativeStitchException(
        SvStatus.internal,
        'the stitch reported success but produced no report. The report is '
        'how quality is measured, so a result without one cannot be trusted.',
      );
    }
    final map = (jsonDecode(json) as Map).cast<String, Object?>();
    if (extraWarnings.isNotEmpty) {
      // Merged into the report rather than kept beside it, because
      // architecture §8's rule is that every compromise reaches the caller —
      // and a caller reads `report.warnings`. A downgrade recorded anywhere
      // else is a downgrade nobody sees.
      map['warnings'] = [
        for (final warning in extraWarnings) warning.toJson(),
        ...((map['warnings'] as List?) ?? const []),
      ];
    }
    final report = StitchReport.fromJson(map);
    return StitchResult(
      equirectPath: outputPath,
      width: tier.outputWidth,
      height: tier.outputHeight,
      report: report,
    );
  }
}
