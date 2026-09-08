import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The shared-memory progress triple the native pipeline writes and Dart polls.
///
/// This struct is the whole of architecture §6.3. Calling back into Dart from a
/// C++ worker thread needs a `NativeCallable.listener` bound to a specific
/// isolate, which is fragile across that isolate's lifecycle — and the failure
/// mode is a hang, not an error. Instead C++ writes three `int32`s into memory
/// the main isolate allocated, the isolate polls at 10 Hz, and the UI sets
/// [cancel] which C++ checks between tiles. No lifetime hazards, and
/// cancellation that actually works.
///
/// **The layout is the ABI.** It must stay three `int32_t`s in this order, byte
/// for byte identical to `SvProgress` in `src/sphere_stitch/sphere_stitch.h`; a
/// mismatch is not an error but silent memory corruption, which is why
/// [SvProgressAbi.assertLayout] exists and why the tests call it.
final class SvProgress extends Struct {
  /// Index into `StitchStage.values` — see the ABI note on that enum.
  @Int32()
  external int stage;

  /// Progress in thousandths, `0..1000`, **within [stage]** — not overall.
  ///
  /// Per-stage because that is the only thing C++ can compute honestly: it
  /// knows it is on frame 12 of 34, not what fraction of the remaining minute
  /// that represents. Turning the pair into the single monotone number a
  /// progress bar needs is [StitchProgressMapper]'s job, on the Dart side,
  /// where the stage weights live.
  @Int32()
  external int permille;

  /// Set to non-zero by the UI to request cancellation.
  ///
  /// The only field Dart writes and the only field C++ reads. That one-way
  /// split per field is what makes the whole arrangement lock-free: each field
  /// has exactly one writer, and an aligned `int32` store is never torn, so a
  /// reader can see a stale value but never a nonsensical one.
  @Int32()
  external int cancel;
}

/// Facts about [SvProgress] that have to hold for the shared memory to work.
abstract final class SvProgressAbi {
  /// `3 * sizeof(int32_t)`, with no padding — Phase 10 §7.6.
  static const int expectedSizeBytes = 12;

  /// Throws unless the Dart struct matches the C one.
  ///
  /// Called from the tests rather than from a hot path, but it is cheap enough
  /// to call anywhere. The check is worth having because the failure it catches
  /// is invisible: a fourth field added to the C struct without adding it here
  /// does not fail to compile, it makes `cancel` read whatever happens to sit
  /// twelve bytes into a struct that is now longer, and cancellation stops
  /// working on one platform for reasons nothing in the log explains.
  static void assertLayout() {
    if (sizeOf<SvProgress>() != expectedSizeBytes) {
      throw StateError(
        'SvProgress is ${sizeOf<SvProgress>()} bytes in Dart but must be '
        '$expectedSizeBytes to match sphere_stitch.h. The shared-memory '
        'progress triple is a raw memory overlay, so a layout difference is '
        'silent corruption rather than an error.',
      );
    }
  }
}

/// Return codes from `sv_stitch`. Mirrors the `SV_*` defines in
/// `sphere_stitch.h`; see that header for what each one means.
abstract final class SvStatus {
  /// The stitch completed.
  static const int ok = 0;

  /// `request_json` did not parse.
  static const int badJson = -1;

  /// `schema_version` disagrees with the native build.
  static const int schema = -2;

  /// The bundle had nothing to stitch.
  static const int noFrames = -3;

  /// A frame or the output path was unreadable.
  static const int io = -4;

  /// Bundle adjustment failed outright.
  static const int registration = -5;

  /// The caller set `SvProgress.cancel`.
  static const int cancelled = -6;

  /// The plan is too sparse to register — actionable, re-shoot.
  static const int insufficient = -7;

  /// A bug in the pipeline; the message says where.
  static const int internal = -8;

  /// Allocation failed. The one code the caller *acts* on rather than reports:
  /// it means drop a tier and retry once (architecture §8).
  static const int outOfMemory = -9;

  /// A `cv::Exception` that was not an allocation failure.
  static const int openCv = -10;

  /// Something not derived from `std::exception` reached the ABI boundary.
  static const int unknown = -11;

  /// Whether [code] means the stitch should be retried one tier down.
  static bool isOutOfMemory(int code) => code == outOfMemory;
}

