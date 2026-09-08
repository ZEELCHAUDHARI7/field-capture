// Smoke test for the app shell.
//
// Replaces the counter-app boilerplate that `flutter create` drops in. That
// version referenced `MyApp`, which does not exist here — the shell is
// `FieldCaptureApp` in lib/app.dart, and it needs a ProviderScope above it.
//
// Deliberately does NOT use pumpAndSettle: connectivity_pill.dart and
// state_views.dart drive repeating animations, and pumpAndSettle never
// returns while one is running.
//
// The storage overrides are what `main()` resolves before `runApp`. The shell
// starts the stitch queue on the first frame, so booting without them throws —
// which is the point of those providers having no default.

import 'package:field_capture/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sphere_test_support.dart';

void main() {
  testWidgets('app boots to the sign-in screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: sphereStorageOverrides(),
        child: const FieldCaptureApp(),
      ),
    );

    await tester.pump();                                   // first route builds
    await tester.pump(const Duration(milliseconds: 400));  // entrance transition

    expect(find.text('Field Capture'), findsOneWidget);
    expect(
      find.text('Site progress monitoring · 360° capture'),
      findsOneWidget,
    );
  });
}
