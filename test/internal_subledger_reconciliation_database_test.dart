import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/internal_subledger_reconciliation_report_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_internal_subledger_reconciliation_test';
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
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
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

  Future<int> accountId(dynamic db, String code) async =>
      ((await db.query(
                'accounts',
                columns: ['id'],
                where: 'code = ?',
                whereArgs: [code],
                limit: 1,
              )).single['id']
              as num)
          .toInt();

  Future<Map<String, Object?>> makeLease(dynamic db) async {
    await helper.insertTenantWithAccount({
      'name': 'مستأجر المطابقة الداخلية',
      'mobile': '779340001',
    });
    final tenant = (await db.query(
      'tenants',
      columns: ['id', 'name', 'account_id'],
      where: 'name = ?',
      whereArgs: ['مستأجر المطابقة الداخلية'],
      limit: 1,
    )).single;
    final ownerId = await db.insert('owners', {
      'name': 'مالك المطابقة الداخلية',
    });
    final propertyId = await db.insert('properties', {
      'name': 'عقار المطابقة الداخلية',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'IR-01',
      'status': 'مؤجرة',
    });
    final contractId = await db.insert('contracts', {
      'tenant_id': tenant['id'],
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2026-12-31',
      'rent_amount': 100.0,
      'status': 'Active',
    });
    final installmentId = await db.insert('contract_installments', {
      'contract_id': contractId,
      'amount': 100.0,
      'paid_amount': 0.0,
      'due_date': '2026-01-01',
      'status': 'Unpaid',
    });
    final invoiceId = await helper.insertTaxInvoice(
      contractId: contractId,
      tenantId: (tenant['id'] as num).toInt(),
      installmentId: installmentId,
      invoiceDate: '2026-01-01',
      netAmount: 100.0,
      taxAmount: 15.0,
      revenueAccountId: await accountId(db, '4101'),
      taxAccountId: await accountId(db, '2103'),
    );
    return {
      ...tenant,
      'contract_id': contractId,
      'unit_id': unitId,
      'installment_id': installmentId,
      'invoice_id': invoiceId,
    };
  }

  String dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  test(
    'reconciles linked subledger documents, separates unapplied receipts, and surfaces source-less journals',
    () async {
      final db = await helper.database;
      await db.update('company_info', {'tax_rate': 15.0});
      final lease = await makeLease(db);
      final tenantId = (lease['id'] as num).toInt();
      final invoiceId = (lease['invoice_id'] as num).toInt();

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: tenantId,
        amount: 115.0,
        voucherDate: '2026-01-05',
        cashAccountId: await accountId(db, '1101'),
        installmentsToUpdate: const [],
        invoiceId: invoiceId,
      );
      final sourceAllocation = (await db.query(
        'collection_allocations',
        columns: ['id'],
        where: 'voucher_id = ?',
        whereArgs: [receiptId],
        limit: 1,
      )).single;

      final noteId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-10',
        totalAmountMinor: 5000,
        reason: 'تخفيض موثق للاختبار',
      );
      await helper.postCreditNote(noteId);
      final reversibleNoteId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-11',
        totalAmountMinor: 2500,
        reason: 'إشعار مستقل لاختبار العكس',
      );
      await helper.postCreditNote(reversibleNoteId);
      await helper.reverseCreditNote(
        reversibleNoteId,
        reversalDate: '2026-01-12',
        reason: 'اختبار عكس موثق',
      );
      final refundId = await helper.insertTenantRefundVoucher(
        tenantId: tenantId,
        amount: 50.0,
        voucherDate: '2026-01-15',
        cashAccountId: await accountId(db, '1101'),
        collectionAllocationId: (sourceAllocation['id'] as num).toInt(),
        description: 'رد مرتبط بالإشعار ومصدر القبض',
        creditNoteId: noteId,
      );

      final tenantAccountId = (lease['account_id'] as num).toInt();
      final cashAccountId = await accountId(db, '1101');
      await db.execute('DROP TRIGGER collection_allocations_voucher_valid');
      await db.execute('DROP TRIGGER refund_allocations_voucher_match');
      final missingSourceReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-01-16',
        'amount': 10.0,
        'tenant_id': tenantId,
        'party_name': lease['name'],
        'description': 'مصدر تاريخي بلا قيد للاختبار',
      });
      final missingSourceAllocationId = await db.insert(
        'collection_allocations',
        {
          'voucher_id': missingSourceReceiptId,
          'installment_id': lease['installment_id'],
          'amount_minor': 1000,
          'rent_amount_minor': 1000,
          'tax_amount_minor': 0,
        },
      );
      final missingSourceRefundJournalId = await db.insert('journal_entries', {
        'entry_date': '2026-01-17',
        'description': 'قيد رد له مصدر قبض تاريخي بلا قيد',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': missingSourceRefundJournalId,
        'account_id': tenantAccountId,
        'debit': 10.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': missingSourceRefundJournalId,
        'account_id': cashAccountId,
        'debit': 0.0,
        'credit': 10.0,
      });
      final missingSourceRefundId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2026-01-17',
        'amount': 10.0,
        'tenant_id': tenantId,
        'party_name': lease['name'],
        'journal_entry_id': missingSourceRefundJournalId,
        'description': 'رد تاريخي بلا قيد مصدر للاختبار',
      });
      await db.insert('refund_allocations', {
        'refund_voucher_id': missingSourceRefundId,
        'collection_allocation_id': missingSourceAllocationId,
        'amount_minor': 1000,
        'rent_amount_minor': 1000,
        'tax_amount_minor': 0,
      });
      final unallocatedJournalId = await db.insert('journal_entries', {
        'entry_date': '2026-01-18',
        'description': 'قبض مستأجر غير مخصص للاختبار',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': unallocatedJournalId,
        'account_id': cashAccountId,
        'debit': 20.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': unallocatedJournalId,
        'account_id': tenantAccountId,
        'debit': 0.0,
        'credit': 20.0,
      });
      await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-01-18',
        'amount': 20.0,
        'tenant_id': tenantId,
        'party_name': lease['name'],
        'journal_entry_id': unallocatedJournalId,
        'description': 'قبض غير مخصص للاختبار',
      });

      await helper.insertOwnerWithAccount({
        'name': 'مالك اختبار المطابقة',
        'commission_rate': 0,
      });
      final owner = (await db.query(
        'owners',
        where: 'name = ?',
        whereArgs: ['مالك اختبار المطابقة'],
        limit: 1,
      )).single;
      final ownerId = (owner['id'] as num).toInt();
      final ownerAccountId = (owner['account_id'] as num).toInt();
      final assetOffsetId = await db.insert('accounts', {
        'code': '129991',
        'name': 'أصل تمويل مالك اختبار المطابقة',
        'parent_id': await accountId(db, '1201'),
        'account_type': 'Asset',
        'balance': 0.0,
      });
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await helper.insertJournalEntryWithLines(
        {
          'entry_date': dateOnly(yesterday),
          'description': 'إثبات استحقاق المالك للاختبار',
        },
        [
          {
            'account_id': assetOffsetId,
            'debit': 100.0,
            'credit': 0.0,
            'description': 'تمويل أصل الاختبار',
          },
          {
            'account_id': ownerAccountId,
            'debit': 0.0,
            'credit': 100.0,
            'description': 'استحقاق المالك للاختبار',
          },
        ],
      );
      await helper.insertOwnerSettlementVoucher(
        ownerId: ownerId,
        amountMinor: 2500,
        settlementDate: dateOnly(DateTime.now()),
        cashAccountId: cashAccountId,
        description: 'سداد مستحقات المالك للاختبار',
      );

      final unmatchedJournalId = await helper.insertJournalEntryWithLines(
        {
          'entry_date': '2026-01-20',
          'description': 'قيد يدوي على ذمم المستأجر بلا مستند مصدر',
        },
        [
          {
            'account_id': tenantAccountId,
            'debit': 3.0,
            'credit': 0.0,
            'description': 'فرق يدوي للاختبار',
          },
          {
            'account_id': await accountId(db, '4101'),
            'debit': 0.0,
            'credit': 3.0,
            'description': 'مقابل يدوي للاختبار',
          },
        ],
      );

      final report = await helper.getInternalSubledgerReconciliationReport(
        startDate: '2026-01-01',
        endDate: dateOnly(DateTime.now()),
      );
      InternalSubledgerReconciliationRow findRow(
        InternalSubledgerSource source,
        int id,
      ) => report.rows.singleWhere(
        (row) => row.source == source && row.sourceId == id,
      );

      final invoiceRow = findRow(InternalSubledgerSource.invoice, invoiceId);
      expect(invoiceRow.state, InternalSubledgerRowState.matched);
      final receiptRow = findRow(
        InternalSubledgerSource.tenantReceipt,
        receiptId,
      );
      expect(receiptRow.state, InternalSubledgerRowState.matched);
      expect(receiptRow.allocationStatus, 'مخصص بالكامل');
      final noteRow = findRow(InternalSubledgerSource.creditNote, noteId);
      expect(noteRow.state, InternalSubledgerRowState.matched);
      final reversedNoteRow = findRow(
        InternalSubledgerSource.creditNote,
        reversibleNoteId,
      );
      expect(reversedNoteRow.state, InternalSubledgerRowState.matched);
      final reversalRow = findRow(
        InternalSubledgerSource.creditNoteReversal,
        reversibleNoteId,
      );
      expect(reversalRow.state, InternalSubledgerRowState.matched);
      final januaryReport = await helper
          .getInternalSubledgerReconciliationReport(
            startDate: '2026-01-01',
            endDate: '2026-01-31',
          );
      final januaryReversalRow = januaryReport.rows.singleWhere(
        (row) =>
            row.source == InternalSubledgerSource.creditNoteReversal &&
            row.sourceId == reversibleNoteId,
      );
      expect(januaryReversalRow.sourceDate, '2026-01-12');
      expect(januaryReversalRow.state, InternalSubledgerRowState.matched);
      final refundRow = findRow(InternalSubledgerSource.tenantRefund, refundId);
      expect(refundRow.state, InternalSubledgerRowState.matched);
      final missingSourceRefundRow = findRow(
        InternalSubledgerSource.tenantRefund,
        missingSourceRefundId,
      );
      expect(
        missingSourceRefundRow.state,
        InternalSubledgerRowState.needsReview,
      );
      final unallocatedRow = report.rows.singleWhere(
        (row) =>
            row.source == InternalSubledgerSource.tenantReceipt &&
            row.amountMinor == 2000,
      );
      expect(unallocatedRow.state, InternalSubledgerRowState.matched);
      expect(unallocatedRow.allocationStatus, 'غير مخصص');
      expect(report.unallocatedMinor, 2000);

      final settlement = report.rows.singleWhere(
        (row) => row.source == InternalSubledgerSource.ownerSettlement,
      );
      expect(settlement.state, InternalSubledgerRowState.matched);
      final directJournal = report.rows.singleWhere(
        (row) =>
            row.source == InternalSubledgerSource.directJournal &&
            row.sourceId == unmatchedJournalId,
      );
      expect(directJournal.state, InternalSubledgerRowState.needsReview);
      expect(report.directJournalCount, greaterThanOrEqualTo(2));
      expect(report.reviewCount, greaterThanOrEqualTo(report.directJournalCount));
    },
  );

  test('accepts the maximum calendar date without overflowing', () async {
    final report = await helper.getInternalSubledgerReconciliationReport(
      startDate: '9999-12-31',
      endDate: '9999-12-31',
    );
    expect(report.rows, isEmpty);
  });

  test('requires report permission and rejects an invalid date range', () async {
    await expectLater(
      helper.getInternalSubledgerReconciliationReport(
        startDate: '2026-02-01',
        endDate: '2026-01-01',
      ),
      throwsArgumentError,
    );
    PermissionRuntime.activate(
      userId: 2,
      role: 'User',
      permissionRows: const [],
    );
    await expectLater(
      helper.getInternalSubledgerReconciliationReport(
        startDate: '2026-01-01',
        endDate: '2026-01-31',
      ),
      throwsStateError,
    );
  });
}
