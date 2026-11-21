import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/general_accounting/owner_settlement_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late String testDocuments;
  final helper = DatabaseHelper.instance;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'aqari_owner_settlement_ui_',
    );
    testDocuments = directory.path;
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

  Future<void> seedOwnerPayable() async {
    final db = await helper.database;
    await helper.insertOwnerWithAccount({
      'name': 'مالك شاشة اختبار',
      'commission_rate': 0,
    });
    final owner = (await db.query(
      'owners',
      where: 'name = ?',
      whereArgs: ['مالك شاشة اختبار'],
      limit: 1,
    )).single;
    final cash = (await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: ['1101'],
      limit: 1,
    )).single;
    final date = DateTime.now().subtract(const Duration(days: 1));
    final dateText =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    await helper.insertJournalEntryWithLines(
      {'entry_date': dateText, 'description': 'استحقاق للواجهة'},
      [
        {
          'account_id': cash['id'],
          'debit': 100.0,
          'credit': 0.0,
          'description': 'تمويل الاختبار',
        },
        {
          'account_id': owner['account_id'],
          'debit': 0.0,
          'credit': 100.0,
          'description': 'استحقاق المالك المرحل',
        },
      ],
    );
  }

  testWidgets('shows owner payable and available cash accounts', (
    tester,
  ) async {
    await tester.runAsync(seedOwnerPayable);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OwnerSettlementScreen())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('سداد مستحقات المالك'), findsOneWidget);
    expect(find.text('ترحيل ومعاينة سند PDF'), findsOneWidget);
    final dropdowns = find.byType(DropdownButtonFormField<int>);
    expect(dropdowns, findsNWidgets(2));

    await tester.tap(dropdowns.first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('مالك شاشة اختبار').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.textContaining('100.00'), findsWidgets);

    await tester.tap(find.byType(DropdownButtonFormField<int>).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('1101'), findsWidgets);
    await tester.tap(find.textContaining('1101').last);
    await tester.pumpAndSettle();

    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'ترحيل ومعاينة سند PDF'),
    );
    expect(submit.onPressed, isNotNull);
  });

  testWidgets('viewer without accounting post permission cannot submit', (
    tester,
  ) async {
    await tester.runAsync(seedOwnerPayable);
    PermissionRuntime.activate(
      userId: 88,
      role: 'DataEntry',
      permissionRows: [
        {
          'screen_name': 'accounting',
          'can_view': 1,
          'can_add': 1,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 0,
          'can_post': 0,
        },
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: OwnerSettlementScreen())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.textContaining('صلاحية ترحيل المحاسبة'), findsOneWidget);
    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'ترحيل ومعاينة سند PDF'),
    );
    expect(submit.onPressed, isNull);
  });
}
