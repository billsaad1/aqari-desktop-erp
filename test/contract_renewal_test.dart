import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final helper = DatabaseHelper.instance;
  final testDirectory = Directory.systemTemp.createTempSync(
    'aqari_contract_renewal_',
  );
  final testDocuments = testDirectory.path;

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
    await directory.create(recursive: true);
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
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test(
    'renewal preserves the original schedule, receipt, invoice and journal history',
    () async {
      final db = await helper.database;
      final ownerId = await db.insert('owners', {'name': 'مالك تجديد'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار تجديد',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'R-01',
        'default_rent': 100.0,
        'default_rent_period': 'monthly',
      });
      await helper.insertTenantWithAccount({
        'name': 'مستأجر تجديد',
        'mobile': '777900001',
      });
      final tenantId =
          (await db.query(
                'tenants',
                where: 'mobile = ?',
                whereArgs: ['777900001'],
              )).single['id']
              as int;

      final oldContractId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': '2026-11-10',
          'end_date': '2026-12-09',
          'rent_amount': 100.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': '2026-11-10',
            'status': 'Unpaid',
          },
        ],
      );
      final oldInstallment = (await db.query(
        'contract_installments',
        where: 'contract_id = ?',
        whereArgs: [oldContractId],
      )).single;
      final cashAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['1101'],
              )).single['id']
              as int;
      final receiptId = await helper.insertTenantReceiptVoucher(
        tenantId: tenantId,
        amount: 30.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashAccountId,
        installmentsToUpdate: [
          {
            'id': oldInstallment['id'],
            'paid_amount': 30.0,
            'status': 'Partially Paid',
          },
        ],
      );

      await helper.updateCompanyInfo({'tax_rate': 0.0});
      final revenueAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4101'],
              )).single['id']
              as int;
      final invoiceId = await helper.insertTaxInvoice(
        contractId: oldContractId,
        tenantId: tenantId,
        installmentId: oldInstallment['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 0.0,
        revenueAccountId: revenueAccountId,
        taxAccountId: null,
      );

      final installmentBeforeRenewal = (await db.query(
        'contract_installments',
        where: 'id = ?',
        whereArgs: [oldInstallment['id']],
      )).single;
      final invoiceBeforeRenewal = (await db.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
      )).single;
      final receiptBeforeRenewal = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [receiptId],
      )).single;
      final invoiceJournalLinesBeforeRenewal = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [invoiceBeforeRenewal['journal_entry_id']],
        orderBy: 'id',
      );
      final receiptJournalLinesBeforeRenewal = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [receiptBeforeRenewal['journal_entry_id']],
        orderBy: 'id',
      );
      Future<int> rowCount(String table) async =>
          (await db.rawQuery(
                'SELECT COUNT(*) AS count FROM $table',
              )).single['count']
              as int;
      final financialCountsBeforeRenewal = {
        'tax_invoices': await rowCount('tax_invoices'),
        'vouchers': await rowCount('vouchers'),
        'journal_entries': await rowCount('journal_entries'),
      };

      final renewalId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': '2026-12-10',
          'end_date': '2027-12-09',
          'rent_amount': 1200.0,
          'payment_method': 'سنوي',
          'status': 'Active',
        },
        [
          {
            'amount': 1200.0,
            'paid_amount': 0.0,
            'due_date': '2026-12-10',
            'status': 'Unpaid',
          },
        ],
        renewedFromContractId: oldContractId,
      );

      final oldContractAfterRenewal = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [oldContractId],
      )).single;
      final renewal = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [renewalId],
      )).single;
      expect(oldContractAfterRenewal['status'], 'Active');
      expect(oldContractAfterRenewal['renewed_from_contract_id'], isNull);
      expect(renewal['renewed_from_contract_id'], oldContractId);
      expect(renewal['tenant_id'], tenantId);
      expect(renewal['unit_id'], unitId);
      expect(renewal['rent_amount'], 1200.0);
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [unitId],
        )).single['status'],
        'مؤجرة',
      );
      expect(
        (await db.query(
          'contract_installments',
          where: 'contract_id = ?',
          whereArgs: [oldContractId],
        )).single,
        installmentBeforeRenewal,
      );
      expect(
        (await db.query(
          'tax_invoices',
          where: 'id = ?',
          whereArgs: [invoiceId],
        )).single,
        invoiceBeforeRenewal,
      );
      expect(
        (await db.query(
          'vouchers',
          where: 'id = ?',
          whereArgs: [receiptId],
        )).single,
        receiptBeforeRenewal,
      );
      expect(
        await db.query(
          'journal_lines',
          where: 'journal_entry_id = ?',
          whereArgs: [invoiceBeforeRenewal['journal_entry_id']],
          orderBy: 'id',
        ),
        invoiceJournalLinesBeforeRenewal,
      );
      expect(
        await db.query(
          'journal_lines',
          where: 'journal_entry_id = ?',
          whereArgs: [receiptBeforeRenewal['journal_entry_id']],
          orderBy: 'id',
        ),
        receiptJournalLinesBeforeRenewal,
      );
      for (final entry in financialCountsBeforeRenewal.entries) {
        expect(await rowCount(entry.key), entry.value, reason: entry.key);
      }
      final contracts = await helper.getAllContracts();
      final oldContractInList = contracts.singleWhere(
        (contract) => contract['id'] == oldContractId,
      );
      expect(oldContractInList['renewed_to_contract_id'], renewalId);

      await expectLater(
        helper.insertContractWithInstallments(
          {
            'tenant_id': tenantId,
            'unit_id': unitId,
            'start_date': '2026-12-09',
            'end_date': '2027-12-08',
            'rent_amount': 1200.0,
            'payment_method': 'سنوي',
            'status': 'Active',
          },
          [
            {
              'amount': 1200.0,
              'paid_amount': 0.0,
              'due_date': '2026-12-09',
              'status': 'Unpaid',
            },
          ],
          renewedFromContractId: oldContractId,
        ),
        throwsStateError,
      );
      await expectLater(
        helper.cancelContract(oldContractId, reason: 'اختبار حماية التجديد'),
        throwsStateError,
      );
      await expectLater(
        helper.insertContractWithInstallments(
          {
            'tenant_id': tenantId,
            'unit_id': unitId,
            'start_date': '2026-12-10',
            'end_date': '2027-12-09',
            'rent_amount': 1200.0,
            'payment_method': 'سنوي',
            'status': 'Active',
          },
          [
            {
              'amount': 1200.0,
              'paid_amount': 0.0,
              'due_date': '2026-12-10',
              'status': 'Unpaid',
            },
          ],
          renewedFromContractId: oldContractId,
        ),
        throwsStateError,
      );
      await expectLater(
        helper.insertContractWithInstallments(
          {
            'tenant_id': tenantId,
            'unit_id': unitId,
            'start_date': '2026-12-10',
            'end_date': '2027-12-10',
            'rent_amount': 1200.0,
            'payment_method': 'سنوي',
            'status': 'Active',
          },
          [
            {
              'amount': 1200.0,
              'paid_amount': 0.0,
              'due_date': '2026-12-10',
              'status': 'Unpaid',
            },
          ],
          renewedFromContractId: oldContractId,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'cancelling an expired unpaid renewal frees the unit without cancelling its source',
    () async {
      final db = await helper.database;
      final ownerId = await db.insert('owners', {'name': 'مالك إلغاء التجديد'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار إلغاء التجديد',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'R-02',
        'default_rent': 100.0,
        'default_rent_period': 'monthly',
      });
      await helper.insertTenantWithAccount({
        'name': 'مستأجر إلغاء التجديد',
        'mobile': '777900002',
      });
      final tenantId =
          (await db.query(
                'tenants',
                where: 'mobile = ?',
                whereArgs: ['777900002'],
              )).single['id']
              as int;
      final sourceStart = DateTime(DateTime.now().year - 3, 1, 1);
      final sourceEnd = DateTime(sourceStart.year, 2, 0);
      final renewalStart = sourceEnd.add(const Duration(days: 1));
      final renewalEnd = DateTime(
        renewalStart.year + 1,
        renewalStart.month,
        renewalStart.day,
      ).subtract(const Duration(days: 1));
      String date(DateTime value) => value.toIso8601String().split('T').first;

      final sourceId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': date(sourceStart),
          'end_date': date(sourceEnd),
          'rent_amount': 100.0,
          'payment_method': 'شهري',
          'status': 'Active',
        },
        [
          {
            'amount': 100.0,
            'paid_amount': 0.0,
            'due_date': date(sourceStart),
            'status': 'Unpaid',
          },
        ],
      );
      final renewalId = await helper.insertContractWithInstallments(
        {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': date(renewalStart),
          'end_date': date(renewalEnd),
          'rent_amount': 1200.0,
          'payment_method': 'سنوي',
          'status': 'Active',
        },
        [
          {
            'amount': 1200.0,
            'paid_amount': 0.0,
            'due_date': date(renewalStart),
            'status': 'Unpaid',
          },
        ],
        renewedFromContractId: sourceId,
      );

      await helper.cancelContract(renewalId, reason: 'انتهاء الاتفاق');

      expect(
        (await db.query(
          'contracts',
          where: 'id = ?',
          whereArgs: [sourceId],
        )).single['status'],
        'Active',
      );
      expect(
        (await db.query(
          'contracts',
          where: 'id = ?',
          whereArgs: [renewalId],
        )).single['status'],
        'Cancelled',
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [unitId],
        )).single['status'],
        'شاغرة',
      );
    },
  );

  test(
    'schema v24 stores the self-referencing renewal link and guards it',
    () async {
      final db = await helper.database;
      final columns = await db.rawQuery('PRAGMA table_info(contracts)');
      expect(
        columns.map((column) => column['name']),
        contains('renewed_from_contract_id'),
      );
      final version = (await db.rawQuery(
        'PRAGMA user_version',
      )).single['user_version'];
      expect(version, DatabaseHelper.schemaVersion);
      final triggers = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'contracts'",
      )).map((row) => row['name']);
      expect(
        triggers,
        containsAll([
          'contracts_renewal_link_valid_insert',
          'contracts_renewal_link_immutable',
        ]),
      );
    },
  );
}
