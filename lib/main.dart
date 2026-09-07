import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Bootstrap only. Everything else lives in app.dart and the feature folders.
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The prototype is phone-portrait throughout. Landscape and tablet layouts
  // are out of scope until Asite specifies them — see ASSUMPTIONS.md.
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: FieldCaptureApp()));
}
