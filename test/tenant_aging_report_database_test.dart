import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/tenant_aging_report_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_tenant_aging_report_test';
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

  Future<Map<String, Object?>> tenantAndContract(
    dynamic db, {
    required String suffix,
  }) async {
    await helper.insertTenantWithAccount({
      'name': 'مستأجر أعمار $suffix',
      'mobile': '779100${suffix.hashCode.abs() % 1000}',
    });
    final tenant = (await db.query(
      'tenants',
      columns: ['id', 'name', 'account_id'],
      where: 'name = ?',
      whereArgs: ['مستأجر أعمار $suffix'],
      limit: 1,
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك أعمار $suffix'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار أعمار $suffix',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'A-$suffix',
      'status': 'مؤجرة',
    });
    final contractId = await db.insert('contracts', {
      'tenant_id': tenant['id'],
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2027-12-31',
      'rent_amount': 1000.0,
      'status': 'Active',
    });
    return {
      ...tenant,
      'contract_id': contractId,
      'property_id': propertyId,
      'unit_id': unitId,
    };
  }

  Future<int> addInstallment(
    dynamic db,
    Map<String, Object?> lease, {
    required String dueDate,
    required double amount,
    double paidAmount = 0,
  }) => db.insert('contract_installments', {
    'contract_id': lease['contract_id'],
    'amount': amount,
    'paid_amount': paidAmount,
    'due_date': dueDate,
    'status': 'Unpaid',
  });

  Future<int> addJournal(
    dynamic db, {
    required String date,
    required int debitAccount,
    required int creditAccount,
    required double amount,
  }) async {
    final id = await db.insert('journal_entries', {
      'entry_date': date,
      'description': 'tenant aging test fixture',
      'is_posted': 1,
    });
    await db.insert('journal_lines', {
      'journal_entry_id': id,
      'account_id': debitAccount,
      'debit': amount,
      'credit': 0.0,
    });
    await db.insert('journal_lines', {
      'journal_entry_id': id,
      'account_id': creditAccount,
      'debit': 0.0,
      'credit': amount,
    });
    return id;
  }

  Future<int> addReceipt(
    dynamic db,
    Map<String, Object?> lease, {
    required String date,
    required double total,
    required int installmentId,
    required double rentAmount,
    double taxAmount = 0,
    int? invoiceId,
    bool addDetailedAllocation = true,
    bool addLegacyAllocation = true,
  }) async {
    final cashAccount = (await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: ['1101'],
      limit: 1,
    )).single;
    final journalId = await addJournal(
      db,
      date: date,
      debitAccount: (cashAccount['id'] as num).toInt(),
      creditAccount: (lease['account_id'] as num).toInt(),
      amount: total,
    );
    final receiptId = await db.insert('vouchers', {
      'voucher_type': 'قبض مستأجر',
      'voucher_date': date,
      'amount': total,
      'tenant_id': lease['id'],
      'party_name': lease['name'],
      'journal_entry_id': journalId,
      'description': 'قبض اختبار أعمار',
    });
    if (addLegacyAllocation) {
      await db.insert('voucher_installment_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'amount': rentAmount,
      });
      if (invoiceId != null) {
        await db.insert('voucher_invoice_allocations', {
          'voucher_id': receiptId,
          'invoice_id': invoiceId,
          'amount': total,
        });
      }
    }
    if (addDetailedAllocation) {
      await db.insert('collection_allocations', {
        'voucher_id': receiptId,
        'installment_id': installmentId,
        'invoice_id': invoiceId,
        'amount_minor': (total * 100).round(),
        'rent_amount_minor': (rentAmount * 100).round(),
        'tax_amount_minor': (taxAmount * 100).round(),
      });
    }
    return receiptId;
  }

  Future<int> addRefund(
    dynamic db,
    Map<String, Object?> lease, {
    required String date,
    required double amount,
    required int sourceAllocationId,
  }) async {
    final cashAccount = (await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: ['1101'],
      limit: 1,
    )).single;
    final journalId = await addJournal(
      db,
      date: date,
      debitAccount: (lease['account_id'] as num).toInt(),
      creditAccount: (cashAccount['id'] as num).toInt(),
      amount: amount,
    );
    final refundId = await db.insert('vouchers', {
      'voucher_type': 'صرف مستأجر',
      'voucher_date': date,
      'amount': amount,
      'tenant_id': lease['id'],
      'party_name': lease['name'],
      'journal_entry_id': journalId,
      'description': 'استرداد اختبار أعمار',
    });
    await db.insert('refund_allocations', {
      'refund_voucher_id': refundId,
      'collection_allocation_id': sourceAllocationId,
      'amount_minor': (amount * 100).round(),
      'rent_amount_minor': (amount * 100).round(),
      'tax_amount_minor': 0,
    });
    return refundId;
  }

  test(
    'reconstructs balances using voucher and invoice dates at each cutoff',
    () async {
      final db = await helper.database;
      final lease = await tenantAndContract(db, suffix: 'cutoff');
      final installment = await addInstallment(
        db,
        lease,
        dueDate: '2026-06-20',
        amount: 100.00,
        paidAmount: 0,
      );
      final invoiceInstallment = await addInstallment(
        db,
        lease,
        dueDate: '2026-05-30',
        amount: 50.00,
        paidAmount: 50,
      );
      final tenantAccount = (lease['account_id'] as num).toInt();
      final revenue = (await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['4101'],
        limit: 1,
      )).single;
      final invoiceJournal = await addJournal(
        db,
        date: '2026-06-15',
        debitAccount: tenantAccount,
        creditAccount: (revenue['id'] as num).toInt(),
        amount: 55.00,
      );
      final invoiceId = await db.insert('tax_invoices', {
        'contract_id': lease['contract_id'],
        'installment_id': invoiceInstallment,
        'journal_entry_id': invoiceJournal,
        'invoice_date': '2026-06-15',
        'net_amount': 50.00,
        'total_amount': 55.00,
        'tax_amount': 5.00,
        'tax_rate': 10.0,
      });

      final beforeReceipt = await helper.getTenantAgingReport(
        asOfDate: '2026-06-10',
      );
      expect(
        beforeReceipt.rows
            .singleWhere((row) => row.installmentId == installment)
            .balanceMinor,
        10000,
      );
      expect(
        beforeReceipt.rows
            .singleWhere((row) => row.installmentId == invoiceInstallment)
            .obligationMinor,
        5000,
        reason: 'before invoice date, only the scheduled rent amount is used',
      );

      await addReceipt(
        db,
        lease,
        date: '2026-06-25',
        total: 40,
        installmentId: installment,
        rentAmount: 40,
      );
      final beforeRefund = await helper.getTenantAgingReport(
        asOfDate: '2026-06-28',
      );
      expect(
        beforeRefund.rows
            .singleWhere((row) => row.installmentId == installment)
            .balanceMinor,
        6000,
      );
      final receiptAllocation = (await db.query(
        'collection_allocations',
        columns: ['id'],
        orderBy: 'id ASC',
        limit: 1,
      )).single;
      await addRefund(
        db,
        lease,
        date: '2026-06-29',
        amount: 10,
        sourceAllocationId: (receiptAllocation['id'] as num).toInt(),
      );
      final atCutoff = await helper.getTenantAgingReport(
        asOfDate: '2026-06-30',
      );
      final atInstallment = atCutoff.rows.singleWhere(
        (row) => row.installmentId == installment,
      );
      expect(atInstallment.obligationMinor, 10000);
      expect(atInstallment.paidMinor, 3000);
      expect(atInstallment.balanceMinor, 7000);
      expect(
        atCutoff.rows
            .singleWhere((row) => row.installmentId == invoiceInstallment)
            .obligationMinor,
        5500,
        reason: 'the posted invoice total includes its tax',
      );
      expect(
        atCutoff.rows
            .singleWhere((row) => row.installmentId == invoiceInstallment)
            .bucket
            .label,
        '31–60 يومًا',
      );

      await addReceipt(
        db,
        lease,
        date: '2026-07-01',
        total: 20,
        installmentId: installment,
        rentAmount: 20,
      );
      final laterReceiptAllocation = (await db.query(
        'collection_allocations',
        columns: ['id'],
        orderBy: 'id DESC',
        limit: 1,
      )).single;
      await addRefund(
        db,
        lease,
        date: '2026-07-03',
        amount: 5,
        sourceAllocationId: (laterReceiptAllocation['id'] as num).toInt(),
      );
      final afterReceiptAndRefund = await helper.getTenantAgingReport(
        asOfDate: '2026-07-05',
      );
      final afterRow = afterReceiptAndRefund.rows.singleWhere(
        (row) => row.installmentId == installment,
      );
      expect(afterRow.paidMinor, 4500);
      expect(afterRow.balanceMinor, 5500);
      expect(
        afterReceiptAndRefund.rows
            .singleWhere((row) => row.installmentId == invoiceInstallment)
            .obligationMinor,
        5500,
      );
      expect(invoiceId, greaterThan(0));
    },
  );

  test(
    'assigns exact aging boundaries and future amounts to separate buckets',
    () async {
      final db = await helper.database;
      final lease = await tenantAndContract(db, suffix: 'boundaries');
      final boundaryDates = <String, String>{
        'future': '2026-07-01',
        'today': '2026-06-30',
        '30': '2026-05-31',
        '31': '2026-05-30',
        '60': '2026-05-01',
        '61': '2026-04-30',
        '90': '2026-04-01',
        '91': '2026-03-31',
      };
      final ids = <String, int>{};
      for (final entry in boundaryDates.entries) {
        ids[entry.key] = await addInstallment(
          db,
          lease,
          dueDate: entry.value,
          amount: 1.00,
        );
      }
      final report = await helper.getTenantAgingReport(asOfDate: '2026-06-30');
      final bucketByName = {
        for (final row in report.rows)
          boundaryDates.entries
                  .where((entry) => ids[entry.key] == row.installmentId)
                  .single
                  .key:
              row.bucket.label,
      };
      expect(bucketByName['future'], 'غير مستحق');
      expect(bucketByName['today'], '0–30 يومًا');
      expect(bucketByName['30'], '0–30 يومًا');
      expect(bucketByName['31'], '31–60 يومًا');
      expect(bucketByName['60'], '31–60 يومًا');
      expect(bucketByName['61'], '61–90 يومًا');
      expect(bucketByName['90'], '61–90 يومًا');
      expect(bucketByName['91'], '91+ يومًا');
      expect(report.totalOutstandingMinor, 800);
    },
  );

  test(
    'separates unallocated and legacy-only receipt history as exceptions',
    () async {
      final db = await helper.database;
      final lease = await tenantAndContract(db, suffix: 'exceptions');
      final installment = await addInstallment(
        db,
        lease,
        dueDate: '2026-06-01',
        amount: 100,
      );
      await addReceipt(
        db,
        lease,
        date: '2026-06-10',
        total: 20,
        installmentId: installment,
        rentAmount: 20,
      );
      await addReceipt(
        db,
        lease,
        date: '2026-06-11',
        total: 10,
        installmentId: installment,
        rentAmount: 10,
        addDetailedAllocation: false,
      );
      await addReceipt(
        db,
        lease,
        date: '2026-06-12',
        total: 10,
        installmentId: installment,
        rentAmount: 0,
        addDetailedAllocation: false,
        addLegacyAllocation: false,
      );

      final report = await helper.getTenantAgingReport(asOfDate: '2026-06-30');
      final row = report.rows.single;
      expect(row.paidMinor, 2000);
      expect(row.balanceMinor, 8000);
      expect(report.exceptions, hasLength(2));
      expect(report.exceptionAmountMinor, 2000);
      expect(
        report.exceptions.map((item) => item.reason).join(' '),
        contains('السجل التاريخي القديم فقط'),
      );
      expect(
        report.exceptions.map((item) => item.reason).join(' '),
        contains('بلا تخصيص تفصيلي موثق'),
      );
    },
  );

  test(
    'excludes cancelled schedules and flags inconsistent financial activity',
    () async {
      final db = await helper.database;
      final cancelledLease = await tenantAndContract(db, suffix: 'cancelled');
      await addInstallment(
        db,
        cancelledLease,
        dueDate: '2026-05-01',
        amount: 100,
      );
      await helper.cancelContract(
        (cancelledLease['contract_id'] as num).toInt(),
        reason: 'إلغاء اختبار تقرير الأعمار',
      );

      final inconsistentLease = await tenantAndContract(
        db,
        suffix: 'cancelled-with-receipt',
      );
      final installmentId = await addInstallment(
        db,
        inconsistentLease,
        dueDate: '2026-05-01',
        amount: 100,
      );
      await addReceipt(
        db,
        inconsistentLease,
        date: '2026-05-10',
        total: 20,
        installmentId: installmentId,
        rentAmount: 20,
      );
      await db.update(
        'contract_installments',
        {'status': 'Cancelled'},
        where: 'id = ?',
        whereArgs: [installmentId],
      );
      await db.update(
        'contracts',
        {'status': 'Cancelled'},
        where: 'id = ?',
        whereArgs: [inconsistentLease['contract_id']],
      );

      final report = await helper.getTenantAgingReport(asOfDate: '2026-06-30');
      expect(report.rows, isEmpty);
      expect(
        report.exceptions.where((item) => item.documentType == 'قسط ملغى'),
        hasLength(1),
      );
    },
  );

  test('requires reports.view and validates cutoff calendar date', () async {
    PermissionRuntime.activate(
      userId: 42,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await expectLater(
      helper.getTenantAgingReport(asOfDate: '2026-06-30'),
      throwsStateError,
    );
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    await expectLater(
      helper.getTenantAgingReport(asOfDate: '2026-02-30'),
      throwsArgumentError,
    );
  });
}
