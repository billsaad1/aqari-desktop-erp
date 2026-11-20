import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/reports_inquiry/accounting_periods_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_accounting_periods_screen_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
  });

  setUp(() async {
    await helper.close();
    final stale = Directory(testDocuments);
    if (await stale.exists()) await stale.delete(recursive: true);
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(() async {
    await helper.close();
  });

  tearDownAll(() async {
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1024,
              height: 564,
              child: const AccountingPeriodsScreen(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
    });
  }

  testWidgets('period controls remain scrollable in a short desktop window', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final period = await helper.createAccountingPeriod(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );
      await helper.lockAccountingPeriod(period.id);
      await helper.closeAccountingPeriod(period.id);
    });

    await pumpScreen(tester);

    expect(find.text('جاهزية الفترات وقفلها'), findsOneWidget);
    expect(find.text('2026-02-01 — 2026-02-28'), findsOneWidget);
    expect(find.text('مقفلة نهائيًا'), findsOneWidget);
    expect(tester.takeException(), isNull);

    PermissionRuntime.activate(
      userId: 1,
      role: 'Admin',
      permissionRows: const [],
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
    });
    expect(find.text('إعادة فتح'), findsNothing);
    expect(find.text('سجل الأحداث'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