typedef _SvStitchNative =
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
typedef _SvFreeNative = Void Function(Pointer<Utf8>);
typedef _SvFreeDart = void Function(Pointer<Utf8>);
typedef _SvVersionNative = Pointer<Utf8> Function();

/// What one `sv_stitch` call returned.
///
/// A value type with no pointers in it, so it can cross the isolate boundary
/// unchanged. The report travels as its raw JSON string rather than as a parsed
/// `StitchReport` for the same reason the ABI is JSON at all (architecture
/// §6.4): the worker isolate should not need to know the report's shape, and a
/// field added to the native report must not make the worker fail to send it.
class NativeStitchOutcome {
  /// Creates an outcome.
  const NativeStitchOutcome({
    required this.code,
    required this.message,
    required this.reportJson,
  });

  /// One of the [SvStatus] values.
  final int code;

  /// What the native side wrote into `error_buf`; empty on success.
  final String message;

  /// The report JSON, or `null` when none was produced.
  ///
  /// Present even on several *failures*: architecture §8's never-degrade-
  /// silently rule applies to failures too, and on a partial failure the
  /// numbers are usually the diagnosis.
  final String? reportJson;

  /// Whether the stitch succeeded.
  bool get isOk => code == SvStatus.ok;

  /// Whether the caller asked for this to stop.
  bool get isCancelled => code == SvStatus.cancelled;

  @override
  String toString() =>
      'NativeStitchOutcome($code${message.isEmpty ? '' : ': $message'})';
}

/// Thrown when the native library reports a failure.
///
/// Carries [code] so a caller can tell the cases apart that need different
/// answers: `insufficient` is "re-shoot this station", `outOfMemory` is a retry
/// the stitcher performs for you, and `internal` is a bug report.
class NativeStitchException implements Exception {
  /// Creates the exception.
  const NativeStitchException(this.code, this.message, [this.reportJson]);

  /// One of the [SvStatus] values.
  final int code;

  /// The message the native side wrote.
  final String message;

  /// The report, when one was produced anyway.
  final String? reportJson;

  @override
  String toString() => 'native stitch failed ($code): $message';
}

/// The FFI binding to `libsphere_stitch`.
///
/// Native is unavoidable here rather than preferred: graph-cut seam finding
/// needs max-flow over a large lattice, and SIFT plus bundle adjustment in Dart
/// would be 10–50× too slow with a lower quality ceiling (architecture §5). The
/// bindings are hand-written against the small `extern "C"` shim in
/// `src/sphere_stitch/sphere_stitch.h` — R1 established that no off-the-shelf
/// OpenCV channel exposes `cv::detail::` at all, so the shim is ours regardless.
///
/// **Construct this inside the isolate that will call it.** FFI symbol lookups
/// are per-isolate: a handle resolved on the main isolate is not usable from a
/// worker, and the failure is a crash rather than an exception (Phase 10 §2.3).
class NativeStitcher {
  /// Wraps an already-opened [library].
  NativeStitcher(this.library)
    : _stitch = library.lookupFunction<_SvStitchNative, _SvStitchDart>(
        'sv_stitch',
      ),
      _free = library.lookupFunction<_SvFreeNative, _SvFreeDart>('sv_free'),
      _version = library
          .lookupFunction<_SvVersionNative, Pointer<Utf8> Function()>(
            'sv_version',
          );

  /// The loaded dynamic library.
  final DynamicLibrary library;

  final _SvStitchDart _stitch;
  final _SvFreeDart _free;
  final Pointer<Utf8> Function() _version;

  /// How many bytes of error message the native side may write back.
  static const int errorBufferBytes = 2048;

  /// The Android shared-object name.
  static const String androidLibraryName = 'libsphere_stitch.so';

  /// Where `tools/build_native.sh` puts the desktop build, without its
  /// platform extension. Used by `tools/replay` and by the tests.
  static const String desktopLibraryStem = 'build/native/libsphere_stitch';

  /// Opens the platform's copy of `libsphere_stitch`.
  ///
  /// The three platforms genuinely differ, and Phase 10 §7.2 names getting this
  /// wrong as a pitfall because it works on one platform and not the other:
  ///
  /// * **iOS** links the library into the app binary, so there is no file to
  ///   open and the symbols are already in the process.
  /// * **Android** ships it as a real `.so` beside the app's other JNI
  ///   libraries, found by name on the loader path.
  /// * **Desktop** is the replay and test path, where the library is whatever
  ///   `tools/build_native.sh` just built.
  ///
  /// [libraryPath] overrides all of it, which is what the tests use.
  static NativeStitcher open({String? libraryPath}) =>
      NativeStitcher(openLibrary(libraryPath: libraryPath));

