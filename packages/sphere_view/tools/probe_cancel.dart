import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:sphere_view/src/api/models/capture_bundle.dart';

import 'harness/native_stitcher.dart';

/// Measures how long `SvProgress.cancel` takes to actually stop a stitch.
///
/// The exit criterion is 500 ms, and the reason it is a criterion at all is
/// that cancellation which only takes effect at a stage boundary is not
/// cancellation: undistort and feature detection are each seconds long on a
/// full bundle, so a flag polled once per stage would leave a user staring at a
/// cancelled progress bar.
///
/// The measurement has to be done across isolates because `sv_stitch` blocks
/// the calling isolate for its whole duration. That is exactly the arrangement
/// the real pipeline uses (architecture §6.3): the worker isolate runs the
/// stitch, the UI isolate writes `cancel` into shared memory, and the two never
/// synchronise on anything else. Passing the raw address across is safe here
/// precisely because `calloc` memory is process-wide and outlives both.
Future<void> main(List<String> arguments) async {
  final directory = Directory(
    arguments.isEmpty ? 'build/bundles/nominal' : arguments.first,
  );
  final bundle = await CaptureBundle.load(directory);

  final progress = calloc<SvProgress>();
  final request = jsonEncode({
    'schema_version': NativeStitcherBackend.schemaVersion,
    'bundle_dir': bundle.directory.absolute.path,
    'output_path': '',
    'tier': 'mid',
    'registration_only': true,
    'bundle': bundle.toJson(),
  });

  const backend = NativeStitcherBackend();
  final libraryPath = File(backend.resolvedPath).absolute.path;

  final done = ReceivePort();
  final started = Stopwatch()..start();

  await Isolate.spawn(_worker, [
    done.sendPort,
    libraryPath,
    request,
    progress.address,
  ]);

  // Let it get properly under way, then pull the flag. Cancelling before the
  // first frame is read would prove nothing — the interesting case is a cancel
  // arriving in the middle of a long stage.
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final requestedAt = started.elapsedMilliseconds;
  progress.ref.cancel = 1;

  final result = await done.first as List<Object?>;
  final finishedAt = started.elapsedMilliseconds;
  done.close();

  final latency = finishedAt - requestedAt;
  stdout.writeln('bundle          ${directory.path}');
  stdout.writeln('stage reached   ${progress.ref.stage} '
      '(${progress.ref.permille ~/ 10}% through it)');
  stdout.writeln('return code     ${result[0]}   ${result[1]}');
  stdout.writeln('cancel latency  $latency ms   target < 500');
  stdout.writeln(latency < 500 ? 'PASS' : 'FAIL');

  calloc.free(progress);
  exitCode = latency < 500 && result[0] == -6 ? 0 : 1;
}

void _worker(List<Object?> message) {
  final sendPort = message[0] as SendPort;
  final libraryPath = message[1] as String;
  final request = message[2] as String;
  final progress = Pointer<SvProgress>.fromAddress(message[3] as int);

  final library = DynamicLibrary.open(libraryPath);
  final stitch = library.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<SvProgress>, Pointer<Utf8>, Int32,
          Pointer<Pointer<Utf8>>),
      int Function(Pointer<Utf8>, Pointer<SvProgress>, Pointer<Utf8>, int,
          Pointer<Pointer<Utf8>>)>('sv_stitch');

  final requestPtr = request.toNativeUtf8();
  final errorPtr = calloc<Uint8>(2048).cast<Utf8>();
  final reportPtr = calloc<Pointer<Utf8>>();

  final code = stitch(requestPtr, progress, errorPtr, 2048, reportPtr);
  final message2 = errorPtr.toDartString();

  calloc.free(requestPtr);
  calloc.free(errorPtr);
  calloc.free(reportPtr);
  sendPort.send([code, message2]);
}
