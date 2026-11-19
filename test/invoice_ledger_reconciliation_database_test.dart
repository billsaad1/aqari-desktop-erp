import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/invoice_ledger_reconciliation_report_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_invoice_ledger_reconciliation_test';
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
    'reconciles posted invoice entries and flags source or ledger defects',
    () async {
      final db = await helper.database;
      await helper.insertTenantWithAccount({
        'name': 'مستأجر اختبار المطابقة',
        'mobile': '777820001',
      });
      final tenant = (await db.query(
        'tenants',
        columns: ['id', 'name', 'account_id'],
        where: 'name = ?',
        whereArgs: ['مستأجر اختبار المطابقة'],
        limit: 1,
      )).single;
      final tenantId = (tenant['id'] as num).toInt();
      final tenantAccountId = (tenant['account_id'] as num).toInt();
      final revenueAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: 'code = ?',
                    whereArgs: ['4101'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      final taxAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: 'code = ?',
                    whereArgs: ['2103'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      final otherLiabilityAccountId =
          ((await db.query(
                    'accounts',
                    columns: ['id'],
                    where: 'code = ?',
                    whereArgs: ['2101'],
                    limit: 1,
                  )).single['id']
                  as num)
              .toInt();
      final ownerId = await db.insert('owners', {
        'name': 'مالك اختبار المطابقة',
      });
      final propertyId = await db.insert('properties', {
        'name': 'عقار اختبار المطابقة',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'R-21',
        'status': 'مؤجرة',
      });
      final contractId = await db.insert('contracts', {
        'tenant_id': tenantId,
        'unit_id': unitId,
        'start_date': '2026-03-01',
        'end_date': '2027-02-28',
        'rent_amount': 1000.0,
        'status': 'Active',
      });
      final secondUnitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'R-22',
        'status': 'مؤجرة',
      });
      final secondContractId = await db.insert('contracts', {
        'tenant_id': tenantId,
        'unit_id': secondUnitId,
        'start_date': '2026-03-01',
        'end_date': '2027-02-28',
        'rent_amount': 500.0,
        'status': 'Active',
      });

      Future<int> insertInstallment({
        int? forContractId,
        required double amount,
      }) => db.insert('contract_installments', {
        'contract_id': forContractId ?? contractId,
        'amount': amount,
        'paid_amount': 0.0,
        'due_date': '2026-03-15',
        'status': 'Unpaid',
      });

      Future<int> insertJournal({
        required String date,
        required int isPosted,
        required List<Map<String, Object?>> lines,
      }) async {
        final journalId = await db.insert('journal_entries', {
          'entry_date': date,
          'description': 'قيد اختبار مطابقة فاتورة',
          'is_posted': isPosted,
        });
        for (final line in lines) {
          await db.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': line['account_id'],
            'debit': line['debit'],
            'credit': line['credit'],
            'description': line['description'] ?? 'سطر قيد اختباري',
          });
        }
        return journalId;
      }

      Future<int> insertInvoice({
        required String date,
        required double net,
        required double tax,
        required double total,
        int? journalId,
        int? installmentContractId,
        double? installmentAmount,
        bool omitTaxAccountSource = false,
        bool omitContractLink = false,
        bool omitInstallmentLink = false,
      }) async => db.insert('tax_invoices', {
        'contract_id': omitContractLink ? null : contractId,
        'installment_id': omitInstallmentLink
            ? null
            : await insertInstallment(
                forContractId: installmentContractId,
                amount: installmentAmount ?? net,
              ),
        'journal_entry_id': journalId,
        'invoice_date': date,
        'net_amount': net,
        'tax_amount': tax,
        'total_amount': total,
        'tax_rate': tax == 0 ? 0.0 : 15.0,
        'tax_account_id': tax == 0 || omitTaxAccountSource
            ? null
            : taxAccountId,
      });

      final validJournalId = await insertJournal(
        date: '2026-03-01',
        isPosted: 1,
        lines: [
          {'account_id': tenantAccountId, 'debit': 115.26, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 100.23},
          {
            'account_id': taxAccountId,
            'debit': 0.0,
            'credit': 15.03,
            'description': 'ضريبة قيمة مضافة',
          },
        ],
      );
      final validId = await insertInvoice(
        date: '2026-03-01',
        net: 100.23,
        tax: 15.03,
        total: 115.26,
        journalId: validJournalId,
      );
      final wrongTaxJournalId = await insertJournal(
        date: '2026-03-01',
        isPosted: 1,
        lines: [
          {'account_id': tenantAccountId, 'debit': 115.26, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 100.23},
          {
            'account_id': otherLiabilityAccountId,
            'debit': 0.0,
            'credit': 15.03,
            'description': 'التزام آخر',
          },
        ],
      );
      final wrongTaxId = await insertInvoice(
        date: '2026-03-01',
        net: 100.23,
        tax: 15.03,
        total: 115.26,
        journalId: wrongTaxJournalId,
      );
      final legacyTaxWithoutAccountId = await insertInvoice(
        date: '2026-03-09',
        net: 10,
        tax: 1.5,
        total: 11.5,
        omitTaxAccountSource: true,
      );

      final missingLinkId = await insertInvoice(
        date: '2026-03-02',
        net: 50,
        tax: 0,
        total: 50,
      );

      final unpostedJournalId = await insertJournal(
        date: '2026-03-03',
        isPosted: 0,
        lines: [
          {'account_id': tenantAccountId, 'debit': 60.0, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 60.0},
        ],
      );
      final unpostedId = await insertInvoice(
        date: '2026-03-03',
        net: 60,
        tax: 0,
        total: 60,
        journalId: unpostedJournalId,
      );

      final mismatchJournalId = await insertJournal(
        date: '2026-03-04',
        isPosted: 1,
        lines: [
          {'account_id': tenantAccountId, 'debit': 46.0, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 39.0},
          {'account_id': taxAccountId, 'debit': 0.0, 'credit': 7.0},
        ],
      );
      final mismatchId = await insertInvoice(
        date: '2026-03-04',
        net: 40,
        tax: 6,
        total: 46,
        journalId: mismatchJournalId,
      );

      final duplicateJournalId = await insertJournal(
        date: '2026-03-05',
        isPosted: 1,
        lines: [
          {'account_id': tenantAccountId, 'debit': 20.0, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 20.0},
        ],
      );
      final duplicateOneId = await insertInvoice(
        date: '2026-03-05',
        net: 20,
        tax: 0,
        total: 20,
        journalId: duplicateJournalId,
      );
      final duplicateTwoId = await insertInvoice(
        date: '2026-03-05',
        net: 20,
        tax: 0,
        total: 20,
        journalId: duplicateJournalId,
      );

      final arithmeticMismatchId = await insertInvoice(
        date: '2026-03-06',
        net: 30,
        tax: 5,
        total: 34,
      );
      final sourceContractMismatchId = await insertInvoice(
        date: '2026-03-07',
        net: 10,
        tax: 0,
        total: 10,
        installmentContractId: secondContractId,
      );
      final installmentAmountMismatchId = await insertInvoice(
        date: '2026-03-08',
        net: 12,
        tax: 0,
        total: 12,
        installmentAmount: 11,
      );
      final missingInstallmentId = await insertInvoice(
        date: '2026-03-09',
        net: 10,
        tax: 0,
        total: 10,
        omitInstallmentLink: true,
      );
      final missingContractId = await insertInvoice(
        date: '2026-03-10',
        net: 10,
        tax: 0,
        total: 10,
        omitContractLink: true,
      );

      final endDayJournalId = await insertJournal(
        date: '2026-03-31T23:59:59',
        isPosted: 1,
        lines: [
          {'account_id': tenantAccountId, 'debit': 25.0, 'credit': 0.0},
          {'account_id': revenueAccountId, 'debit': 0.0, 'credit': 25.0},
        ],
      );
      final endDayId = await insertInvoice(
        date: '2026-03-31T23:59:59',
        net: 25,
        tax: 0,
        total: 25,
        journalId: endDayJournalId,
      );
      await insertInvoice(date: '2026-02-28', net: 70, tax: 0, total: 70);

      final invoiceCountBefore = (await db.query('tax_invoices')).length;
      final journalCountBefore = (await db.query('journal_entries')).length;
      final report = await helper.getInvoiceLedgerReconciliationReport(
        startDate: '2026-03-01',
        endDate: '2026-03-31',
      );

      final byId = {for (final row in report.rows) row.invoiceId: row};
      expect(report.currency, isNotEmpty);
      expect(report.invoiceCount, 14);
      expect(byId[validId]!.isReconciled, isTrue);
      expect(byId[validId]!.journalDebitMinor, 11526);
      expect(byId[validId]!.revenueCreditMinor, 10023);
      expect(byId[validId]!.taxLiabilityCreditMinor, 1503);
      expect(byId[wrongTaxId]!.taxLiabilityCreditMinor, 0);
      expect(
        byId[wrongTaxId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.taxLiabilityMismatch),
      );
      expect(
        byId[legacyTaxWithoutAccountId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.missingTaxAccountSource),
      );
      expect(
        byId[missingLinkId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.missingJournalLink),
      );
      expect(
        byId[unpostedId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.journalNotPosted),
      );
      expect(
        byId[mismatchId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.revenueMismatch),
      );
      expect(
        byId[mismatchId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.taxLiabilityMismatch),
      );
      expect(
        byId[duplicateOneId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.duplicateJournalLink),
      );
      expect(
        byId[duplicateTwoId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.duplicateJournalLink),
      );
      expect(
        byId[arithmeticMismatchId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.invoiceTotalMismatch),
      );
      expect(
        byId[sourceContractMismatchId]!.issues,
        contains(
          InvoiceLedgerReconciliationIssue.invoiceInstallmentContractMismatch,
        ),
      );
      expect(
        byId[installmentAmountMismatchId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.installmentAmountMismatch),
      );
      expect(byId[installmentAmountMismatchId]!.installmentAmountMinor, 1100);
      expect(
        byId[missingInstallmentId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.missingInvoiceInstallment),
      );
      expect(
        byId[missingContractId]!.issues,
        contains(InvoiceLedgerReconciliationIssue.missingInvoiceContract),
      );
      expect(byId[endDayId], isNotNull, reason: 'the final date is inclusive');
      expect(report.reviewCount, 12);
      expect((await db.query('tax_invoices')).length, invoiceCountBefore);
      expect((await db.query('journal_entries')).length, journalCountBefore);

      await expectLater(
        helper.getInvoiceLedgerReconciliationReport(
          startDate: '2026-03-31',
          endDate: '2026-03-01',
        ),
        throwsArgumentError,
      );

      PermissionRuntime.activate(
        userId: 2,
        role: 'DataEntry',
        permissionRows: const [],
      );
      await expectLater(
        helper.getInvoiceLedgerReconciliationReport(
          startDate: '2026-03-01',
          endDate: '2026-03-31',
        ),
        throwsStateError,
      );
    },
  );
}
