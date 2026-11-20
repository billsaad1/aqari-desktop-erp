import 'dart:io';

import 'package:app/core/internal_tax.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 26: automated leasing journal lines must carry the cost centre of
/// their real source (property of the unit the installment belongs to), and a
/// voucher covering several properties must not dump its whole amount on one
/// centre.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_cost_center_test';
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
    await helper.updateCompanyInfo({'name_ar': 'منشأة اختبار المراكز', 'tax_rate': 15.0});
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

  /// Seeds owner/property/unit/tenant and an active contract, optionally with a
  /// cost centre on the property. Returns the identifiers the writers need.
  Future<
    ({
      int tenantId,
      int contractId,
      int propertyId,
      List<Map<String, Object?>> installments,
    })
  >
  seedContract({
    required String suffix,
    int? costCenterId,
    int installmentCount = 2,
  }) async {
    final db = await helper.database;
    final ownerId = await db.insert('owners', {'name': 'مالك $suffix'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار $suffix',
      'owner_id': ownerId,
      'cost_center_id': costCenterId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'U-$suffix',
      'default_rent': 100.0,
      'default_rent_period': 'monthly',
    });
    await helper.insertTenantWithAccount({
      'name': 'مستأجر $suffix',
      'mobile': '7770$suffix',
    });
    final tenantId =
        (await db.query(
              'tenants',
              where: 'name = ?',
              whereArgs: ['مستأجر $suffix'],
            )).single['id']
            as int;
    final rent = 100.0 * installmentCount;
    final contractId = await helper.insertContractWithInstallments({
      'tenant_id': tenantId,
      'unit_id': unitId,
      'start_date': '2026-11-10',
      'end_date': '2027-11-09',
      'rent_amount': rent,
      'payment_method': 'شهري',
      'status': 'Active',
    }, [
      for (var i = 0; i < installmentCount; i++)
        {
          'amount': 100.0,
          'paid_amount': 0.0,
          'due_date': '2026-${(11 + i).toString().padLeft(2, '0')}-10',
          'status': 'Unpaid',
        },
    ]);
    return (
      tenantId: tenantId,
      contractId: contractId,
      propertyId: propertyId,
      installments: await helper.getInstallmentsForContract(contractId),
    );
  }

  /// Returns (account_code -> {cost_center_id -> credit_minor}) for a journal.
  Future<Map<int?, int>> costCenterCredits(int journalEntryId) async {
    final db = await helper.database;
    final rows = await db.rawQuery(
      '''
      SELECT jl.cost_center_id AS cost_center_id,
             CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER) AS credit_minor
      FROM journal_lines jl
      WHERE jl.journal_entry_id = ?
      GROUP BY jl.cost_center_id
      HAVING credit_minor != 0
      ''',
      [journalEntryId],
    );
    return {
      for (final row in rows)
        (row['cost_center_id'] as num?)?.toInt():
            (row['credit_minor'] as num).toInt(),
    };
  }

  Future<Map<int?, int>> costCenterDebits(int journalEntryId) async {
    final db = await helper.database;
    final rows = await db.rawQuery(
      '''
      SELECT jl.cost_center_id AS cost_center_id,
             CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER) AS debit_minor
      FROM journal_lines jl
      WHERE jl.journal_entry_id = ?
      GROUP BY jl.cost_center_id
      HAVING debit_minor != 0
      ''',
      [journalEntryId],
    );
    return {
      for (final row in rows)
        (row['cost_center_id'] as num?)?.toInt():
            (row['debit_minor'] as num).toInt(),
    };
  }

  Future<int> journalOf(String table, int id) async {
    final db = await helper.database;
    final rows = await db.query(
      table,
      columns: ['journal_entry_id'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.single['journal_entry_id'] as int;
  }

  group('rent invoice attributes revenue to the property cost centre', () {
    test('invoice revenue line carries the property cost centre', () async {
      final center = await makeCostCenter('CC-1', 'عقار واحد');
      final seeded = await seedContract(suffix: '1', costCenterId: center);
      final revenueId = await account('4101');
      final taxId = await account('2103');

      final invoiceId = await helper.insertTaxInvoice(
        contractId: seeded.contractId,
        tenantId: seeded.tenantId,
        installmentId: seeded.installments.first['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueId,
        taxAccountId: taxId,
      );

      final journalId = await journalOf('tax_invoices', invoiceId);
      final credits = await costCenterCredits(journalId);
      // Revenue 100.00 goes to the property centre; tax 15.00 stays unattributed.
      expect(credits[center], 10000);
      expect(credits[null], 1500);
      final debits = await costCenterDebits(journalId);
      expect(debits[null], 11500);
      expect(
        credits.values.fold<int>(0, (a, b) => a + b),
        debits.values.fold<int>(0, (a, b) => a + b),
      );
    });

    test('a property with no cost centre leaves the line unattributed',
        () async {
      final seeded = await seedContract(suffix: '2');
      final revenueId = await account('4101');
      final taxId = await account('2103');

      final invoiceId = await helper.insertTaxInvoice(
        contractId: seeded.contractId,
        tenantId: seeded.tenantId,
        installmentId: seeded.installments.first['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueId,
        taxAccountId: taxId,
      );

      final journalId = await journalOf('tax_invoices', invoiceId);
      final credits = await costCenterCredits(journalId);
      expect(credits.keys, everyElement(isNull));
      expect(credits[null], 11500);
    });
  });

  group('receipt splits across the cost centres of its sources', () {
    test('one installment posts one attributed line', () async {
      final center = await makeCostCenter('CC-A', 'عقار أ');
      final seeded = await seedContract(suffix: '3', costCenterId: center);
      final cashId = await account('1101');

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 100.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': seeded.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
        ],
      );

      final journalId = await journalOf('vouchers', receiptId);
      final credits = await costCenterCredits(journalId);
      expect(credits, {center: 10000});
      final debits = await costCenterDebits(journalId);
      expect(debits, {null: 10000});
    });

    test('a receipt covering two properties is split, not dumped on one',
        () async {
      final centerA = await makeCostCenter('CC-M1', 'عقار م1');
      final centerB = await makeCostCenter('CC-M2', 'عقار م2');
      final first = await seedContract(suffix: '4', costCenterId: centerA);
      final db = await helper.database;

      // A second contract for the same tenant on a different property.
      final secondOwnerId = await db.insert('owners', {'name': 'مالك م2'});
      final secondPropertyId = await db.insert('properties', {
        'name': 'عقار م2',
        'owner_id': secondOwnerId,
        'cost_center_id': centerB,
      });
      final secondUnitId = await db.insert('units', {
        'property_id': secondPropertyId,
        'unit_number': 'U-M2',
        'default_rent': 60.0,
        'default_rent_period': 'monthly',
      });
      final secondContractId = await helper.insertContractWithInstallments({
        'tenant_id': first.tenantId,
        'unit_id': secondUnitId,
        'start_date': '2026-11-10',
        'end_date': '2027-11-09',
        'rent_amount': 60.0,
        'payment_method': 'شهري',
        'status': 'Active',
      }, [
        {
          'amount': 60.0,
          'paid_amount': 0.0,
          'due_date': '2026-11-10',
          'status': 'Unpaid',
        },
      ]);
      final secondInstallments = await helper.getInstallmentsForContract(
        secondContractId,
      );

      final cashId = await account('1101');
      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: first.tenantId,
        amount: 160.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': first.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
          {
            'id': secondInstallments.first['id'],
            'paid_amount': 60.0,
            'status': 'Paid',
          },
        ],
      );

      final journalId = await journalOf('vouchers', receiptId);
      final credits = await costCenterCredits(journalId);
      expect(credits[centerA], 10000);
      expect(credits[centerB], 6000);
      expect(credits.values.fold<int>(0, (a, b) => a + b), 16000);
      final debits = await costCenterDebits(journalId);
      expect(debits, {null: 16000});
      expect(
        credits.values.fold<int>(0, (a, b) => a + b),
        debits.values.fold<int>(0, (a, b) => a + b),
      );
    });

    test('a mixed receipt keeps unattributed sources out of the centre',
        () async {
      final centerA = await makeCostCenter('CC-X1', 'عقار س1');
      final first = await seedContract(suffix: '5', costCenterId: centerA);
      final db = await helper.database;

      final secondOwnerId = await db.insert('owners', {'name': 'مالك س2'});
      final secondPropertyId = await db.insert('properties', {
        'name': 'عقار بلا مركز',
        'owner_id': secondOwnerId,
      });
      final secondUnitId = await db.insert('units', {
        'property_id': secondPropertyId,
        'unit_number': 'U-S2',
        'default_rent': 60.0,
        'default_rent_period': 'monthly',
      });
      final secondContractId = await helper.insertContractWithInstallments({
        'tenant_id': first.tenantId,
        'unit_id': secondUnitId,
        'start_date': '2026-11-10',
        'end_date': '2027-11-09',
        'rent_amount': 60.0,
        'payment_method': 'شهري',
        'status': 'Active',
      }, [
        {
          'amount': 60.0,
          'paid_amount': 0.0,
          'due_date': '2026-11-10',
          'status': 'Unpaid',
        },
      ]);
      final secondInstallments = await helper.getInstallmentsForContract(
        secondContractId,
      );

      final cashId = await account('1101');
      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: first.tenantId,
        amount: 160.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': first.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
          {
            'id': secondInstallments.first['id'],
            'paid_amount': 60.0,
            'status': 'Paid',
          },
        ],
      );

      final journalId = await journalOf('vouchers', receiptId);
      final credits = await costCenterCredits(journalId);
      expect(credits[centerA], 10000);
      expect(credits[null], 6000);
    });
  });

  group('receipt settling a tax invoice', () {
    test('invoice payment keeps the whole amount on the property centre',
        () async {
      final center = await makeCostCenter('CC-INV', 'عقار فاتورة');
      final seeded = await seedContract(suffix: '10', costCenterId: center);
      final revenueId = await account('4101');
      final taxId = await account('2103');
      final cashId = await account('1101');

      final invoiceId = await helper.insertTaxInvoice(
        contractId: seeded.contractId,
        tenantId: seeded.tenantId,
        installmentId: seeded.installments.first['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueId,
        taxAccountId: taxId,
      );

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 115.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        invoiceId: invoiceId,
        installmentsToUpdate: const [],
      );

      final journalId = await journalOf('vouchers', receiptId);
      final credits = await costCenterCredits(journalId);
      // The invoice settlement belongs to the invoice's property, not to a
      // separate centre, and no cent is lost when rent and tax are combined.
      expect(credits, {center: 11500});
      final debits = await costCenterDebits(journalId);
      expect(debits, {null: 11500});
    });
  });

  group('refund attributes to the original receipt source', () {
    test('refund debit carries the centre of the refunded installment',
        () async {
      final center = await makeCostCenter('CC-R', 'عقار رد');
      final seeded = await seedContract(suffix: '6', costCenterId: center);
      final cashId = await account('1101');

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 100.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': seeded.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
        ],
      );
      final db = await helper.database;
      final allocationId =
          (await db.query(
                'collection_allocations',
                columns: ['id'],
                where: 'voucher_id = ?',
                whereArgs: [receiptId],
                limit: 1,
              )).single['id']
              as int;

      final refundId = await helper.insertTenantRefundVoucher(
        tenantId: seeded.tenantId,
        amount: 40.0,
        voucherDate: '2026-11-11',
        cashAccountId: cashId,
        collectionAllocationId: allocationId,
        description: 'رد جزئي',
      );

      final journalId = await journalOf('vouchers', refundId);
      final debits = await costCenterDebits(journalId);
      expect(debits, {center: 4000});
      final credits = await costCenterCredits(journalId);
      expect(credits, {null: 4000});
    });

    test('a refund on a property without a centre stays unattributed',
        () async {
      final seeded = await seedContract(suffix: '7');
      final cashId = await account('1101');

      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 100.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': seeded.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
        ],
      );
      final db = await helper.database;
      final allocationId =
          (await db.query(
                'collection_allocations',
                columns: ['id'],
                where: 'voucher_id = ?',
                whereArgs: [receiptId],
                limit: 1,
              )).single['id']
              as int;

      final refundId = await helper.insertTenantRefundVoucher(
        tenantId: seeded.tenantId,
        amount: 25.0,
        voucherDate: '2026-11-11',
        cashAccountId: cashId,
        collectionAllocationId: allocationId,
        description: 'رد بلا مركز',
      );

      final journalId = await journalOf('vouchers', refundId);
      final debits = await costCenterDebits(journalId);
      expect(debits.keys, everyElement(isNull));
      expect(debits[null], 2500);
    });
  });

  group('balances and totals survive the attribution', () {
    test('journal stays balanced to the cent for every attributed writer',
        () async {
      final center = await makeCostCenter('CC-B', 'عقار اتزان');
      final seeded = await seedContract(
        suffix: '8',
        costCenterId: center,
        installmentCount: 3,
      );
      final cashId = await account('1101');
      final revenueId = await account('4101');
      final taxId = await account('2103');

      final invoiceId = await helper.insertTaxInvoice(
        contractId: seeded.contractId,
        tenantId: seeded.tenantId,
        installmentId: seeded.installments[0]['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueId,
        taxAccountId: taxId,
      );
      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 160.0,
        voucherDate: '2026-11-12',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': seeded.installments[1]['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
          {
            'id': seeded.installments[2]['id'],
            'paid_amount': 60.0,
            'status': 'Partially Paid',
          },
        ],
      );

      final db = await helper.database;
      for (final journalId in [
        await journalOf('tax_invoices', invoiceId),
        await journalOf('vouchers', receiptId),
      ]) {
        final totals = await db.rawQuery(
          '''
          SELECT CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER) AS debit_minor,
                 CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER) AS credit_minor
          FROM journal_lines jl WHERE jl.journal_entry_id = ?
          ''',
          [journalId],
        );
        expect(totals.single['debit_minor'], totals.single['credit_minor']);
        expect((totals.single['debit_minor'] as num).toInt(), greaterThan(0));
      }
    });

    test('account balances match the journal lines after attribution',
        () async {
      final center = await makeCostCenter('CC-T', 'عقار أرصدة');
      final seeded = await seedContract(suffix: '9', costCenterId: center);
      final cashId = await account('1101');

      await helper.insertTenantReceiptVoucher(
        tenantId: seeded.tenantId,
        amount: 100.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashId,
        installmentsToUpdate: [
          {
            'id': seeded.installments.first['id'],
            'paid_amount': 100.0,
            'status': 'Paid',
          },
        ],
      );

      final db = await helper.database;
      final accounts = await db.rawQuery('''
        SELECT a.id AS id, a.balance AS balance FROM accounts a
        WHERE NOT EXISTS (SELECT 1 FROM accounts child WHERE child.parent_id = a.id)
      ''');
      for (final row in accounts) {
        final accountId = row['id'] as int;
        final stored = ((row['balance'] as num?) ?? 0).toDouble();
        final computed = await db.rawQuery(
          '''
          SELECT COALESCE(SUM(jl.debit), 0) - COALESCE(SUM(jl.credit), 0) AS net
          FROM journal_lines jl WHERE jl.account_id = ?
          ''',
          [accountId],
        );
        final net = ((computed.single['net'] as num?) ?? 0).toDouble();
        expect(
          InternalTax.toMinorUnits(stored),
          InternalTax.toMinorUnits(net),
          reason: 'account $accountId drifted from its journal lines',
        );
      }
    });
  });
}
