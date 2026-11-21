import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_tenant_collection_report_test';
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
    'uses posted tenant receipts once and subtracts only verified refunds',
    () async {
      final db = await helper.database;
      await helper.insertTenantWithAccount({
        'name': 'مستأجر تقرير التحصيل',
        'mobile': '777810001',
      });
      final tenant = (await db.query(
        'tenants',
        columns: ['id', 'name', 'account_id'],
        where: 'name = ?',
        whereArgs: ['مستأجر تقرير التحصيل'],
        limit: 1,
      )).single;
      final tenantId = (tenant['id'] as num).toInt();
      final tenantAccountId = (tenant['account_id'] as num).toInt();
      final cashAccount = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['1101'],
        limit: 1,
      )).single;
      final cashAccountId = (cashAccount['id'] as num).toInt();
      final ownerId = await db.insert('owners', {'name': 'مالك تقرير التحصيل'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار تقرير التحصيل',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'C-19',
        'status': 'مؤجرة',
      });
      final contractId = await db.insert('contracts', {
        'tenant_id': tenantId,
        'unit_id': unitId,
        'start_date': '2026-01-01',
        'end_date': '2026-12-31',
        'rent_amount': 100.0,
        'status': 'Active',
      });
      final installmentId = await db.insert('contract_installments', {
        'contract_id': contractId,
        'amount': 40.0,
        'paid_amount': 40.0,
        'due_date': '2026-02-01',
        'status': 'Paid',
      });
      final secondInstallmentId = await db.insert('contract_installments', {
        'contract_id': contractId,
        'amount': 60.0,
        'paid_amount': 60.0,
        'due_date': '2026-03-01',
        'status': 'Paid',
      });
      final thirdInstallmentId = await db.insert('contract_installments', {
        'contract_id': contractId,
        'amount': 12.0,
        'paid_amount': 12.0,
        'due_date': '2026-04-01',
        'status': 'Paid',
      });

      Future<int> insertJournal({
        required String date,
        required int debitAccount,
        required int creditAccount,
        required double amount,
        required int isPosted,
      }) async {
        final entryId = await db.insert('journal_entries', {
          'entry_date': date,
          'description': 'fixture for collection report',
          'is_posted': isPosted,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': debitAccount,
          'debit': amount,
          'credit': 0.0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': creditAccount,
          'debit': 0.0,
          'credit': amount,
        });
        return entryId;
      }

      final receiptJournalId = await insertJournal(
        date: '2026-02-10',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 100.0,
        isPosted: 1,
      );
      final receiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-10',
        'amount': 100.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': receiptJournalId,
        'description': 'قبض مرتبط بالقسط',
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'amount': 40.0,
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': receiptId,
        'installment_id': secondInstallmentId,
        'amount': 60.0,
      });
      final collectionAllocationId = await db.insert('collection_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'invoice_id': null,
        'amount_minor': 4000,
        'rent_amount_minor': 4000,
        'tax_amount_minor': 0,
      });
      await db.insert('collection_allocations', {
        'voucher_id': receiptId,
        'installment_id': secondInstallmentId,
        'invoice_id': null,
        'amount_minor': 6000,
        'rent_amount_minor': 6000,
        'tax_amount_minor': 0,
      });

      final unallocatedJournalId = await insertJournal(
        date: '2026-02-11',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 50.0,
        isPosted: 1,
      );
      final unallocatedReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-11',
        'amount': 50.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': unallocatedJournalId,
        'description': 'قبض مرحل بلا تخصيص تفصيلي مثبت',
      });
      final legacyOnlyJournalId = await insertJournal(
        date: '2026-02-11',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 8.0,
        isPosted: 1,
      );
      final legacyOnlyReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-11',
        'amount': 8.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': legacyOnlyJournalId,
        'description': 'تخصيص محفوظ في الجدول القديم دون التخصيص التفصيلي',
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': legacyOnlyReceiptId,
        'installment_id': secondInstallmentId,
        'amount': 8.0,
      });
      final invoiceId = await db.insert('tax_invoices', {
        'contract_id': contractId,
        'installment_id': secondInstallmentId,
        'invoice_date': '2026-02-09',
        'net_amount': 60.0,
        'total_amount': 60.0,
        'tax_amount': 0.0,
        'tax_rate': 0.0,
      });
      final invoiceOnlyJournalId = await insertJournal(
        date: '2026-02-11',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 12.0,
        isPosted: 1,
      );
      final invoiceOnlyReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-11',
        'amount': 12.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': invoiceOnlyJournalId,
        'description': 'مرجع فاتورة قديم دون تخصيص تفصيلي',
      });
      await db.insert('voucher_invoice_allocations', {
        'voucher_id': invoiceOnlyReceiptId,
        'invoice_id': invoiceId,
        'amount': 12.0,
      });
      final invoiceRentMismatchId = await db.insert('tax_invoices', {
        'contract_id': contractId,
        'installment_id': thirdInstallmentId,
        'invoice_date': '2026-02-09',
        'net_amount': 12.0,
        'total_amount': 15.0,
        'tax_amount': 3.0,
        'tax_rate': 25.0,
      });
      final invoiceRentMismatchJournalId = await insertJournal(
        date: '2026-02-11',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 15.0,
        isPosted: 1,
      );
      final invoiceRentMismatchReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-11',
        'amount': 15.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': invoiceRentMismatchJournalId,
        'description': 'قسط تاريخي لا يطابق جزء الإيجار التفصيلي',
      });
      await db.insert('voucher_invoice_allocations', {
        'voucher_id': invoiceRentMismatchReceiptId,
        'invoice_id': invoiceRentMismatchId,
        'amount': 15.0,
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': invoiceRentMismatchReceiptId,
        'installment_id': thirdInstallmentId,
        'amount': 10.0,
      });
      // Simulate a corrupt historical row predating the current write guard.
      await db.execute('DROP TRIGGER collection_allocations_voucher_valid');
      final invoiceRentMismatchAllocationId = await db
          .insert('collection_allocations', {
            'voucher_id': invoiceRentMismatchReceiptId,
            'installment_id': thirdInstallmentId,
            'invoice_id': invoiceRentMismatchId,
            'amount_minor': 1500,
            'rent_amount_minor': 1200,
            'tax_amount_minor': 300,
          });
      final endDateJournalId = await insertJournal(
        date: '2026-02-28T23:59:59',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 25.0,
        isPosted: 1,
      );
      final endDateReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-28T23:59:59',
        'amount': 25.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': endDateJournalId,
        'description': 'قبض في نهاية اليوم الأخير للفترة',
      });

      final verifiedRefundJournalId = await insertJournal(
        date: '2026-02-12',
        debitAccount: tenantAccountId,
        creditAccount: cashAccountId,
        amount: 25.0,
        isPosted: 1,
      );
      final verifiedRefundId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2026-02-12',
        'amount': 25.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': verifiedRefundJournalId,
        'description': 'رد مرتبط ومطابق',
      });
      await db.insert('refund_allocations', {
        'refund_voucher_id': verifiedRefundId,
        'collection_allocation_id': collectionAllocationId,
        'amount_minor': 2500,
        'rent_amount_minor': 2500,
        'tax_amount_minor': 0,
      });

      final sourceMismatchRefundJournalId = await insertJournal(
        date: '2026-02-12',
        debitAccount: tenantAccountId,
        creditAccount: cashAccountId,
        amount: 5.0,
        isPosted: 1,
      );
      final sourceMismatchRefundId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2026-02-12',
        'amount': 5.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': sourceMismatchRefundJournalId,
        'description': 'رد مربوط بمصدر تخصيص قسط مخالف تاريخيًا',
      });
      await db.insert('refund_allocations', {
        'refund_voucher_id': sourceMismatchRefundId,
        'collection_allocation_id': invoiceRentMismatchAllocationId,
        'amount_minor': 500,
        'rent_amount_minor': 500,
        'tax_amount_minor': 0,
      });

      final reviewRefundJournalId = await insertJournal(
        date: '2026-02-13',
        debitAccount: tenantAccountId,
        creditAccount: cashAccountId,
        amount: 10.0,
        isPosted: 1,
      );
      final reviewRefundId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2026-02-13',
        'amount': 10.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': reviewRefundJournalId,
        'description': 'رد بتخصيص غير مكتمل للمراجعة',
      });
      await db.insert('refund_allocations', {
        'refund_voucher_id': reviewRefundId,
        'collection_allocation_id': collectionAllocationId,
        'amount_minor': 500,
        'rent_amount_minor': 500,
        'tax_amount_minor': 0,
      });

      final unrelatedPayoutJournalId = await insertJournal(
        date: '2026-02-14',
        debitAccount: tenantAccountId,
        creditAccount: cashAccountId,
        amount: 30.0,
        isPosted: 1,
      );
      final unrelatedPayoutVoucherId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2026-02-14',
        'amount': 30.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': unrelatedPayoutJournalId,
        'description': 'صرف غير مرتبط بمصدر تحصيل',
      });

      final unpostedJournalId = await db.insert('journal_entries', {
        'entry_date': '2026-02-15',
        'description': 'unposted receipt',
        'is_posted': 0,
      });
      final unpostedVoucherId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-15',
        'amount': 999.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': unpostedJournalId,
        'description': 'غير مرحل ويجب استبعاده',
      });
      final outsideJournalId = await insertJournal(
        date: '2026-03-01',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 60.0,
        isPosted: 1,
      );
      final outsideVoucherId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-03-01',
        'amount': 60.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': outsideJournalId,
        'description': 'خارج الفترة',
      });

      final report = await helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );
      final rowsById = {for (final row in report.rows) row.voucherId: row};
      expect(rowsById.keys, containsAll([receiptId, unallocatedReceiptId]));
      expect(rowsById.keys, contains(endDateReceiptId));
      expect(rowsById.keys, contains(legacyOnlyReceiptId));
      expect(rowsById.keys, contains(invoiceOnlyReceiptId));
      expect(rowsById.keys, contains(invoiceRentMismatchReceiptId));
      expect(
        rowsById.keys,
        containsAll([verifiedRefundId, sourceMismatchRefundId, reviewRefundId]),
      );
      expect(rowsById, isNot(contains(unrelatedPayoutVoucherId)));
      expect(rowsById, isNot(contains(unpostedVoucherId)));
      expect(rowsById, isNot(contains(outsideVoucherId)));
      expect(rowsById.values, hasLength(9));
      expect(rowsById[receiptId]?.allocationStatus, 'التخصيص مطابق');
      expect(rowsById[receiptId]?.linkedAllocationMinor, 10000);
      expect(
        rowsById[receiptId]?.sourceConsistencyStatus,
        'سجلات التخصيص متطابقة',
      );
      expect(
        rowsById[unallocatedReceiptId]?.allocationStatus,
        'لا يوجد تخصيص مثبت',
      );
      expect(
        rowsById[unallocatedReceiptId]?.sourceConsistencyStatus,
        'لا توجد تخصيصات للمقارنة',
      );
      expect(
        rowsById[legacyOnlyReceiptId]?.sourceMismatchCount,
        greaterThan(0),
      );
      expect(
        rowsById[legacyOnlyReceiptId]?.sourceConsistencyStatus,
        'يوجد اختلاف في سجل أو رابط التخصيص',
      );
      expect(
        rowsById[invoiceOnlyReceiptId]?.sourceMismatchCount,
        greaterThan(0),
      );
      expect(
        rowsById[invoiceOnlyReceiptId]?.sourceConsistencyStatus,
        'يوجد اختلاف في سجل أو رابط التخصيص',
      );
      expect(
        rowsById[invoiceRentMismatchReceiptId]?.allocationStatus,
        'التخصيص مطابق',
      );
      expect(
        rowsById[invoiceRentMismatchReceiptId]?.sourceMismatchCount,
        greaterThan(0),
      );
      expect(
        rowsById[invoiceRentMismatchReceiptId]?.sourceConsistencyStatus,
        'يوجد اختلاف في سجل أو رابط التخصيص',
      );
      expect(rowsById[sourceMismatchRefundId]?.isVerifiedRefund, isFalse);
      expect(
        rowsById[sourceMismatchRefundId]?.allocationStatus,
        'تخصيص مصدر القبض يحتاج مراجعة',
      );
      expect(rowsById[verifiedRefundId]?.isVerifiedRefund, isTrue);
      expect(rowsById[verifiedRefundId]?.amountMinor, -2500);
      expect(
        rowsById[verifiedRefundId]?.sourceConsistencyStatus,
        'المصدر متسق وتحت السقف',
      );
      expect(rowsById[verifiedRefundId]?.sourceReceiptVoucherIds, '$receiptId');
      expect(rowsById[reviewRefundId]?.isVerifiedRefund, isFalse);
      expect(
        rowsById[reviewRefundId]?.allocationStatus,
        'مجموع تخصيصات الاسترداد لا يطابق السند',
      );
      expect(report.grossReceiptsMinor, 21000);
      expect(report.linkedRefundsMinor, 2500);
      expect(report.unverifiedRefundsMinor, 1500);
      expect(report.netCollectedMinor, 18500);
      expect(report.unallocatedReceiptsMinor, 9500);
      expect(report.receiptCount, 6);
      expect(report.linkedRefundCount, 1);
      expect(report.unverifiedRefundCount, 2);
      expect(report.sourceMismatchVoucherCount, 5);
    },
  );

  test(
    'filters collection report rows and totals to the selected tenant',
    () async {
      final db = await helper.database;
      await helper.insertTenantWithAccount({
        'name': 'مستأجر كشف مفلتر أول',
        'mobile': '777810201',
      });
      await helper.insertTenantWithAccount({
        'name': 'مستأجر كشف مفلتر ثان',
        'mobile': '777810202',
      });
      final tenants = await db.query(
        'tenants',
        columns: ['id', 'name', 'account_id'],
        where: 'name LIKE ?',
        whereArgs: ['مستأجر كشف مفلتر%'],
        orderBy: 'name',
      );
      expect(tenants, hasLength(2));
      final cashAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: 'code = ?',
                    whereArgs: ['1101'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();

      Future<void> addReceipt(
        Map<String, Object?> tenant,
        double amount,
      ) async {
        final tenantId = (tenant['id'] as num).toInt();
        final tenantAccountId = (tenant['account_id'] as num).toInt();
        final journalId = await db.insert('journal_entries', {
          'entry_date': '2026-02-10',
          'description': 'قبض مستأجر لاختبار المرشح',
          'is_posted': 1,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': cashAccountId,
          'debit': amount,
          'credit': 0.0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': tenantAccountId,
          'debit': 0.0,
          'credit': amount,
        });
        await db.insert('vouchers', {
          'voucher_type': 'قبض مستأجر',
          'voucher_date': '2026-02-10',
          'amount': amount,
          'tenant_id': tenantId,
          'party_name': tenant['name'],
          'journal_entry_id': journalId,
          'description': 'قبض اختباري',
        });
      }

      await addReceipt(tenants[0], 25.0);
      await addReceipt(tenants[1], 75.0);

      final completeReport = await helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );
      expect(completeReport.rows, hasLength(2));
      expect(completeReport.grossReceiptsMinor, 10000);

      final firstTenantId = (tenants[0]['id'] as num).toInt();
      final firstTenantReport = await helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
        tenantId: firstTenantId,
      );
      expect(firstTenantReport.tenantId, firstTenantId);
      expect(firstTenantReport.tenantName, tenants[0]['name']);
      expect(firstTenantReport.rows, hasLength(1));
      expect(firstTenantReport.rows.single.tenantId, firstTenantId);
      expect(firstTenantReport.rows.single.tenantName, tenants[0]['name']);
      expect(firstTenantReport.grossReceiptsMinor, 2500);
      expect(firstTenantReport.netCollectedMinor, 2500);
    },
  );

  test(
    'does not verify refunds after cumulative source cap is exceeded',
    () async {
      final db = await helper.database;
      await helper.insertTenantWithAccount({
        'name': 'مستأجر تجاوز سقف الاسترداد',
        'mobile': '777810002',
      });
      final tenant = (await db.query(
        'tenants',
        columns: ['id', 'name', 'account_id'],
        where: 'name = ?',
        whereArgs: ['مستأجر تجاوز سقف الاسترداد'],
        limit: 1,
      )).single;
      final tenantId = (tenant['id'] as num).toInt();
      final tenantAccountId = (tenant['account_id'] as num).toInt();
      final cashAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: 'code = ?',
                    whereArgs: ['1101'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      final ownerId = await db.insert('owners', {'name': 'مالك سقف الاسترداد'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار سقف الاسترداد',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'C-20',
        'status': 'مؤجرة',
      });
      final contractId = await db.insert('contracts', {
        'tenant_id': tenantId,
        'unit_id': unitId,
        'start_date': '2026-01-01',
        'end_date': '2026-12-31',
        'rent_amount': 100.0,
        'status': 'Active',
      });
      final installmentId = await db.insert('contract_installments', {
        'contract_id': contractId,
        'amount': 100.0,
        'paid_amount': 100.0,
        'due_date': '2026-02-01',
        'status': 'Paid',
      });

      Future<int> insertJournal({
        required String date,
        required int debitAccount,
        required int creditAccount,
        required double amount,
      }) async {
        final entryId = await db.insert('journal_entries', {
          'entry_date': date,
          'description': 'refund-cap fixture',
          'is_posted': 1,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': debitAccount,
          'debit': amount,
          'credit': 0.0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId,
          'account_id': creditAccount,
          'debit': 0.0,
          'credit': amount,
        });
        return entryId;
      }

      final receiptJournalId = await insertJournal(
        date: '2026-02-10',
        debitAccount: cashAccountId,
        creditAccount: tenantAccountId,
        amount: 100.0,
      );
      final receiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2026-02-10',
        'amount': 100.0,
        'tenant_id': tenantId,
        'party_name': tenant['name'],
        'journal_entry_id': receiptJournalId,
        'description': 'المصدر الأصلي للاسترداد',
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'amount': 100.0,
      });
      final sourceAllocationId = await db.insert('collection_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'invoice_id': null,
        'amount_minor': 10000,
        'rent_amount_minor': 10000,
        'tax_amount_minor': 0,
      });

      Future<int> insertRefund({
        required String date,
        required double amount,
      }) async {
        final journalId = await insertJournal(
          date: date,
          debitAccount: tenantAccountId,
          creditAccount: cashAccountId,
          amount: amount,
        );
        final voucherId = await db.insert('vouchers', {
          'voucher_type': 'صرف مستأجر',
          'voucher_date': date,
          'amount': amount,
          'tenant_id': tenantId,
          'party_name': tenant['name'],
          'journal_entry_id': journalId,
          'description': 'استرداد تاريخي للاختبار',
        });
        await db.insert('refund_allocations', {
          'refund_voucher_id': voucherId,
          'collection_allocation_id': sourceAllocationId,
          'amount_minor': (amount * 100).round(),
          'rent_amount_minor': (amount * 100).round(),
          'tax_amount_minor': 0,
        });
        return voucherId;
      }

      final firstRefund = await insertRefund(date: '2026-02-11', amount: 40.0);
      final secondRefund = await insertRefund(date: '2026-02-12', amount: 30.0);
      // Simulate legacy rows written before the cumulative source-cap trigger.
      await db.execute('DROP TRIGGER refund_allocations_source_cap');
      final overCapRefund = await insertRefund(
        date: '2026-02-13',
        amount: 31.0,
      );

      final report = await helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      );
      final rowsById = {for (final row in report.rows) row.voucherId: row};
      for (final refundId in [firstRefund, secondRefund, overCapRefund]) {
        expect(rowsById[refundId]?.isVerifiedRefund, isFalse);
        expect(
          rowsById[refundId]?.allocationStatus,
          'مجموع الاستردادات يتجاوز سقف المصدر',
        );
      }
      expect(report.grossReceiptsMinor, 10000);
      expect(report.linkedRefundsMinor, 0);
      expect(report.unverifiedRefundsMinor, 10100);
      expect(report.netCollectedMinor, 10000);
      expect(report.unverifiedRefundCount, 3);
      expect(report.sourceMismatchVoucherCount, 3);
    },
  );

  test('report requires reports.view and rejects invalid dates', () async {
    PermissionRuntime.activate(
      userId: 42,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await expectLater(
      helper.getTenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
      ),
      throwsStateError,
    );

    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    await expectLater(
      helper.getTenantCollectionReport(
        startDate: '2026-02-30',
        endDate: '2026-02-28',
      ),
      throwsArgumentError,
    );
    await expectLater(
      helper.getTenantCollectionReport(
        startDate: '2026-03-01',
        endDate: '2026-02-28',
      ),
      throwsArgumentError,
    );
  });
}
