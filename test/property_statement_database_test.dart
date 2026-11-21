import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/property_statement_report_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 27: the property statement is a read-only view over posted journal
/// lines. A line belongs to a property only through a cost centre that the
/// property owns exclusively; everything else must be disclosed, never guessed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_property_statement_test';
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
    await helper.updateCompanyInfo({
      'name_ar': 'منشأة اختبار كشف العقار',
      'default_currency': 'SAR',
    });
  });

  tearDown(() async {
    await helper.close();
  });

  Future<int> account(String code) async {
    final db = await helper.database;
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: [code],
      limit: 1,
    );
    return rows.single['id'] as int;
  }

  Future<int> makeCostCenter(String code, String name) async {
    final db = await helper.database;
    return db.insert('cost_centers', {'code': code, 'name': name});
  }

  Future<int> makeProperty({
    required String name,
    int? costCenterId,
  }) async {
    final db = await helper.database;
    final ownerId = await db.insert('owners', {'name': 'مالك $name'});
    return db.insert('properties', {
      'name': name,
      'owner_id': ownerId,
      'cost_center_id': costCenterId,
    });
  }

  /// Posts one balanced entry so the statement has real ledger data.
  Future<int> postEntry({
    required String date,
    required int debitAccountId,
    required int creditAccountId,
    required double amount,
    int? costCenterId,
    String description = 'حركة اختبار',
  }) async {
    // Real writers attribute one side of the entry only: revenue on an invoice,
    // the receivable on a receipt. Mirroring that keeps the fixture realistic.
    final db = await helper.database;
    return db.transaction((txn) async {
      final entryId = await txn.insert('journal_entries', {
        'entry_date': date,
        'description': description,
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': debitAccountId,
        'debit': amount,
        'credit': 0.0,
        'description': description,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': creditAccountId,
        'debit': 0.0,
        'credit': amount,
        'cost_center_id': costCenterId,
        'description': description,
      });
      return entryId;
    });
  }

  group('attribution through the property cost centre', () {
    test('reports only lines carrying the property cost centre', () async {
      final center = await makeCostCenter('CC-P1', 'عقار أول');
      final propertyId = await makeProperty(name: 'عقار أول', costCenterId: center);
      final otherCenter = await makeCostCenter('CC-P2', 'عقار ثان');
      await makeProperty(name: 'عقار ثان', costCenterId: otherCenter);

      final cash = await account('1101');
      final revenue = await account('4101');
      await postEntry(
        date: '2026-03-01',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 1000.0,
        costCenterId: center,
        description: 'إيجار مارس',
      );
      await postEntry(
        date: '2026-03-02',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 500.0,
        costCenterId: otherCenter,
        description: 'إيجار عقار آخر',
      );

      final report = await helper.getPropertyStatement(
        propertyId: propertyId,
        startDate: '2026-03-01',
        endDate: '2026-03-31',
      );

      expect(report.lines, hasLength(1));
      expect(report.totalDebitMinor, 0);
      expect(report.totalCreditMinor, 100000);
      expect(report.closingBalanceMinor, -100000);
      expect(
        report.lines.every((line) => line.description.contains('مارس')),
        isTrue,
      );
    });

    test('ignores unposted entries', () async {
      final center = await makeCostCenter('CC-U1', 'عقار غير مرحل');
      final propertyId = await makeProperty(name: 'عقار غير مرحل', costCenterId: center);
      final cash = await account('1101');
      final revenue = await account('4101');
      final db = await helper.database;
      final entryId = await db.insert('journal_entries', {
        'entry_date': '2026-04-01',
        'description': 'قيد غير مرحل',
        'is_posted': 0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': cash,
        'debit': 900.0,
        'credit': 0.0,
        'cost_center_id': center,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': revenue,
        'debit': 0.0,
        'credit': 900.0,
        'cost_center_id': center,
      });

      final report = await helper.getPropertyStatement(
        propertyId: propertyId,
        startDate: '2026-04-01',
        endDate: '2026-04-30',
      );

      expect(report.lines, isEmpty);
      expect(report.totalDebitMinor, 0);
      expect(report.closingBalanceMinor, 0);
    });
  });

  group('no guessing for unattributable movements', () {
    test('a property without a cost centre discloses the gap', () async {
      final propertyId = await makeProperty(name: 'عقار بلا مركز');
      final cash = await account('1101');
      final revenue = await account('4101');
      await postEntry(
        date: '2026-05-01',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 300.0,
      );

      final report = await helper.getPropertyStatement(
        propertyId: propertyId,
        startDate: '2026-05-01',
        endDate: '2026-05-31',
      );

      expect(report.hasCostCenter, isFalse);
      expect(report.lines, isEmpty);
      expect(report.gaps, hasLength(1));
      final gap = report.gaps.single;
      expect(gap.reason, PropertyStatementGapReason.propertyWithoutCostCenter);
      expect(gap.lineCount, 2);
      expect(gap.debitMinor, 30000);
      expect(gap.creditMinor, 30000);
    });

    test('a shared cost centre is not claimed by any property', () async {
      final shared = await makeCostCenter('CC-SH', 'مركز مشترك');
      final firstId = await makeProperty(name: 'عقار مشترك أ', costCenterId: shared);
      final secondId = await makeProperty(name: 'عقار مشترك ب', costCenterId: shared);
      final cash = await account('1101');
      final revenue = await account('4101');
      await postEntry(
        date: '2026-06-01',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 700.0,
        costCenterId: shared,
      );

      for (final propertyId in [firstId, secondId]) {
        final report = await helper.getPropertyStatement(
          propertyId: propertyId,
          startDate: '2026-06-01',
          endDate: '2026-06-30',
        );
        expect(
          report.lines,
          isEmpty,
          reason: 'a shared centre must not post its lines on each property',
        );
        expect(report.totalDebitMinor, 0);
        final sharedGap = report.gaps.singleWhere(
          (gap) => gap.reason == PropertyStatementGapReason.sharedCostCenter,
        );
        expect(sharedGap.lineCount, 1);
        expect(sharedGap.debitMinor, 0);
        expect(sharedGap.creditMinor, 70000);
      }
    });
  });

  group('a voucher split across properties is never double counted', () {
    test('each property sees only its own share', () async {
      final centerA = await makeCostCenter('CC-A', 'عقار أ');
      final centerB = await makeCostCenter('CC-B', 'عقار ب');
      final propertyA = await makeProperty(name: 'عقار أ', costCenterId: centerA);
      final propertyB = await makeProperty(name: 'عقار ب', costCenterId: centerB);
      final cash = await account('1101');
      final receivable = await account('1201');

      final db = await helper.database;
      final entryId = await db.insert('journal_entries', {
        'entry_date': '2026-07-05',
        'description': 'سند قبض موزع',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': cash,
        'debit': 160.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': receivable,
        'debit': 0.0,
        'credit': 100.0,
        'cost_center_id': centerA,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': receivable,
        'debit': 0.0,
        'credit': 60.0,
        'cost_center_id': centerB,
      });

      final reportA = await helper.getPropertyStatement(
        propertyId: propertyA,
        startDate: '2026-07-01',
        endDate: '2026-07-31',
      );
      final reportB = await helper.getPropertyStatement(
        propertyId: propertyB,
        startDate: '2026-07-01',
        endDate: '2026-07-31',
      );

      expect(reportA.totalCreditMinor, 10000);
      expect(reportA.totalDebitMinor, 0);
      expect(reportB.totalCreditMinor, 6000);
      expect(reportB.totalDebitMinor, 0);
      // 100.00 + 60.00 equals the 160.00 cash line exactly: no cent counted
      // twice, and no cent lost.
      expect(
        reportA.totalCreditMinor + reportB.totalCreditMinor,
        16000,
      );
    });
  });

  group('period boundaries', () {
    test('opening balance covers prior activity and period filters the rest', () async {
      final center = await makeCostCenter('CC-PER', 'عقار الفترة');
      final propertyId = await makeProperty(name: 'عقار الفترة', costCenterId: center);
      final cash = await account('1101');
      final revenue = await account('4101');
      await postEntry(
        date: '2026-01-15',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 200.0,
        costCenterId: center,
        description: 'قبل الفترة',
      );
      await postEntry(
        date: '2026-02-10',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 250.0,
        costCenterId: center,
        description: 'داخل الفترة',
      );
      await postEntry(
        date: '2026-03-10',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 400.0,
        costCenterId: center,
        description: 'بعد الفترة',
      );

      final report = await helper.getPropertyStatement(
        propertyId: propertyId,
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );

      expect(report.openingBalanceMinor, -20000);
      expect(report.lines, hasLength(1));
      expect(report.totalDebitMinor, 0);
      expect(report.totalCreditMinor, 25000);
      expect(report.closingBalanceMinor, -45000);
      expect(
        report.lines.any((line) => line.description.contains('بعد الفترة')),
        isFalse,
      );
    });

    test('rejects an inverted or malformed period', () async {
      final center = await makeCostCenter('CC-ERR', 'عقار خطأ');
      final propertyId = await makeProperty(name: 'عقار خطأ', costCenterId: center);

      expect(
        () => helper.getPropertyStatement(
          propertyId: propertyId,
          startDate: '2026-05-31',
          endDate: '2026-05-01',
        ),
        throwsArgumentError,
      );
      expect(
        () => helper.getPropertyStatement(
          propertyId: propertyId,
          startDate: '2026-02-30',
          endDate: '2026-03-01',
        ),
        throwsArgumentError,
      );
      expect(
        () => helper.getPropertyStatement(
          propertyId: 0,
          startDate: '2026-05-01',
          endDate: '2026-05-31',
        ),
        throwsArgumentError,
      );
      expect(
        () => helper.getPropertyStatement(
          propertyId: 999999,
          startDate: '2026-05-01',
          endDate: '2026-05-31',
        ),
        throwsStateError,
      );
    });
  });

  group('read-only guarantee', () {
    test('loading the statement writes nothing', () async {
      final center = await makeCostCenter('CC-RO', 'عقار قراءة');
      final propertyId = await makeProperty(name: 'عقار قراءة', costCenterId: center);
      final cash = await account('1101');
      final revenue = await account('4101');
      await postEntry(
        date: '2026-08-01',
        debitAccountId: cash,
        creditAccountId: revenue,
        amount: 123.45,
        costCenterId: center,
      );

      final db = await helper.database;
      Future<int> count(String table) async {
        final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM $table');
        return (rows.single['total'] as num).toInt();
      }

      final before = {
        'journal_entries': await count('journal_entries'),
        'journal_lines': await count('journal_lines'),
        'accounts': await count('accounts'),
        'properties': await count('properties'),
        'cost_centers': await count('cost_centers'),
      };

      await helper.getPropertyStatement(
        propertyId: propertyId,
        startDate: '2026-08-01',
        endDate: '2026-08-31',
      );

      final after = {
        'journal_entries': await count('journal_entries'),
        'journal_lines': await count('journal_lines'),
        'accounts': await count('accounts'),
        'properties': await count('properties'),
        'cost_centers': await count('cost_centers'),
      };
      expect(after, before);
    });
  });

  group('permissions', () {
    test('view permission is required to read the statement', () async {
      final center = await makeCostCenter('CC-PERM', 'عقار صلاحية');
      final propertyId = await makeProperty(name: 'عقار صلاحية', costCenterId: center);
      PermissionRuntime.activate(
        userId: 55,
        role: 'DataEntry',
        permissionRows: const [],
      );

      expect(
        () => helper.getPropertyStatement(
          propertyId: propertyId,
          startDate: '2026-01-01',
          endDate: '2026-01-31',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