  /// Whether the native library loads and answers, as a message or `null`.
  ///
  /// Returns `null` when the stitcher is usable. Otherwise the reason, short
  /// enough to put in front of an operator.
  ///
  /// Exists so the capability probe can refuse *before* a capture rather than
  /// after one. The library is built for `arm64-v8a` only, so on an `x86_64`
  /// emulator or a 32-bit tablet `DynamicLibrary.open` throws and, without this,
  /// the first sign of it is a stitch failing ninety seconds of capture later.
  /// `sv_version` is called rather than merely opening the library, because a
  /// library that loads but is missing a symbol fails the same way and just as
  /// late.
  static String? probeError() {
    try {
      final version = NativeStitcher(openLibrary()).version();
      return version.isEmpty ? 'the stitching library reported no version' : null;
    } on Object catch (error) {
      return '$error'.split('\n').first;
    }
  }

  /// [open]'s library-loading half, exposed because the worker isolate wants
  /// to open the library and construct the binding as one step.
  static DynamicLibrary openLibrary({String? libraryPath}) {
    if (libraryPath != null) return DynamicLibrary.open(libraryPath);
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isAndroid) return DynamicLibrary.open(androidLibraryName);

    final path = defaultDesktopLibraryPath;
    if (!File(path).existsSync()) {
      throw StateError(
        'The native stitcher is not built.\n'
        '  expected: $path\n'
        '  build it with:\n'
        '      tools/build_native.sh\n'
        '  (the first run also builds OpenCV for the host, ~10-20 min; after '
        'that it is seconds.)',
      );
    }
    return DynamicLibrary.open(path);
  }

  /// The desktop library path, extension included.
  static String get defaultDesktopLibraryPath => switch (Platform
      .operatingSystem) {
    'macos' => '$desktopLibraryStem.dylib',
    'windows' => '$desktopLibraryStem.dll',
    _ => '$desktopLibraryStem.so',
  };

  /// Runs the pipeline synchronously on the calling thread.
  ///
  /// Must only be called from a worker isolate — it blocks for the full stitch,
  /// which S8 budgets at up to 60 seconds. [progress] is the shared-memory
  /// triple the *main* isolate allocated; writing `cancel` into it from there is
  /// what stops this call.
  ///
  /// Never throws for a pipeline failure: the whole point of the `noexcept` ABI
  /// guard on the other side is that failures are return codes, so this returns
  /// one too and lets the caller decide which are worth an exception.
  NativeStitchOutcome stitch(
    String requestJson,
    Pointer<SvProgress> progress,
  ) {
    final requestPtr = requestJson.toNativeUtf8();
    final errorPtr = calloc<Uint8>(errorBufferBytes).cast<Utf8>();
    final reportPtr = calloc<Pointer<Utf8>>();
    try {
      final code = _stitch(
        requestPtr,
        progress,
        errorPtr,
        errorBufferBytes,
        reportPtr,
      );

      String? report;
      if (reportPtr.value != nullptr) {
        report = reportPtr.value.toDartString();
        // Phase 10 §7.5: this buffer came out of C++'s `new[]`, so it goes back
        // through the library's own `sv_free`. Handing it to `calloc.free`
        // instead mismatches the allocators, which corrupts the heap in a way
        // that surfaces somewhere else entirely, much later.
        _free(reportPtr.value);
        reportPtr.value = nullptr;
      }
      return NativeStitchOutcome(
        code: code,
        message: errorPtr.cast<Uint8>().value == 0
            ? ''
            : errorPtr.toDartString(),
        reportJson: report,
      );
    } finally {
      calloc.free(requestPtr);
      calloc.free(errorPtr);
      calloc.free(reportPtr);
    }
  }

  /// The library's self-description: its schema version and the OpenCV it was
  /// linked against.
  ///
  /// Worth having because "which OpenCV did this run use" is the first question
  /// when desktop replay and the device disagree. Static storage on the native
  /// side; not freed.
  String version() => _version().toDartString();
}
