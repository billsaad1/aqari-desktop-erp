import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_financial_position_report_test';
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

  test(
    'builds as-of position from posted ledger balances without a plug',
    () async {
      final db = await helper.database;
      final cash = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['1101'],
        limit: 1,
      )).single;
      final revenue = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['4101'],
        limit: 1,
      )).single;
      final expense = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['5101'],
        limit: 1,
      )).single;
      final cashId = (cash['id'] as num).toInt();
      final revenueId = (revenue['id'] as num).toInt();
      final expenseId = (expense['id'] as num).toInt();
      final equityId = await db.insert('accounts', {
        'code': '3',
        'name': 'حقوق الملكية',
        'parent_id': null,
        'account_type': 'Equity',
      });

      Future<void> post({
        required String date,
        required int debitAccountId,
        required int creditAccountId,
        required double amount,
        required bool isPosted,
      }) async {
        final entryId = await db.insert('journal_entries', {
          'entry_date': date,
          'description': 'fixture for financial position report',
          'is_posted': isPosted ? 1 : 0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': debitAccountId,
          'debit': amount,
          'credit': 0.0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': creditAccountId,
          'debit': 0.0,
          'credit': amount,
        });
      }

      await post(
        date: '2026-01-01',
        debitAccountId: cashId,
        creditAccountId: equityId,
        amount: 1000.0,
        isPosted: true,
      );
      await post(
        date: '2026-06-30T23:59:59',
        debitAccountId: cashId,
        creditAccountId: revenueId,
        amount: 200.0,
        isPosted: true,
      );
      await post(
        date: '2026-06-30',
        debitAccountId: expenseId,
        creditAccountId: cashId,
        amount: 50.0,
        isPosted: true,
      );
      await post(
        date: '2026-06-30',
        debitAccountId: cashId,
        creditAccountId: revenueId,
        amount: 500.0,
        isPosted: false,
      );
      await post(
        date: '2026-07-01',
        debitAccountId: cashId,
        creditAccountId: revenueId,
        amount: 100.0,
        isPosted: true,
      );

      final report = await helper.getFinancialPositionReport(
        asOfDate: '2026-06-30',
      );
      expect(report.asOfDate, '2026-06-30');
      expect(report.currency, isNotEmpty);
      expect(report.assetsMinor, 115000);
      expect(report.liabilitiesMinor, 0);
      expect(report.equityAccountsMinor, 100000);
      expect(report.revenuesMinor, 20000);
      expect(report.expensesMinor, 5000);
      expect(report.unclosedEarningsMinor, 15000);
      expect(report.equityIncludingUnclosedEarningsMinor, 115000);
      expect(report.equationDifferenceMinor, 0);
      expect(report.isAccountingEquationBalanced, isTrue);
      expect(report.isReadyForReview, isTrue);
      expect(report.rows.any((row) => row.debitMinor == 50000), isFalse);
      expect(report.rows.any((row) => row.accountId == cashId), isTrue);
    },
  );

  test(
    'reports unclassified balances and refuses invalid dates/permissions',
    () async {
      final db = await helper.database;
      final cash = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['1101'],
        limit: 1,
      )).single;
      final cashId = (cash['id'] as num).toInt();
      final mysteryId = await db.insert('accounts', {
        'code': '6901',
        'name': 'حساب غير مصنف للاختبار',
        'parent_id': null,
        'account_type': 'Mystery',
      });
      final journalId = await db.insert('journal_entries', {
        'entry_date': '2026-06-30',
        'description': 'unclassified posted balance',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': mysteryId,
        'debit': 25.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashId,
        'debit': 0.0,
        'credit': 25.0,
      });

      final report = await helper.getFinancialPositionReport(
        asOfDate: '2026-06-30',
      );
      expect(report.unclassifiedRows, hasLength(1));
      expect(report.unclassifiedRows.single.accountId, mysteryId);
      expect(report.hasUnclassifiedAccounts, isTrue);
      expect(report.isReadyForReview, isFalse);
      expect(report.equationDifferenceMinor, -2500);
      await expectLater(
        helper.getFinancialPositionReport(asOfDate: '2026-02-30'),
        throwsArgumentError,
      );

      PermissionRuntime.activate(
        userId: 2,
        role: 'DataEntry',
        permissionRows: const [],
      );
      await expectLater(
        helper.getFinancialPositionReport(asOfDate: '2026-06-30'),
        throwsStateError,
      );
    },
  );
}
