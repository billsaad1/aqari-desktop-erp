import 'dart:convert';
import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/audit/audit_trail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_audit_screen_flutter_test';
  final helper = DatabaseHelper.instance;

  // The database is seeded here rather than per test: opening it inside a widget
  // test blocks, because `testWidgets` runs in a fake-async zone where the
  // sqflite isolate response never arrives.
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return testDocuments;
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
    final stale = Directory(testDocuments);
    if (await stale.exists()) await stale.delete(recursive: true);
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    final db = await helper.database;
    await db.insert('audit_logs', {
      'user_id': 1,
      'actor_name': 'مدير النظام',
      'action': 'JOURNAL_ENTRY_POSTED',
      'entity_type': 'journal_entry',
      'entity_id': 7,
      'amount_minor': 125050,
      'details': jsonEncode({'debit_minor': 125050, 'credit_minor': 125050}),
      'timestamp': '2026-05-01T10:30:00',
    });
    await db.insert('audit_logs', {
      'user_id': 1,
      'actor_name': 'مدير النظام',
      'action': 'ACCOUNT_CREATE',
      'entity_type': 'account',
      'entity_id': 42,
      'details': '{}',
      'timestamp': '2026-05-03T08:00:00',
    });
    await db.insert('audit_logs', {
      'user_id': 1,
      'actor_name': 'مدير النظام',
      'action': 'CONTRACT_CREATED',
      'entity_type': 'contract',
      'entity_id': 3,
      'details': '{}',
      'timestamp': '2026-05-02T09:00:00',
    });
  });

  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  /// Mounts the screen and lets the real database round-trip finish.
  ///
  /// Both the mount and the wait run inside [WidgetTester.runAsync];
  /// `pumpAndSettle` cannot be used because the loading spinner animates
  /// indefinitely while the query is in flight.
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AuditTrailScreen())),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await tester.pump();
    });
  }

  testWidgets('renders recorded events with readable Arabic labels', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.text('سجل التدقيق المالي'), findsOneWidget);
    expect(find.text('ترحيل قيد يومية'), findsWidgets);
    expect(find.text('مدير النظام'), findsWidgets);
    expect(find.textContaining('1,250.50'), findsOneWidget);
    expect(find.textContaining('2026-05-01 10:30:00'), findsOneWidget);
    expect(find.text('إنشاء عقد'), findsWidgets);
  });

  testWidgets('denies rendering without audit_logs.view', (tester) async {
    PermissionRuntime.activate(
      userId: 2,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await pumpScreen(tester);

    expect(find.text('لا تملك صلاحية عرض سجل التدقيق المالي'), findsOneWidget);
    expect(find.text('ترحيل قيد يومية'), findsNothing);
  });

  testWidgets('every recorded action code has an Arabic label', (
    tester,
  ) async {
    // Guards against the screen drifting from the codes the database writes.
    await pumpScreen(tester);

    expect(find.text('إنشاء حساب'), findsWidgets);
    expect(find.text('حساب#42'), findsWidgets);
  });

  testWidgets('exposes no editing or deleting affordance', (tester) async {
    await pumpScreen(tester);
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.edit), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'حذف'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'تعديل'), findsNothing);
  });

  testWidgets('discloses that the row cap truncated the trail', (tester) async {
    await tester.runAsync(() async {
      final db = await helper.database;
      final batch = db.batch();
      for (var i = 0; i < 600; i++) {
        batch.insert('audit_logs', {
          'user_id': 1,
          'actor_name': 'مدير النظام',
          'action': 'BULK_EVENT',
          'entity_type': 'journal_entry',
          'entity_id': i,
          'details': '{}',
          'timestamp': '2026-06-01T00:00:00',
        });
      }
      await batch.commit(noResult: true);
    });

    await pumpScreen(tester);

    // Silently showing the newest 500 rows would let a reviewer believe the
    // trail ended there, so the cap must be visible.
    expect(find.textContaining('تُعرض أحدث 500 حادثة فقط'), findsOneWidget);
  });
}
