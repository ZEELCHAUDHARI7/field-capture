// Smoke test for the app shell.
//
// Replaces the counter-app boilerplate that `flutter create` drops in. That
// version referenced `MyApp`, which does not exist here — the shell is
// `FieldCaptureApp` in lib/app.dart, and it needs a ProviderScope above it.
//
// Deliberately does NOT use pumpAndSettle: connectivity_pill.dart and
// state_views.dart drive repeating animations, and pumpAndSettle never
// returns while one is running.

import 'package:field_capture/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to the sign-in screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: FieldCaptureApp()),
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
