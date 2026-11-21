import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_account_balance_reconciliation_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
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

  test('compares account cache to posted ledger and never auto-corrects', () async {
    final db = await helper.database;
    Future<int> accountId(String code) async =>
        ((await db.query(
                  'accounts',
                  columns: ['id'],
                  where: 'code = ?',
                  whereArgs: [code],
                  limit: 1,
                )).single['id']
                as num)
            .toInt();

    final cashId = await accountId('1101');
    final revenueId = await accountId('4101');
    final initialReport = await helper.getAccountBalanceReconciliationReport();
    final initialCashRow = initialReport.rows.singleWhere(
      (row) => row.accountId == cashId,
    );
    expect(initialCashRow.isReconciled, isTrue);

    await helper.insertJournalEntryWithLines(
      {
        'entry_date': '2026-11-01',
        'description': 'قيد اختبار مطابقة الأرصدة',
      },
      [
        {
          'account_id': cashId,
          'debit': 250.75,
          'credit': 0.0,
          'description': 'نقدية اختبار',
        },
        {
          'account_id': revenueId,
          'debit': 0.0,
          'credit': 250.75,
          'description': 'إيراد اختبار',
        },
      ],
    );

    final matchedReport = await helper.getAccountBalanceReconciliationReport();
    final matchedCashRow = matchedReport.rows.singleWhere(
      (row) => row.accountId == cashId,
    );
    final matchedRevenueRow = matchedReport.rows.singleWhere(
      (row) => row.accountId == revenueId,
    );
    expect(matchedCashRow.isReconciled, isTrue);
    expect(matchedRevenueRow.isReconciled, isTrue);
    expect(matchedReport.rows, isNotEmpty);

    await db.update(
      'accounts',
      {'balance': 250.74},
      where: 'id = ?',
      whereArgs: [cashId],
    );
    final journalCountBefore = (await db.query('journal_entries')).length;
    final lineCountBefore = (await db.query('journal_lines')).length;
    final accountCountBefore = (await db.query('accounts')).length;

    final mismatchReport = await helper.getAccountBalanceReconciliationReport();
    final cashRow = mismatchReport.rows.singleWhere(
      (row) => row.accountId == cashId,
    );
    expect(cashRow.storedBalanceMinor, 25074);
    expect(cashRow.ledgerBalanceMinor, 25075);
    expect(cashRow.differenceMinor, -1);
    expect(cashRow.isReconciled, isFalse);
    expect(mismatchReport.reviewCount, matchedReport.reviewCount + 1);
    expect((await db.query('journal_entries')).length, journalCountBefore);
    expect((await db.query('journal_lines')).length, lineCountBefore);
    expect((await db.query('accounts')).length, accountCountBefore);
    expect(
      ((await db.query(
                'accounts',
                columns: ['balance'],
                where: 'id = ?',
                whereArgs: [cashId],
              )).single['balance']
              as num)
          .toDouble(),
      250.74,
      reason: 'المطابقة تعرض الفرق ولا تعدل الرصيد المخزن',
    );
  });

  test('requires reports.view', () async {
    PermissionRuntime.activate(
      userId: 2,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await expectLater(
      helper.getAccountBalanceReconciliationReport(),
      throwsStateError,
    );
  });
}
