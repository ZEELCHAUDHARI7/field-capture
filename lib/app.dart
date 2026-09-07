import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

/// The application shell. Holds nothing but theme and routing.
class FieldCaptureApp extends ConsumerWidget {
  const FieldCaptureApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Field Capture',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,

      // The prototype is designed for sunlight contrast and defines no dark
      // variant. Locking to light avoids a half-designed dark theme shipping
      // by accident. See ASSUMPTIONS.md.
      themeMode: ThemeMode.light,

      routerConfig: router,

      // Site crews wear gloves and often run large system text. Clamp rather
      // than ignore, so layouts hold together at the extremes.
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.3,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
