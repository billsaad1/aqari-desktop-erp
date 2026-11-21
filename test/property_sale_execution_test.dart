import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late String testDocuments;
  final helper = DatabaseHelper.instance;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'aqari_property_sale_execution_',
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

  test(
    'approved property sale transfers current ownership but creates no journal',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db);
      final reviewId = await _approvedReview(
        ids,
        targetType: 'property',
        unitId: null,
        proposedAmountMinor: 12500000,
      );
      final journalCountBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
      );

      final executionId = await helper.completePropertySaleExecution(
        saleReviewId: reviewId,
        buyerOwnerId: ids['buyer_id']!,
        salePriceMinor: 12500000,
        saleDate: _today(),
        deedReference: 'SALE-DEED-001',
        reason: 'تم التحقق من مستند البيع وموافقة المراجع',
      );

      final property = (await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [ids['property_id']],
      )).single;
      expect(property['owner_id'], ids['buyer_id']);
      await expectLater(
        db.update(
          'properties',
          {'owner_id': ids['seller_id']},
          where: 'id = ?',
          whereArgs: [ids['property_id']],
        ),
        throwsA(isA<DatabaseException>()),
      );
      final unit = (await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [ids['unit_id']],
      )).single;
      expect(
        unit['owner_id'],
        isNull,
        reason: 'الوحدة ترث مالك العقار بعد البيع الكامل',
      );
      final execution = (await db.query(
        'property_sale_executions',
        where: 'id = ?',
        whereArgs: [executionId],
      )).single;
      expect(execution['seller_owner_id'], ids['seller_id']);
      expect(execution['buyer_owner_id'], ids['buyer_id']);
      expect(execution['transfer_applied_at'], isNotNull);
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
        ),
        journalCountBefore,
        reason: 'إتمام البيع ينقل الملكية فقط ولا يرحل قيدًا آليًا',
      );
      final listed = (await helper.getPropertySaleReviews()).single;
      expect(listed['sale_execution_id'], executionId);
      expect(listed['sale_price_minor'], 12500000);
      expect(listed['accounting_record_id'], isNull);

      await expectLater(
        helper.cancelPropertySaleReview(
          saleReviewId: reviewId,
          reason: 'محاولة إلغاء بيع منفذ',
        ),
        throwsA(isA<DatabaseException>()),
      );
      final nextBuyerId = await db.insert('owners', {
        'name': 'مشتري لاحق ${DateTime.now().microsecondsSinceEpoch}',
      });
      final nextReview = await helper.createPropertySaleReview(
        targetType: 'property',
        propertyId: ids['property_id']!,
        reason: 'مراجعة جديدة من المالك الحالي',
        proposedBuyerOwnerId: nextBuyerId,
        proposedAmountMinor: 13500000,
        proposedSaleDate: _today(),
      );
      final nextSnapshot =
          (await db.query(
                'property_sale_reviews',
                columns: ['target_snapshot_json'],
                where: 'id = ?',
                whereArgs: [nextReview],
              )).single['target_snapshot_json']
              as String;
      expect(nextSnapshot, contains('"seller_owner_id":${ids['buyer_id']}'));
    },
  );

  test(
    'execution refuses changed buyer, price, or date after review approval',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db);
      final otherBuyerId = await db.insert('owners', {
        'name': 'مشتري بديل ${DateTime.now().microsecondsSinceEpoch}',
      });
      final reviewId = await _approvedReview(
        ids,
        targetType: 'property',
        unitId: null,
        proposedAmountMinor: 1000000,
      );

      Future<void> execute({
        int? buyerOwnerId,
        int salePriceMinor = 1000000,
        String? saleDate,
      }) async {
        await helper.completePropertySaleExecution(
          saleReviewId: reviewId,
          buyerOwnerId: buyerOwnerId ?? ids['buyer_id']!,
          salePriceMinor: salePriceMinor,
          saleDate: saleDate ?? _today(),
          deedReference: 'MISMATCH-SALE',
          reason: 'محاولة تغيير شرط معتمد',
        );
      }

      await expectLater(execute(buyerOwnerId: otherBuyerId), throwsStateError);
      await expectLater(execute(salePriceMinor: 1000001), throwsStateError);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final yesterdayText =
          '${yesterday.year.toString().padLeft(4, '0')}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      await expectLater(execute(saleDate: yesterdayText), throwsStateError);
      expect(
        _count(
          await db.rawQuery(
            'SELECT COUNT(*) AS count FROM property_sale_executions',
          ),
        ),
        0,
      );
      expect(
        (await db.query(
          'properties',
          columns: ['owner_id'],
          where: 'id = ?',
          whereArgs: [ids['property_id']],
        )).single['owner_id'],
        ids['seller_id'],
      );
    },
  );

  test(
    'unit sale changes only that unit and routes the next lease snapshot to buyer',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db);
      final reviewId = await _approvedReview(
        ids,
        targetType: 'unit',
        unitId: ids['unit_id'],
      );

      await helper.completePropertySaleExecution(
        saleReviewId: reviewId,
        buyerOwnerId: ids['buyer_id']!,
        salePriceMinor: 5000000,
        saleDate: _today(),
        deedReference: 'UNIT-SALE-001',
        reason: 'بيع الوحدة كاملة بعد المراجعة',
      );

      final property = (await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [ids['property_id']],
      )).single;
      final unit = (await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [ids['unit_id']],
      )).single;
      expect(property['owner_id'], ids['seller_id']);
      expect(unit['owner_id'], ids['buyer_id']);

      final tenantId = await db.insert('tenants', {
        'name': 'مستأجر بعد البيع',
        'mobile': '700000001',
      });
      await db.update(
        'units',
        {
          'status': 'شاغرة',
          'default_rent': 100.0,
          'default_rent_period': 'monthly',
        },
        where: 'id = ?',
        whereArgs: [ids['unit_id']],
      );
      final contractId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': ids['unit_id'],
          'start_date': '2026-12-01',
          'end_date': '2027-11-30',
          'rent_amount': 100.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': '2026-12-01',
            'status': 'Unpaid',
          },
        ],
      );
      final contract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      final partySnapshot = contract['party_snapshot'] as String;
      final buyerName = (await db.query(
        'owners',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [ids['buyer_id']],
      )).single['name'];
      expect(partySnapshot, contains('"owner_id":${ids['buyer_id']}'));
      expect(partySnapshot, contains('"name":"$buyerName"'));
    },
  );

  test(
    'sale execution is blocked when a non-cancelled lease extends beyond sale date',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db, activeContract: true);
      final reviewId = await _approvedReview(
        ids,
        targetType: 'unit',
        unitId: ids['unit_id'],
      );

      await expectLater(
        helper.completePropertySaleExecution(
          saleReviewId: reviewId,
          buyerOwnerId: ids['buyer_id']!,
          salePriceMinor: 5000000,
          saleDate: _today(),
          deedReference: 'BLOCKED-SALE',
          reason: 'محاولة البيع مع عقد نشط',
        ),
        throwsStateError,
      );
      final unit = (await db.query(
        'units',
        columns: ['owner_id'],
        where: 'id = ?',
        whereArgs: [ids['unit_id']],
      )).single;
      expect(unit['owner_id'], isNull);
      expect(
        _count(
          await db.rawQuery(
            'SELECT COUNT(*) AS count FROM property_sale_executions',
          ),
        ),
        0,
      );
    },
  );

  test(
    'whole-property sale is blocked while a unit has separate ownership',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db);
      final unitReviewId = await _approvedReview(
        ids,
        targetType: 'unit',
        unitId: ids['unit_id'],
      );
      await helper.completePropertySaleExecution(
        saleReviewId: unitReviewId,
        buyerOwnerId: ids['buyer_id']!,
        salePriceMinor: 5000000,
        saleDate: _today(),
        deedReference: 'UNIT-FIRST',
        reason: 'نقل الوحدة كاملة',
      );
      final priorExecution = (await db.query(
        'property_sale_executions',
        where: 'sale_review_id = ?',
        whereArgs: [unitReviewId],
      )).single;
      expect(priorExecution['transfer_applied_at'], isNotNull);

      final thirdOwnerId = await db.insert('owners', {
        'name': 'مشتري العقار التالي',
      });
      final propertyReviewId = await _approvedReview(
        ids,
        targetType: 'property',
        unitId: null,
        proposedBuyerOwnerId: thirdOwnerId,
        proposedAmountMinor: 15000000,
      );
      await expectLater(
        helper.completePropertySaleExecution(
          saleReviewId: propertyReviewId,
          buyerOwnerId: thirdOwnerId,
          salePriceMinor: 15000000,
          saleDate: _today(),
          deedReference: 'PROPERTY-AFTER-UNIT',
          reason: 'محاولة بيع كامل العقار بعد فصل ملكية الوحدة',
        ),
        throwsStateError,
      );
      expect(
        _count(
          await db.rawQuery(
            'SELECT COUNT(*) AS count FROM property_sale_executions',
          ),
        ),
        1,
      );
    },
  );

  test(
    'accounting approval requires a posted balanced manual journal and is append-only',
    () async {
      final db = await helper.database;
      final ids = await _seedAsset(db);
      final reviewId = await _approvedReview(
        ids,
        targetType: 'property',
        unitId: null,
        proposedAmountMinor: 12500000,
      );
      final executionId = await helper.completePropertySaleExecution(
        saleReviewId: reviewId,
        buyerOwnerId: ids['buyer_id']!,
        salePriceMinor: 12500000,
        saleDate: _today(),
        deedReference: 'ACCOUNTING-SALE-001',
        reason: 'تنفيذ بيع للاختبار',
      );
      final cashAccount = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1101'],
        limit: 1,
      )).single;
      final revenueAccount = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['4101'],
        limit: 1,
      )).single;
      final unbalancedJournalId = await db.insert('journal_entries', {
        'entry_date': _today(),
        'description': 'قيد غير متوازن للاختبار',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': unbalancedJournalId,
        'account_id': cashAccount['id'],
        'debit': 50.0,
        'credit': 0.0,
      });
      await expectLater(
        helper.recordPropertySaleAccounting(
          saleExecutionId: executionId,
          bookValueMinor: 9000000,
          manualJournalEntryId: unbalancedJournalId,
          note: 'يجب رفض القيد غير المتوازن',
        ),
        throwsStateError,
      );
      final journalId = await db.insert('journal_entries', {
        'entry_date': _today(),
        'description': 'قيد يدوي لاختبار تسوية البيع',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccount['id'],
        'debit': 100.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': revenueAccount['id'],
        'debit': 0.0,
        'credit': 100.0,
      });
      final journalCountBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
      );

      final accountingRecordId = await helper.recordPropertySaleAccounting(
        saleExecutionId: executionId,
        bookValueMinor: 9000000,
        manualJournalEntryId: journalId,
        note: 'اعتمد المحاسب القيمة الدفترية وربط القيد اليدوي المرحّل',
      );
      final record = (await db.query(
        'property_sale_accounting_records',
        where: 'id = ?',
        whereArgs: [accountingRecordId],
      )).single;
      expect(record['book_value_minor'], 9000000);
      expect(record['manual_journal_entry_id'], journalId);
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
        ),
        journalCountBefore,
        reason: 'التوثيق يربط القيد اليدوي ولا ينشئ قيدًا جديدًا',
      );
      final listed = (await helper.getPropertySaleReviews()).single;
      expect(listed['accounting_record_id'], accountingRecordId);
      expect(listed['accounting_book_value_minor'], 9000000);
      final correctionId = await helper.recordPropertySaleAccounting(
        saleExecutionId: executionId,
        bookValueMinor: 9100000,
        manualJournalEntryId: journalId,
        note: 'تصحيح موثق بعد مراجعة المستند؛ لا يمحى الاعتماد السابق',
        supersedesRecordId: accountingRecordId,
      );
      expect(correctionId, isNot(accountingRecordId));
      expect(
        _count(
          await db.rawQuery(
            'SELECT COUNT(*) AS count FROM property_sale_accounting_records WHERE sale_execution_id = ?',
            [executionId],
          ),
        ),
        2,
      );
      final correctedList = (await helper.getPropertySaleReviews()).single;
      expect(correctedList['accounting_record_id'], correctionId);
      expect(correctedList['accounting_book_value_minor'], 9100000);
      final eventTypes = (await helper.getPropertySaleReviewEvents(
        reviewId,
      )).map((event) => event['event_type']).toSet();
      expect(
        eventTypes,
        containsAll([
          'executed',
          'accounting_approved',
          'accounting_corrected',
        ]),
      );

      await expectLater(
        db.update(
          'property_sale_accounting_records',
          {'book_value_minor': 1},
          where: 'id = ?',
          whereArgs: [accountingRecordId],
        ),
        throwsA(isA<DatabaseException>()),
      );
    },
  );
}

