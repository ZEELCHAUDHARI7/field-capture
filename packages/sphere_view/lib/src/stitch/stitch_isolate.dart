import 'dart:ffi';
import 'dart:isolate';

import 'native_stitcher.dart';

/// The worker-isolate entry point for a stitch.
///
/// The stitch runs off the platform thread because S8 budgets it at up to 60
/// seconds and an FFI call blocks the isolate that makes it — so on the main
/// isolate that is 60 seconds of frozen UI, no progress bar, no cancel button,
/// and on both platforms a real chance the OS watchdog kills the app
/// (Phase 10 §1).
///
/// What the isolate buys is worth stating precisely, because it is easy to
/// overclaim: it makes the native work concurrent with **Dart**, not with
/// anything else. The C++ still runs on a real thread and still competes for
/// CPU and memory. The isolate buys a responsive UI, not free throughput.
abstract final class StitchIsolate {
  /// Runs the native pipeline on a worker isolate.
  ///
  /// [progressAddress] is the address of an `SvProgress` allocated by the
  /// **caller**, on the main isolate. That ownership is not an accident:
  ///
  /// * the caller can write `cancel` into it while this runs, which is the
  ///   whole cancellation mechanism (architecture §6.3); and
  /// * if the worker owned the allocation, a crash there would leak it, and the
  ///   poller on the main isolate would go on reading freed memory — a
  ///   use-after-free whose symptom is a progress bar that reports garbage
  ///   rather than a crash anyone can trace (Phase 10 §2.2).
  ///
  /// [libraryPath] overrides the platform's default library location; the
  /// tests use it, the device does not.
  static Future<NativeStitchOutcome> run(
    String requestJson,
    int progressAddress, {
    String? libraryPath,
  }) {
    // Everything captured here is a String or an int. Phase 10 §7.1: the
    // closure is sent to the worker, so anything it references must be
    // sendable — capturing the bundle, the config or `this` would fail at run
    // time with an error about a non-sendable object, and capturing a
    // `Pointer` would fail for the same reason, which is precisely why the
    // address travels as an int.
    return Isolate.run(
      () => runInIsolate(requestJson, progressAddress, libraryPath),
    );
  }

  /// The body that executes on the worker.
  ///
  /// Split out from [run] rather than written inline in the closure so that the
  /// closure stays one call with three sendable arguments and nothing else in
  /// scope — Phase 10 §7.1's pitfall is that `Isolate.run` captures whatever
  /// its body mentions, and a stray reference to a bundle or to `this` fails at
  /// run time rather than at compile time.
  ///
  /// Opens the library **here**, not on the caller's isolate. FFI symbol
  /// resolution is per-isolate: a `DynamicLibrary` handle captured from another
  /// isolate is not usable, and Phase 10 §2.3 names this as one of the three
  /// details that are easy to get wrong. It is also cheap — the OS has the
  /// library mapped already after the first stitch.
  static NativeStitchOutcome runInIsolate(
    String requestJson,
    int progressAddress,
    String? libraryPath,
  ) {
    // Valid because both isolates live in one process and therefore in one
    // address space. This is the trick the whole shared-memory progress design
    // rests on: `Pointer` is not sendable, `int` is, and `Pointer.fromAddress`
    // reconstructs the former from the latter without copying anything.
    final progress = Pointer<SvProgress>.fromAddress(progressAddress);
    final stitcher = NativeStitcher.open(libraryPath: libraryPath);
    return stitcher.stitch(requestJson, progress);
  }
}
