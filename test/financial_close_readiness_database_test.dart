import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_financial_close_readiness_test';
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

  test(
    'detects unposted, unbalanced, and line-less entries in the period',
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
      final cashId = (cash['id'] as num).toInt();
      final revenueId = (revenue['id'] as num).toInt();

      Future<int> createEntry({
        required String date,
        required String description,
        required bool posted,
      }) => db.insert('journal_entries', {
        'entry_date': date,
        'description': description,
        'is_posted': posted ? 1 : 0,
      });

      Future<void> addLine(
        int journalId,
        int accountId, {
        double debit = 0,
        double credit = 0,
      }) async {
        await db.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': accountId,
          'debit': debit,
          'credit': credit,
        });
      }

      final validId = await createEntry(
        date: '2026-06-01',
        description: 'balanced posted entry',
        posted: true,
      );
      await addLine(validId, cashId, debit: 100);
      await addLine(validId, revenueId, credit: 100);

      final draftId = await createEntry(
        date: '2026-06-30T23:59:59',
        description: 'draft must be reviewed',
        posted: false,
      );
      await addLine(draftId, cashId, debit: 25);
      await addLine(draftId, revenueId, credit: 20);

      final unbalancedId = await createEntry(
        date: '2026-06-15',
        description: 'posted imbalance',
        posted: true,
      );
      await addLine(unbalancedId, cashId, debit: 10);
      await addLine(unbalancedId, revenueId, credit: 8);

      final emptyPostedId = await createEntry(
        date: '2026-06-20',
        description: 'posted without lines',
        posted: true,
      );

      final outsideDraftId = await createEntry(
        date: '2026-07-01',
        description: 'outside period',
        posted: false,
      );
      await addLine(outsideDraftId, cashId, debit: 3);

      final report = await helper.getFinancialCloseReadinessReport(
        startDate: '2026-06-01',
        endDate: '2026-06-30',
      );

      expect(report.startDate, '2026-06-01');
      expect(report.endDate, '2026-06-30');
      expect(report.currency, isNotEmpty);
      expect(report.unpostedEntries, hasLength(1));
      expect(report.unpostedEntries.single.journalEntryId, draftId);
      expect(report.unpostedEntries.single.debitMinor, 2500);
      expect(report.unpostedEntries.single.creditMinor, 2000);
      expect(report.unpostedDebitMinor, 2500);
      expect(report.unpostedCreditMinor, 2000);
      expect(report.unbalancedPostedEntries, hasLength(2));
      expect(
        report.unbalancedPostedEntries.map((entry) => entry.journalEntryId),
        containsAll([unbalancedId, emptyPostedId]),
      );
      expect(
        report.unbalancedPostedEntries
            .singleWhere((entry) => entry.journalEntryId == unbalancedId)
            .differenceMinor,
        200,
      );
      expect(
        report.unbalancedPostedEntries
            .singleWhere((entry) => entry.journalEntryId == emptyPostedId)
            .hasNoLines,
        isTrue,
      );
      expect(report.hasBlockingIssues, isTrue);
      expect(report.isReadyForManualReview, isFalse);
    },
  );

  test(
    'returns no issues for a balanced period and validates date/permission',
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
      final entryId = await db.insert('journal_entries', {
        'entry_date': '2026-01-31',
        'description': 'balanced period edge',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': (cash['id'] as num).toInt(),
        'debit': 12.34,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': (revenue['id'] as num).toInt(),
        'debit': 0.0,
        'credit': 12.34,
      });

      final report = await helper.getFinancialCloseReadinessReport(
        startDate: '2026-01-01',
        endDate: '2026-01-31',
      );
      expect(report.unpostedEntries, isEmpty);
      expect(report.unbalancedPostedEntries, isEmpty);
      expect(report.isReadyForManualReview, isTrue);
      await expectLater(
        helper.getFinancialCloseReadinessReport(
          startDate: '2026-02-30',
          endDate: '2026-03-01',
        ),
        throwsArgumentError,
      );
      await expectLater(
        helper.getFinancialCloseReadinessReport(
          startDate: '2026-03-01',
          endDate: '2026-02-01',
        ),
        throwsArgumentError,
      );

      PermissionRuntime.activate(
        userId: 2,
        role: 'DataEntry',
        permissionRows: const [],
      );
      await expectLater(
        helper.getFinancialCloseReadinessReport(
          startDate: '2026-01-01',
          endDate: '2026-01-31',
        ),
        throwsStateError,
      );
    },
  );
}
