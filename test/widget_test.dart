import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app/main.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/navigation_provider.dart';

void main() {
  testWidgets('Initial app test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => NavigationProvider()),
        ],
        child: const ERPApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify that the login screen text exists
    expect(find.text('تسجيل الدخول'), findsWidgets);
  });
}
