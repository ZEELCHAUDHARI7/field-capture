import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/capture/state/stitch_queue_controller.dart';

/// The application shell. Holds nothing but theme, routing, and one `read` that
/// starts the stitch queue.
class FieldCaptureApp extends ConsumerStatefulWidget {
  const FieldCaptureApp({super.key});

  @override
  ConsumerState<FieldCaptureApp> createState() => _FieldCaptureAppState();
}

class _FieldCaptureAppState extends ConsumerState<FieldCaptureApp> {
  @override
  void initState() {
    super.initState();
    // Instantiates the queue controller, which loads the queue file and starts
    // draining. Read once rather than watched: this rebuild is the whole app,
    // and progress ticks at 10 Hz.
    //
    // It happens here rather than on the plan screen because the queue's job is
    // to finish work the app was killed in the middle of, and a panorama left
    // half-stitched must not wait for somebody to happen to open the level it
    // belongs to.
    ref.read(stitchJobsProvider);
  }

  @override
  Widget build(BuildContext context) {
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
