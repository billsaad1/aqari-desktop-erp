import 'dart:io';

import 'package:app/core/crypto_utils.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_erp_flutter_test';

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory')
            return testDocuments;
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await DatabaseHelper.instance.close();
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('credential hashing', () {
    test(
      'uses salted PBKDF2 and verifies without accepting wrong passwords',
      () {
        final first = CryptoUtils.hashPassword('A-strong-password-2026');
        final second = CryptoUtils.hashPassword('A-strong-password-2026');
        expect(first, startsWith('pbkdf2_sha256\$'));
        expect(first, isNot(second));
        expect(
          CryptoUtils.verifyPassword('A-strong-password-2026', first),
          isTrue,
        );
        expect(CryptoUtils.verifyPassword('wrong-password', first), isFalse);
      },
    );

    test('can authenticate legacy SHA-256 hashes for migration', () {
      const legacyAdminHash =
          '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92';
      expect(CryptoUtils.isLegacyHash(legacyAdminHash), isTrue);
      expect(CryptoUtils.verifyPassword('123456', legacyAdminHash), isTrue);
      expect(
        CryptoUtils.verifyPassword('not-123456', legacyAdminHash),
        isFalse,
      );
    });
  });

  test(
    'creates a valid Arabic voucher PDF and a consistent SQLite backup',
    () async {
      final db = await DatabaseHelper.instance.database;
      final info = await DatabaseHelper.instance.getCompanyInfo();
      expect(info?['name_ar'], isNotEmpty);

      final summary = await DatabaseHelper.instance.getDashboardSummary();
      expect(summary['properties_count'], 0);
      expect(summary['units_count'], 0);

      final pdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: 17,
        date: '2026-11-10',
        targetName: 'مستأجر تجريبي',
        amount: 1250.50,
        paymentMethod: 'نقداً',
        accountName: 'الصندوق الرئيسي',
        description: 'دفعة إيجار اختبارية',
      );
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      expect(PrintUtils.suggestedPdfName('سند قبض/17'), 'سند_قبض_17.pdf');

      final backupPath = '$testDocuments/aqari-test-backup.db';
      await DatabaseHelper.instance.backupToFile(backupPath);
      final backup = File(backupPath);
      expect(await backup.exists(), isTrue);
      expect(await backup.length(), greaterThan(0));

      // Keep the primary test database usable until tearDownAll; remove only the snapshot.
      await backup.delete();
      await db.rawQuery('PRAGMA integrity_check');
    },
  );

  test(
    'posts leasing receipts and invoices atomically and rejects invalid duplicates',
    () async {
      final db = await DatabaseHelper.instance.database;
      final ownerId = await db.insert('owners', {'name': 'مالك الاختبار'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار الاختبار',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'T-01',
      });
      await DatabaseHelper.instance.insertTenantWithAccount({
        'name': 'مستأجر الاختبار',
        'mobile': '777000000',
      });
      final tenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر الاختبار'],
      )).single;
      final tenantId = tenant['id'] as int;

      final installments = List.generate(12, (index) {
        final due = DateTime(2026, 11 + index, 10);
        return {
          'amount': 100.0,
          'paid_amount': 0.0,
          'due_date': due.toIso8601String().substring(0, 10),
          'status': 'Unpaid',
        };
      });
      final contractId = await DatabaseHelper.instance
          .insertContractWithInstallments({
            'tenant_id': tenantId,
            'unit_id': unitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-10',
            'rent_amount': 1200.0,
            'payment_method': 'شهري',
            'status': 'Active',
          }, installments);
      expect(contractId, greaterThan(0));

      final storedInstallments = await DatabaseHelper.instance
          .getInstallmentsForContract(contractId);
      final cashAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['1101'],
              )).single['id']
              as int;
      final receiptId = await DatabaseHelper.instance
          .insertTenantReceiptVoucher(
            tenantId: tenantId,
            amount: 150.0,
            voucherDate: '2026-11-10',
            cashAccountId: cashAccountId,
            installmentsToUpdate: [
              {
                'id': storedInstallments[0]['id'],
                'paid_amount': 100.0,
                'status': 'Paid',
              },
              {
                'id': storedInstallments[1]['id'],
                'paid_amount': 50.0,
                'status': 'Partially Paid',
              },
            ],
          );
      expect(receiptId, greaterThan(0));

      final revenueAccount = (await db.query(
        'accounts',
        where: "account_type = 'Revenue' AND parent_id IS NOT NULL",
        limit: 1,
      )).single;
      final generalVoucherId = await DatabaseHelper.instance
          .insertGeneralVoucher(
            {
              'voucher_type': 'قبض عام',
              'voucher_date': '2026-11-10',
              'amount': 20.0,
              'description': 'اختبار',
            },
            cashAccountId,
            revenueAccount['id'] as int,
            null,
            'قبض عام',
          );
      expect(generalVoucherId, greaterThan(0));

      final taxAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['2103'],
              )).single['id']
              as int;
      final invoiceId = await DatabaseHelper.instance.insertTaxInvoice(
        contractId: contractId,
        tenantId: tenantId,
        invoiceDate: '2026-11-10',
        totalAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueAccount['id'] as int,
        taxAccountId: taxAccountId,
      );
      expect(invoiceId, greaterThan(0));

      await expectLater(
        DatabaseHelper.instance.insertTaxInvoice(
          contractId: contractId,
          tenantId: tenantId,
          invoiceDate: '2026-11-10',
          totalAmount: 100.0,
          taxAmount: 15.0,
          revenueAccountId: revenueAccount['id'] as int,
          taxAccountId: taxAccountId,
        ),
        throwsStateError,
      );

      final summary = await DatabaseHelper.instance.getDashboardSummary();
      expect((summary['outstanding_amount'] as num).toDouble(), 1050.0);
      final before =
          (await db.rawQuery(
                'SELECT COUNT(*) AS count FROM journal_entries',
              )).single['count']
              as int;
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-11-10',
            'amount': 10.0,
          },
          cashAccountId,
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4'],
              )).single['id']
              as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      final after =
          (await db.rawQuery(
                'SELECT COUNT(*) AS count FROM journal_entries',
              )).single['count']
              as int;
      expect(after, before);
      final groupRevenueId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4'],
              )).single['id']
              as int;
      await expectLater(
        DatabaseHelper.instance.insertJournalEntryWithLines(
          {
            'entry_date': '2026-11-10',
            'description': 'قيد بحساب تجميعي',
            'is_posted': 1,
          },
          [
            {'account_id': cashAccountId, 'debit': 1.0, 'credit': 0.0},
            {'account_id': groupRevenueId, 'debit': 0.0, 'credit': 1.0},
          ],
        ),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM journal_entries',
        )).single['count'],
        before,
      );
      await expectLater(
        DatabaseHelper.instance.insertContractWithInstallments({
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': '2026-11-10',
          'end_date': '2027-11-10',
          'rent_amount': 1200.0,
          'payment_method': 'شهري',
          'status': 'Active',
        }, installments),
        throwsStateError,
      );
    },
  );
}
