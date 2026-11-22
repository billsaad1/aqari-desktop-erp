import 'dart:io';

import 'package:app/core/contract_term.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final testDirectory = Directory.systemTemp.createTempSync(
    'aqari_early_termination_test_',
  );
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return testDirectory.path;
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDirectory.path;
          }
          return null;
        });
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  setUp(() async {
    await helper.close();
  });

  tearDownAll(() async {
    await helper.close();
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test(
    'terminates early without erasing receivables or posted receipt history and safely relets the unit',
    () async {
      final db = await helper.database;
      final today = DateTime.now();
      String date(DateTime value) => value.toIso8601String().substring(0, 10);
      final effectiveDate = date(today);
      final startDate = date(DateTime(today.year, today.month, 1));
      final endDate = date(
        ContractTerm.endDateForMonths(DateTime(today.year, today.month, 1), 12),
      );

      await helper.insertTenantWithAccount({
        'name': 'مستأجر الإنهاء المبكر',
        'mobile': '777810101',
      });
      final oldTenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر الإنهاء المبكر'],
        limit: 1,
      )).single;
      final oldTenantId = (oldTenant['id'] as num).toInt();

      final ownerId = await db.insert('owners', {'name': 'مالك الإنهاء'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار الإنهاء المبكر',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'ET-01',
        'status': 'شاغرة',
        'default_rent': 1000.0,
        'default_rent_period': 'monthly',
      });

      final pastInstallmentDate = startDate;
      final partiallyPaidDate = date(today.add(const Duration(days: 2)));
      final invoicedDate = date(today.add(const Duration(days: 3)));
      final cleanFutureDate = date(today.add(const Duration(days: 4)));
      final contractId = await helper.insertContractWithInstallments(
        {
          'tenant_id': oldTenantId,
          'unit_id': unitId,
          'start_date': startDate,
          'end_date': endDate,
          'rent_amount': 1000.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': pastInstallmentDate,
            'status': 'Unpaid',
          },
          {
            'amount': 200.0,
            'paid_amount': 0.0,
            'due_date': partiallyPaidDate,
            'status': 'Unpaid',
          },
          {
            'amount': 300.0,
            'paid_amount': 0.0,
            'due_date': invoicedDate,
            'status': 'Unpaid',
          },
          {
            'amount': 400.0,
            'paid_amount': 0.0,
            'due_date': cleanFutureDate,
            'status': 'Unpaid',
          },
        ],
      );
      final installments = await helper.getInstallmentsForContract(contractId);
      final partialInstallmentId = (installments[1]['id'] as num).toInt();
      final invoicedInstallmentId = (installments[2]['id'] as num).toInt();
      final cleanInstallmentId = (installments[3]['id'] as num).toInt();

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
      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: oldTenantId,
        amount: 20.0,
        voucherDate: effectiveDate,
        cashAccountId: cashAccountId,
        installmentsToUpdate: [
          {
            'id': partialInstallmentId,
            'paid_amount': 20.0,
            'status': 'Partially Paid',
          },
        ],
      );
      final receiptBefore = await helper.getTenantReceiptVoucherDetails(
        receiptId,
      );
      expect(receiptBefore, isNotNull);
      final receiptLinesBefore = receiptBefore!['installments'] as List;
      expect(receiptLinesBefore.single['allocated_amount'], 20.0);

      final invoiceId = await db.insert('tax_invoices', {
        'contract_id': contractId,
        'installment_id': invoicedInstallmentId,
        'journal_entry_id': null,
        'invoice_date': effectiveDate,
        'net_amount': 300.0,
        'total_amount': 300.0,
        'tax_amount': 0.0,
        'tax_rate': 0.0,
      });
      final journalsBefore = await db.query('journal_entries');
      final vouchersBefore = await db.query('vouchers');
      final allocationsBefore = await db.query(
        'voucher_installment_allocations',
        where: 'voucher_id = ?',
        whereArgs: [receiptId],
      );

      await helper.terminateContractEarly(
        contractId,
        effectiveDate: effectiveDate,
        reason: 'إخلاء الوحدة بطلب المستأجر',
      );

      final terminatedContract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      expect(terminatedContract['status'], 'Terminated');
      expect(terminatedContract['early_termination_date'], effectiveDate);
      expect(
        terminatedContract['early_termination_reason'],
        'إخلاء الوحدة بطلب المستأجر',
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [unitId],
        )).single['status'],
        'شاغرة',
      );
      expect(
        (await db.query(
          'tax_invoices',
          where: 'id = ?',
          whereArgs: [invoiceId],
        )),
        hasLength(1),
      );
      expect(
        (await db.query('vouchers', where: 'id = ?', whereArgs: [receiptId])),
        hasLength(1),
      );
      expect(
        (await db.query(
          'voucher_installment_allocations',
          where: 'voucher_id = ?',
          whereArgs: [receiptId],
        )),
        hasLength(allocationsBefore.length),
      );
      expect(
        (await db.query('journal_entries')),
        hasLength(journalsBefore.length),
      );
      expect((await db.query('vouchers')), hasLength(vouchersBefore.length));
      final receiptAfter = await helper.getTenantReceiptVoucherDetails(
        receiptId,
      );
      expect(receiptAfter?['installments'], hasLength(1));
      expect(
        (receiptAfter!['installments'] as List).single['allocated_amount'],
        20.0,
      );

      final currentInstallments = await helper.getInstallmentsForContract(
        contractId,
      );
      expect(currentInstallments[0]['status'], 'Unpaid');
      expect(currentInstallments[1]['status'], 'Partially Paid');
      expect(currentInstallments[2]['status'], 'Unpaid');
      expect(currentInstallments[3]['status'], 'Cancelled');

      final dueInstallments = await helper.getDueInstallments(400);
      final dueById = {
        for (final row in dueInstallments)
          (row['installment_id'] as num).toInt(): row,
      };
      expect(
        dueById.keys,
        containsAll([
          (installments[0]['id'] as num).toInt(),
          partialInstallmentId,
          invoicedInstallmentId,
        ]),
      );
      expect(dueById.keys, isNot(contains(cleanInstallmentId)));
      expect(dueById[partialInstallmentId]?['remaining_amount'], 180.0);
      expect(dueById[invoicedInstallmentId]?['remaining_amount'], 300.0);

      final revenueAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: "account_type = 'Revenue' AND parent_id IS NOT NULL",
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      await expectLater(
        helper.insertTaxInvoice(
          contractId: contractId,
          tenantId: oldTenantId,
          installmentId: cleanInstallmentId,
          invoiceDate: effectiveDate,
          netAmount: 400.0,
          taxAmount: 0.0,
          revenueAccountId: revenueAccountId,
          taxAccountId: null,
        ),
        throwsStateError,
      );
      expect((await db.query('tax_invoices')), hasLength(1));

      await helper.insertTenantWithAccount({
        'name': 'مستأجر جديد بعد الإنهاء',
        'mobile': '777810102',
      });
      final newTenantId =
          ((await db.query(
                    'tenants',
                    columns: ['id'],
                    where: 'name = ?',
                    whereArgs: ['مستأجر جديد بعد الإنهاء'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      final newStart = DateTime(today.year, today.month, today.day);
      final newEnd = ContractTerm.endDateForMonths(newStart, 1);
      final newContractId = await helper.insertContractWithInstallments(
        {
          'tenant_id': newTenantId,
          'unit_id': unitId,
          'start_date': date(newStart),
          'end_date': date(newEnd),
          'rent_amount': 100.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': date(newStart),
            'status': 'Unpaid',
          },
        ],
      );
      expect(newContractId, greaterThan(0));
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [unitId],
        )).single['status'],
        'مؤجرة',
      );
    },
  );

  test(
    'lists and allows prepayment of an installment whose due date is in the future',
    () async {
      final db = await helper.database;
      final today = DateTime.now();
      String date(DateTime value) => value.toIso8601String().substring(0, 10);
      final startDate = DateTime(today.year + 1, 1, 1);
      final endDate = ContractTerm.endDateForMonths(startDate, 1);

      await helper.insertTenantWithAccount({
        'name': 'مستأجر سداد قسط مستقبلي',
        'mobile': '777810103',
      });
      final tenant = (await db.query(
        'tenants',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: ['مستأجر سداد قسط مستقبلي'],
        limit: 1,
      )).single;
      final tenantId = (tenant['id'] as num).toInt();
      final ownerId = await db.insert('owners', {'name': 'مالك السداد المبكر'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار السداد المبكر',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'FP-01',
        'status': 'شاغرة',
        'default_rent': 100.0,
        'default_rent_period': 'monthly',
      });
      final contractId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': date(startDate),
          'end_date': date(endDate),
          'rent_amount': 100.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': date(startDate),
            'status': 'Unpaid',
          },
        ],
      );

      final receivables = await helper.getUnbilledInstallmentsForTenant(
        tenantId,
      );
      expect(receivables, hasLength(1));
      expect(receivables.single['due_date'], date(startDate));
      final installmentId = (receivables.single['id'] as num).toInt();
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

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: tenantId,
        amount: 100.0,
        voucherDate: date(today),
        cashAccountId: cashAccountId,
        installmentsToUpdate: [
          {'id': installmentId, 'paid_amount': 100.0, 'status': 'Paid'},
        ],
      );

      expect(receiptId, greaterThan(0));
      final paid = (await helper.getInstallmentsForContract(contractId)).single;
      expect(paid['status'], 'Paid');
      expect(paid['paid_amount'], 100.0);
    },
  );
}
