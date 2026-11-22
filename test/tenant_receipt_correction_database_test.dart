import 'dart:convert';
import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/internal_subledger_reconciliation_report_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_tenant_receipt_correction_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
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

  Future<Map<String, Object?>> createReceiptFixture() async {
    final db = await helper.database;
    await helper.insertTenantWithAccount({
      'name': 'مستأجر تصحيح سند',
      'mobile': '779199001',
    });
    final tenant = (await db.query(
      'tenants',
      columns: ['id', 'name', 'account_id'],
      where: 'name = ?',
      whereArgs: ['مستأجر تصحيح سند'],
      limit: 1,
    )).single;
    final cash = (await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: ['1101'],
      limit: 1,
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك تصحيح سند'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار تصحيح سند',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'CR-1',
      'status': 'مؤجرة',
    });
    final contractId = await db.insert('contracts', {
      'tenant_id': tenant['id'],
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2026-12-31',
      'rent_amount': 200.0,
      'status': 'Active',
    });
    final originalInstallmentId = await db.insert('contract_installments', {
      'contract_id': contractId,
      'amount': 100.0,
      'paid_amount': 100.0,
      'due_date': '2026-01-01',
      'status': 'Paid',
    });
    final replacementInstallmentId = await db.insert('contract_installments', {
      'contract_id': contractId,
      'amount': 100.0,
      'paid_amount': 0.0,
      'due_date': '2026-02-01',
      'status': 'Unpaid',
    });
    final journalId = await db.insert('journal_entries', {
      'entry_date': '2026-02-10',
      'description': 'بيان أصلي غير صحيح',
      'is_posted': 1,
    });
    await db.insert('journal_lines', {
      'journal_entry_id': journalId,
      'account_id': cash['id'],
      'debit': 100.0,
      'credit': 0.0,
      'description': 'بيان أصلي غير صحيح',
    });
    await db.insert('journal_lines', {
      'journal_entry_id': journalId,
      'account_id': tenant['account_id'],
      'debit': 0.0,
      'credit': 100.0,
      'description': 'بيان أصلي غير صحيح',
    });
    final sourceVoucherId = await db.insert('vouchers', {
      'voucher_type': 'قبض مستأجر',
      'voucher_date': '2026-02-10',
      'amount': 100.0,
      'tenant_id': tenant['id'],
      'party_name': tenant['name'],
      'journal_entry_id': journalId,
      'description': 'بيان أصلي غير صحيح',
    });
    await db.insert('voucher_installment_allocations', {
      'voucher_id': sourceVoucherId,
      'installment_id': originalInstallmentId,
      'amount': 100.0,
    });
    final sourceAllocationId = await db.insert('collection_allocations', {
      'voucher_id': sourceVoucherId,
      'installment_id': originalInstallmentId,
      'invoice_id': null,
      'amount_minor': 10000,
      'rent_amount_minor': 10000,
      'tax_amount_minor': 0,
    });
    return {
      'db': db,
      'tenant': tenant,
      'contract_id': contractId,
      'cash_account_id': (cash['id'] as num).toInt(),
      'tenant_account_id': (tenant['account_id'] as num).toInt(),
      'source_voucher_id': sourceVoucherId,
      'source_journal_id': journalId,
      'source_allocation_id': sourceAllocationId,
      'original_installment_id': originalInstallmentId,
      'replacement_installment_id': replacementInstallmentId,
    };
  }

  test(
    'corrects description with an audit trail and atomically replaces a receipt without a cash refund',
    () async {
      final fixture = await createReceiptFixture();
      final db = fixture['db'] as dynamic;
      final sourceId = fixture['source_voucher_id'] as int;
      final originalJournalId = fixture['source_journal_id'] as int;
      final oldDescription = 'بيان أصلي غير صحيح';

      await helper.correctTenantReceiptVoucherDescription(
        voucherId: sourceId,
        newDescription: 'إيجار شهر يناير',
        reason: 'تصحيح وصف مكتوب خطأ',
      );
      final audit = (await db.query(
        'audit_logs',
        where: 'action = ? AND entity_id = ?',
        whereArgs: ['TENANT_RECEIPT_DESCRIPTION_CORRECTED', sourceId],
        limit: 1,
      )).single;
      final auditDetails = jsonDecode(audit['details'] as String);
      expect(auditDetails['old_description'], oldDescription);
      expect(auditDetails['new_description'], 'إيجار شهر يناير');
      expect(auditDetails['reason'], 'تصحيح وصف مكتوب خطأ');
      expect(
        (await db.query(
          'journal_lines',
          columns: ['description'],
          where: 'journal_entry_id = ?',
          whereArgs: [originalJournalId],
        )).map((line) => line['description']).toSet(),
        {'إيجار شهر يناير'},
      );

      final eligible = await helper.getTenantReceiptCorrectionInstallments(
        sourceId,
      );
      expect(
        eligible.map((row) => row['installment_id']),
        contains(fixture['replacement_installment_id']),
      );

      // Force a failure after reversal, replacement and allocation inserts have
      // started. SQLite must roll the complete correction transaction back.
      await db.execute('''
        CREATE TRIGGER test_fail_receipt_correction
        BEFORE INSERT ON tenant_receipt_corrections
        BEGIN
          SELECT RAISE(ABORT, 'injected correction failure');
        END
      ''');
      await expectLater(
        helper.correctTenantReceiptVoucher(
          sourceVoucherId: sourceId,
          replacementInstallmentId:
              fixture['replacement_installment_id'] as int,
          correctedAmount: 75.0,
          correctionDate: '2026-05-01',
          description: 'سند بديل مضبوط',
          reason: 'المبلغ المدفوع الصحيح سبعون وخمسة',
        ),
        throwsA(anything),
      );
      await db.execute('DROP TRIGGER test_fail_receipt_correction');
      expect((await db.query('tenant_receipt_corrections')).length, 0);
      expect(
        (await db.query(
          'vouchers',
          where: "voucher_type = 'عكس قبض مستأجر'",
        )).length,
        0,
      );
      expect(
        (await db.query('vouchers')).length,
        1,
        reason: 'لا يُترك عكس أو سند بديل جزئي بعد فشل العملية',
      );

      final replacementId = await helper.correctTenantReceiptVoucher(
        sourceVoucherId: sourceId,
        replacementInstallmentId: fixture['replacement_installment_id'] as int,
        correctedAmount: 75.0,
        correctionDate: '2026-05-01',
        description: 'سند بديل مضبوط',
        reason: 'المبلغ المدفوع الصحيح سبعون وخمسة',
      );
      final correction = (await db.query(
        'tenant_receipt_corrections',
        where: 'source_receipt_voucher_id = ?',
        whereArgs: [sourceId],
        limit: 1,
      )).single;
      final reversalId = (correction['reversal_voucher_id'] as num).toInt();
      expect(
        (correction['replacement_receipt_voucher_id'] as num).toInt(),
        replacementId,
      );

      final source = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [sourceId],
        limit: 1,
      )).single;
      expect(source['amount'], 100.0);
      expect(source['journal_entry_id'], originalJournalId);
      final reversal = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [reversalId],
        limit: 1,
      )).single;
      expect(reversal['voucher_type'], 'عكس قبض مستأجر');
      expect(reversal['amount'], 100.0);
      final replacement = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [replacementId],
        limit: 1,
      )).single;
      expect(replacement['voucher_type'], 'قبض مستأجر');
      expect(replacement['amount'], 75.0);
      expect(
        (await db.query(
          'refund_allocations',
        )).where((row) => row['refund_voucher_id'] == reversalId),
        isEmpty,
      );

      final installmentRows = await db.query(
        'contract_installments',
        columns: ['id', 'paid_amount'],
        where: 'id IN (?, ?)',
        whereArgs: [
          fixture['original_installment_id'],
          fixture['replacement_installment_id'],
        ],
      );
      final paidByInstallment = {
        for (final row in installmentRows)
          (row['id'] as num).toInt(): (row['paid_amount'] as num).toDouble(),
      };
      expect(paidByInstallment[fixture['original_installment_id']], 0.0);
      expect(paidByInstallment[fixture['replacement_installment_id']], 75.0);

      await expectLater(
        helper.correctTenantReceiptVoucher(
          sourceVoucherId: sourceId,
          replacementInstallmentId:
              fixture['replacement_installment_id'] as int,
          correctedAmount: 75.0,
          correctionDate: '2026-05-02',
          description: 'محاولة تكرار',
          reason: 'يجب رفض التصحيح المتكرر',
        ),
        throwsA(anything),
      );
      expect((await db.query('tenant_receipt_corrections')).length, 1);

      final report = await helper.getTenantCollectionReport(
        startDate: '2026-01-01',
        endDate: '2026-05-01',
      );
      final reversalRow = report.rows.singleWhere(
        (row) => row.voucherId == reversalId,
      );
      expect(reversalRow.isCorrectionReversal, isTrue);
      expect(reversalRow.isRefund, isFalse);
      expect(reversalRow.isVerifiedCorrectionReversal, isTrue);
      expect(reversalRow.amountMinor, -10000);
      expect(reversalRow.sourceReceiptVoucherIds, '$sourceId');
      expect(reversalRow.replacementReceiptVoucherId, replacementId);
      expect(reversalRow.correctionReason, 'المبلغ المدفوع الصحيح سبعون وخمسة');
      expect(report.linkedReceiptCorrectionsMinor, 10000);
      expect(report.linkedRefundsMinor, 0);

      final reconciliation = await helper
          .getInternalSubledgerReconciliationReport(
            startDate: '2026-01-01',
            endDate: '2026-05-01',
          );
      final correctionReconciliationRow = reconciliation.rows.singleWhere(
        (row) =>
            row.source ==
                InternalSubledgerSource.tenantReceiptCorrectionReversal &&
            row.sourceId == reversalId,
      );
      expect(correctionReconciliationRow.isLedgerMatched, isTrue);
      expect(correctionReconciliationRow.correctionSourceVoucherId, sourceId);
      expect(
        correctionReconciliationRow.correctionReversalVoucherId,
        reversalId,
      );
      expect(
        correctionReconciliationRow.correctionReplacementVoucherId,
        replacementId,
      );
      expect(correctionReconciliationRow.issueSummary, contains('غير نقدي'));

      final beforeCorrection = await helper.getTenantAgingReport(
        asOfDate: '2026-04-30',
      );
      expect(
        beforeCorrection.rows.any(
          (row) => row.installmentId == fixture['original_installment_id'],
        ),
        isFalse,
        reason:
            'قبل تاريخ العكس يظل القسط الأصلي مسددًا كما كان في ذلك التاريخ',
      );
      final beforeTarget = beforeCorrection.rows.singleWhere(
        (row) => row.installmentId == fixture['replacement_installment_id'],
      );
      expect(beforeTarget.balanceMinor, 10000);

      final afterCorrection = await helper.getTenantAgingReport(
        asOfDate: '2026-05-01',
      );
      final originalAgingRow = afterCorrection.rows.singleWhere(
        (row) => row.installmentId == fixture['original_installment_id'],
      );
      final replacementAgingRow = afterCorrection.rows.singleWhere(
        (row) => row.installmentId == fixture['replacement_installment_id'],
      );
      expect(originalAgingRow.balanceMinor, 10000);
      expect(replacementAgingRow.paidMinor, 7500);
      expect(replacementAgingRow.balanceMinor, 2500);

      // A balanced journal with the same totals but the original direction is
      // not a valid accounting reversal and must not alter historical reports.
      final invalidReversalJournalId = await db.insert('journal_entries', {
        'entry_date': '2026-05-01',
        'description': 'قيد متوازن لكنه ليس عكسًا للأصل',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': invalidReversalJournalId,
        'account_id': fixture['cash_account_id'],
        'debit': 100.0,
        'credit': 0.0,
        'description': 'قيد باتجاه الأصل',
      });
      await db.insert('journal_lines', {
        'journal_entry_id': invalidReversalJournalId,
        'account_id': fixture['tenant_account_id'],
        'debit': 0.0,
        'credit': 100.0,
        'description': 'قيد باتجاه الأصل',
      });
      await db.update(
        'vouchers',
        {'journal_entry_id': invalidReversalJournalId},
        where: 'id = ?',
        whereArgs: [reversalId],
      );

      final auditReport = await helper.getTenantCollectionReport(
        startDate: '2026-01-01',
        endDate: '2026-05-01',
      );
      final unverifiedReversal = auditReport.rows.singleWhere(
        (row) => row.voucherId == reversalId,
      );
      expect(unverifiedReversal.isVerifiedCorrectionReversal, isFalse);
      expect(auditReport.linkedReceiptCorrectionsMinor, 0);
      expect(auditReport.unverifiedCorrectionReversalsMinor, 10000);
      expect(auditReport.netCollectedMinor, 17500);

      final auditAging = await helper.getTenantAgingReport(
        asOfDate: '2026-05-01',
      );
      expect(
        auditAging.rows.any(
          (row) => row.installmentId == fixture['original_installment_id'],
        ),
        isFalse,
        reason: 'لا يخصم من القسط إلا عكس يطابق حسابات قيد الأصل',
      );
      expect(
        auditAging.rows
            .singleWhere(
              (row) =>
                  row.installmentId == fixture['replacement_installment_id'],
            )
            .paidMinor,
        7500,
      );
    },
  );

  test(
    'does not certify correction when legacy and detailed allocations diverge',
    () async {
      final fixture = await createReceiptFixture();
      final db = fixture['db'] as dynamic;
      final sourceId = fixture['source_voucher_id'] as int;
      final originalInstallmentId = fixture['original_installment_id'] as int;
      await helper.correctTenantReceiptVoucher(
        sourceVoucherId: sourceId,
        replacementInstallmentId: fixture['replacement_installment_id'] as int,
        correctedAmount: 75.0,
        correctionDate: '2026-05-01',
        description: 'سند بديل مضبوط',
        reason: 'اختبار اتساق السجلين',
      );

      await db.update(
        'voucher_installment_allocations',
        {'amount': 99.0},
        where: 'voucher_id = ? AND installment_id = ?',
        whereArgs: [sourceId, originalInstallmentId],
      );
      final queryPlan = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT COUNT(*) FROM vouchers WHERE journal_entry_id = ?',
        [fixture['source_journal_id']],
      );
      expect(
        queryPlan.map((row) => row['detail'].toString()).join(' '),
        contains('idx_vouchers_journal_entry'),
      );

      final collection = await helper.getTenantCollectionReport(
        startDate: '2026-01-01',
        endDate: '2026-05-01',
      );
      final reversal = collection.rows.singleWhere(
        (row) => row.isCorrectionReversal,
      );
      expect(reversal.isVerifiedCorrectionReversal, isFalse);
      expect(collection.linkedReceiptCorrectionsMinor, 0);
      expect(collection.unverifiedCorrectionReversalsMinor, 10000);

      final aging = await helper.getTenantAgingReport(asOfDate: '2026-05-01');
      expect(
        aging.exceptions.any(
          (row) =>
              row.documentType == 'عكس تصحيح قبض' &&
              row.reason.contains('غير مكتملة أو غير متسقة'),
        ),
        isTrue,
      );
    },
  );

  test(
    'does not certify a reversal dated before its source after later edits',
    () async {
      final fixture = await createReceiptFixture();
      final db = fixture['db'] as dynamic;
      final sourceId = fixture['source_voucher_id'] as int;
      final replacementId = await helper.correctTenantReceiptVoucher(
        sourceVoucherId: sourceId,
        replacementInstallmentId: fixture['replacement_installment_id'] as int,
        correctedAmount: 75.0,
        correctionDate: '2026-05-01',
        description: 'سند بديل مضبوط',
        reason: 'اختبار ترتيب التواريخ',
      );
      final correction = (await db.query(
        'tenant_receipt_corrections',
        where: 'source_receipt_voucher_id = ?',
        whereArgs: [sourceId],
        limit: 1,
      )).single;
      final reversalId = (correction['reversal_voucher_id'] as num).toInt();
      final reversal = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [reversalId],
        limit: 1,
      )).single;
      final replacement = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [replacementId],
        limit: 1,
      )).single;
      for (final voucher in [reversal, replacement]) {
        await db.update(
          'vouchers',
          {'voucher_date': '2026-02-09'},
          where: 'id = ?',
          whereArgs: [voucher['id']],
        );
        await db.update(
          'journal_entries',
          {'entry_date': '2026-02-09'},
          where: 'id = ?',
          whereArgs: [voucher['journal_entry_id']],
        );
      }

      final collection = await helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );
      final reversalRow = collection.rows.singleWhere(
        (row) => row.voucherId == reversalId,
      );
      expect(reversalRow.isVerifiedCorrectionReversal, isFalse);
      expect(collection.linkedReceiptCorrectionsMinor, 0);
      expect(collection.unverifiedCorrectionReversalsMinor, 10000);

      final aging = await helper.getTenantAgingReport(asOfDate: '2026-02-28');
      expect(
        aging.exceptions.any(
          (row) =>
              row.documentType == 'عكس تصحيح قبض' &&
              row.reason.contains('غير مكتملة أو غير متسقة'),
        ),
        isTrue,
      );
    },
  );

  test(
    'rejects a receipt linked to an invoice without partial changes',
    () async {
      final fixture = await createReceiptFixture();
      final db = fixture['db'] as dynamic;
      final invoiceId = await db.insert('tax_invoices', {
        'contract_id': fixture['contract_id'],
        'installment_id': fixture['original_installment_id'],
        'invoice_date': '2026-01-01',
        'net_amount': 100.0,
        'tax_amount': 15.0,
        'total_amount': 115.0,
        'tax_rate': 15.0,
      });
      expect(invoiceId, greaterThan(0));

      await expectLater(
        helper.correctTenantReceiptVoucher(
          sourceVoucherId: fixture['source_voucher_id'] as int,
          replacementInstallmentId:
              fixture['replacement_installment_id'] as int,
          correctedAmount: 75.0,
          correctionDate: '2026-05-01',
          description: 'بديل لا يجب إنشاؤه',
          reason: 'مسار الفواتير الضريبية غير مدعوم',
        ),
        throwsA(isA<StateError>()),
      );
      expect((await db.query('tenant_receipt_corrections')), isEmpty);
      expect((await db.query('vouchers')).length, 1);
      expect((await db.query('journal_entries')).length, 1);
    },
  );

  test('rejects a receipt with a prior cash refund', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final refundId = await helper.insertTenantRefundVoucher(
      tenantId: (fixture['tenant'] as Map)['id'] as int,
      amount: 25.0,
      voucherDate: '2026-03-01',
      cashAccountId: fixture['cash_account_id'] as int,
      collectionAllocationId: fixture['source_allocation_id'] as int,
      description: 'استرداد فعلي سابق',
    );

    await expectLater(
      helper.correctTenantReceiptVoucher(
        sourceVoucherId: fixture['source_voucher_id'] as int,
        replacementInstallmentId: fixture['replacement_installment_id'] as int,
        correctedAmount: 75.0,
        correctionDate: '2026-05-01',
        description: 'بديل لا يجب إنشاؤه',
        reason: 'السند سبق استرداد جزء منه',
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      (await db.query(
        'refund_allocations',
        where: 'refund_voucher_id = ?',
        whereArgs: [refundId],
      )),
      hasLength(1),
    );
    expect((await db.query('tenant_receipt_corrections')), isEmpty);
    expect((await db.query('vouchers')).length, 2);
  });

  test(
    'rejects a correction dated inside a locked accounting period',
    () async {
      final fixture = await createReceiptFixture();
      final db = fixture['db'] as dynamic;
      final period = await helper.createAccountingPeriod(
        startDate: '2026-05-01',
        endDate: '2026-05-31',
      );
      await helper.lockAccountingPeriod(period.id, reason: 'اختبار قفل الفترة');

      await expectLater(
        helper.correctTenantReceiptVoucher(
          sourceVoucherId: fixture['source_voucher_id'] as int,
          replacementInstallmentId:
              fixture['replacement_installment_id'] as int,
          correctedAmount: 75.0,
          correctionDate: '2026-05-01',
          description: 'بديل لا يجب إنشاؤه',
          reason: 'التاريخ يقع داخل فترة مقفلة',
        ),
        throwsA(isA<StateError>()),
      );
      expect((await db.query('tenant_receipt_corrections')), isEmpty);
      expect((await db.query('vouchers')).length, 1);
      expect((await db.query('journal_entries')).length, 1);
    },
  );
}
