import 'package:app/core/app_theme.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/features/main_shell/main_shell_screen.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/navigation_provider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  setUp(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(PermissionRuntime.clear);

  testWidgets(
    'mouse wheel scroll changes sidebar offset and scrollbar is visible',
    (WidgetTester tester) async {
      await _mountSidebar(tester);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(scrollable.position.pixels, 0);

      final listRect = tester.getRect(find.byType(ListView));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: listRect.center,
          scrollDelta: const Offset(0, 320),
        ),
      );
      await tester.pump();

      expect(scrollable.position.pixels, greaterThan(0));
      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.trackVisibility, isTrue);
      expect(scrollbar.interactive, isTrue);
    },
  );

  testWidgets(
    'PageDown and PageUp scroll while a navigation item stays focused',
    (WidgetTester tester) async {
      await _mountSidebar(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final focusedNode = tester.binding.focusManager.primaryFocus;
      expect(focusedNode, isNotNull);
      var focusIsInsideNavigationItem = false;
      focusedNode!.context!.visitAncestorElements((element) {
        if (element.widget is ListTile) focusIsInsideNavigationItem = true;
        return true;
      });
      expect(focusIsInsideNavigationItem, isTrue);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.binding.focusManager.primaryFocus, same(focusedNode));

      final pageDownOffset = scrollable.position.pixels;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, lessThan(pageDownOffset));
      expect(tester.binding.focusManager.primaryFocus, same(focusedNode));
    },
  );

  testWidgets(
    'logout remains visible and tappable while the navigation list is scrolled',
    (WidgetTester tester) async {
      await _mountSidebar(tester);
      final listRect = tester.getRect(find.byType(ListView));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: listRect.center,
          scrollDelta: const Offset(0, 1000),
        ),
      );
      await tester.pump();

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.pixels, greaterThan(0));
      final sidebarRect = tester.getRect(find.byType(AppSidebar));
      final logoutRect = tester.getRect(find.text('تسجيل الخروج'));
      expect(logoutRect.top, greaterThanOrEqualTo(sidebarRect.top));
      expect(logoutRect.bottom, lessThanOrEqualTo(sidebarRect.bottom));
      expect(tester.getTopLeft(find.text('تسجيل الخروج')).dy, greaterThan(0));

      await tester.tap(find.text('تسجيل الخروج'));
      await tester.pumpAndSettle();
      expect(find.text('مرحبًا بعودتك'), findsOneWidget);
    },
  );
}

Future<void> _mountSidebar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => NavigationProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Row(
            children: [
              AppSidebar(),
              Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
