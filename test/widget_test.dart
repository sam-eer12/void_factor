import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:void_factor/app/app.dart';
import 'package:void_factor/features/auth/auth_provider.dart';

class MockAuthController extends AuthController {
  @override
  SignupState build() {
    return SignupState();
  }
}

void main() {
  testWidgets('MonolithApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => MockAuthController()),
          authStateProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const MonolithApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LOGIN'), findsOneWidget);
  });
}
