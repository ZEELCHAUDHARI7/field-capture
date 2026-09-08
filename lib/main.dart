import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'features/plan/data/sphere_capture_store.dart';
import 'shared/storage/sphere_storage.dart';

/// Bootstrap only. Everything else lives in app.dart and the feature folders.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The prototype is phone-portrait throughout. Landscape and tablet layouts
  // are out of scope until Asite specifies them — see ASSUMPTIONS.md.
  //
  // sphere_view's capture screen locks portrait for itself and restores this on
  // the way out, so the two do not fight.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Resolved here rather than behind a FutureProvider so that everything
  // downstream — the plan repository, the stitch queue, the capture screen —
  // stays synchronous. It is two `Directory.create` calls and one small file
  // read; putting it in front of `runApp` costs a few milliseconds of splash
  // and saves an `AsyncValue` in five places.
  //
  // Wrapped, because the cost of anything here throwing is the whole app: this
  // runs before the first frame, so an unhandled exception is the native splash
  // screen forever with no message — on every screen, including the ones that
  // have never heard of a sphere. `SphereStorage.open` already falls back to a
  // temporary directory; this catches whatever it could not.
  //
  // The last resort still produces working objects rather than none. Both
  // providers are read by the plan repository and by the app shell, so leaving
  // either unset would only move the crash a frame later.
  late final SphereStorage storage;
  late final SphereCaptureStore captureStore;
  try {
    storage = await SphereStorage.open();
    captureStore = SphereCaptureStore(storage.captureStoreFile);
    await captureStore.load();
  } on Object catch (error, stack) {
    debugPrint('Sphere storage is unavailable: $error');
    debugPrintStack(stackTrace: stack);
    storage = SphereStorage(Directory.systemTemp);
    captureStore = SphereCaptureStore(storage.captureStoreFile);
  }

  runApp(
    ProviderScope(
      overrides: <Override>[
        sphereStorageProvider.overrideWithValue(storage),
        sphereCaptureStoreProvider.overrideWithValue(captureStore),
      ],
      child: const FieldCaptureApp(),
    ),
  );
}