String _today() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

int _count(List<Map<String, Object?>> rows) =>
    (rows.single['count'] as num).toInt();

Future<int> _approvedReview(
  Map<String, int> ids, {
  required String targetType,
  required int? unitId,
  int? proposedBuyerOwnerId,
  int proposedAmountMinor = 5000000,
}) async {
  final helper = DatabaseHelper.instance;
  final reviewId = await helper.createPropertySaleReview(
    targetType: targetType,
    propertyId: ids['property_id']!,
    unitId: unitId,
    reason: 'طلب بيع للاختبار مع بيانات موثقة',
    proposedBuyerOwnerId: proposedBuyerOwnerId ?? ids['buyer_id']!,
    proposedAmountMinor: proposedAmountMinor,
    proposedSaleDate: _today(),
  );
  await helper.reviewPropertySaleRequest(
    saleReviewId: reviewId,
    accept: true,
    reason: 'اعتماد نتيجة المراجعة اليدوية للاختبار',
  );
  return reviewId;
}

Future<Map<String, int>> _seedAsset(
  Database db, {
  bool activeContract = false,
}) async {
  final suffix = DateTime.now().microsecondsSinceEpoch.toString();
  final sellerId = await db.insert('owners', {'name': 'البائع $suffix'});
  final buyerId = await db.insert('owners', {'name': 'المشتري $suffix'});
  final propertyId = await db.insert('properties', {
    'name': 'عقار بيع $suffix',
    'owner_id': sellerId,
    'deed_number': 'PROPERTY-DEED-$suffix',
  });
  final unitId = await db.insert('units', {
    'property_id': propertyId,
    'unit_number': 'SALE-$suffix',
    'status': activeContract ? 'مؤجرة' : 'شاغرة',
    'default_rent': 100.0,
    'default_rent_period': 'monthly',
  });
  if (activeContract) {
    final tenantId = await db.insert('tenants', {
      'name': 'مستأجر نشط $suffix',
      'mobile': '700000002',
    });
    await db.insert('contracts', {
      'tenant_id': tenantId,
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2027-12-31',
      'rent_amount': 1200.0,
      'payment_method': 'شهري',
      'status': 'Active',
    });
  }
  return {
    'seller_id': sellerId,
    'buyer_id': buyerId,
    'property_id': propertyId,
    'unit_id': unitId,
  };
}
