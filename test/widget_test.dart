import 'package:flutter_test/flutter_test.dart';

import 'package:app/main.dart';

void main() {
  testWidgets('Initial app test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ERPApp());

    // Verify that the title text exists
    expect(find.text('تهيئة النظام'), findsOneWidget);
  });
}
