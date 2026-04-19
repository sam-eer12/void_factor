import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/app/app.dart';

void main() {
  testWidgets('MonolithApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MonolithApp());
    expect(find.text('LOGIN'), findsOneWidget);
  });
}
