import 'dart:io';
import 'dart:convert';

import 'package:app/core/arabic_amount_words.dart';
import 'package:app/core/crypto_utils.dart';
import 'package:app/core/company_logo_storage.dart';
import 'package:app/core/lease_contract_pdf.dart';
import 'package:app/core/lease_contract_terms.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/tenant_financial/voucher_history_screen.dart';
import 'package:app/features/tenants_leasing/tenants_screen.dart';
import 'package:app/providers/leasing_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_erp_flutter_test';

  setUpAll(() async {
    final staleTestDirectory = Directory(testDocuments);
    if (await staleTestDirectory.exists()) {
      await staleTestDirectory.delete(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
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

  group('company logo files', () {
    test('accepts a JPG extension with a JPEG signature', () {
      final jpeg = img.encodeJpg(img.Image(width: 2, height: 2));
      expect(CompanyLogoStorage.validateBytes('company.JPG', jpeg), isNull);
      expect(CompanyLogoStorage.validateBytes('company.jpeg', jpeg), isNull);
      expect(
        CompanyLogoStorage.validateBytes('company.jpg', [0x89, 0x50, 0x4e]),
        contains('لا يطابق'),
      );
      expect(
        CompanyLogoStorage.validateBytes('broken.jpg', [
          0xff,
          0xd8,
          0xff,
          0xe0,
          0x00,
        ]),
        contains('تعذر فك ترميز الصورة'),
      );
      expect(
        CompanyLogoStorage.validateBytes('company.gif', jpeg),
        contains('PNG أو JPG'),
      );
      expect(
        CompanyLogoStorage.validateBytes(
          'company.jpg',
          Uint8List(CompanyLogoStorage.maxBytes + 1),
        ),
        contains('8 ميغابايت'),
      );
    });

    test(
      'stores candidate logos privately and deletes only managed files',
      () async {
        final support = await Directory.systemTemp.createTemp(
          'aqari-logo-storage-test-',
        );
        final jpeg = img.encodeJpg(img.Image(width: 2, height: 2));
        final outside = File('${support.path}/not-managed.jpg');
        try {
          final saved = await CompanyLogoStorage.saveCandidate(
            fileName: 'valid.jpg',
            bytes: jpeg,
            supportDirectory: support.path,
          );
          expect(await saved.exists(), isTrue);
          expect(
            saved.path,
            contains(
              '${Platform.pathSeparator}branding${Platform.pathSeparator}',
            ),
          );
          expect(saved.path.toLowerCase().endsWith('.jpg'), isTrue);
          expect(await saved.readAsBytes(), jpeg);

          await outside.writeAsBytes(jpeg);
          await CompanyLogoStorage.deleteManagedFile(
            outside.path,
            supportDirectory: support.path,
          );
          expect(await outside.exists(), isTrue);

          await CompanyLogoStorage.deleteManagedFile(
            saved.path,
            supportDirectory: support.path,
          );
          expect(await saved.exists(), isFalse);
        } finally {
          await support.delete(recursive: true);
        }
      },
    );
  });

  test('PDF direction preserves RTL Arabic fallbacks and LTR dates', () {
    expect(
      PrintUtils.resolveTextDirection(
        'غير مدون',
        preferred: pw.TextDirection.ltr,
      ),
      pw.TextDirection.rtl,
    );
    expect(PrintUtils.resolveTextDirection('2026/11/10'), pw.TextDirection.ltr);
  });

  test('spells receipt amounts in Arabic using the selected currency', () {
    expect(
      ArabicAmountWords.format(1220, 'ريال سعودي'),
      'ألف ومئتان وعشرون ريال سعودي',
    );
    expect(ArabicAmountWords.format(1, 'ريال سعودي'), 'ريال سعودي واحد');
    expect(ArabicAmountWords.format(2, 'ريال سعودي'), 'ريالان سعوديان');
    expect(
      ArabicAmountWords.format(10.5, 'ريال سعودي'),
      'عشرة ريالات سعودية وخمسون هللة',
    );
  });

  test('lease terms prefer saved settings and strip display numbering', () {
    expect(LeaseContractTerms.defaultClauses, hasLength(8));
    expect(LeaseContractTerms.resolve('شرط خاص للمؤسسة\n2. شرط ثانٍ'), [
      'شرط خاص للمؤسسة',
      'شرط ثانٍ',
    ]);
    expect(LeaseContractTerms.resolve('١. بند مرقم بالأرقام العربية'), [
      'بند مرقم بالأرقام العربية',
    ]);
    expect(LeaseContractTerms.resolve('  '), LeaseContractTerms.defaultClauses);
  });

  test(
    'creates a valid Arabic voucher PDF and a consistent SQLite backup',
    () async {
      final db = await DatabaseHelper.instance.database;
      final info = await DatabaseHelper.instance.getCompanyInfo();
      expect(info?['name_ar'], isNotEmpty);
      expect(info?['terms_conditions'], LeaseContractTerms.defaultText);
      final tenantColumns = (await db.rawQuery(
        'PRAGMA table_info(tenants)',
      )).map((row) => row['name']).toSet();
      final ownerColumns = (await db.rawQuery(
        'PRAGMA table_info(owners)',
      )).map((row) => row['name']).toSet();
      final contractColumns = (await db.rawQuery(
        'PRAGMA table_info(contracts)',
      )).map((row) => row['name']).toSet();
      final voucherColumns = (await db.rawQuery(
        'PRAGMA table_info(vouchers)',
      )).map((row) => row['name']).toSet();
      final voucherTables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(
        tenantColumns,
        containsAll(['identity_issue_date', 'identity_source', 'profession']),
      );
      expect(
        ownerColumns,
        containsAll(['identity_issue_date', 'identity_source']),
      );
      expect(contractColumns, containsAll(['purpose', 'electricity_reading']));
      expect(voucherColumns, contains('party_name'));
      expect(voucherTables, contains('voucher_installment_allocations'));

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
      expect(latin1.decode(pdf), contains('Tajawal'));
      final detailedVoucherPdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: 18,
        date: '2026-11-10',
        targetName: 'مستأجر تجريبي',
        amount: 1250.50,
        accountName: '',
        description: 'دفعة إيجار اختبارية',
        journalLines: [
          {'account_name': 'الصندوق الرئيسي', 'debit': 1250.5, 'credit': 0},
          {'account_name': 'حساب المستأجر', 'debit': 0, 'credit': 1250.5},
        ],
        installmentAllocations: [
          {
            'property_name': 'عقار الاختبار',
            'unit_number': '1',
            'due_date': '2026-11-10',
            'installment_amount': 1250.5,
            'allocated_amount': 1250.5,
          },
        ],
      );
      expect(String.fromCharCodes(detailedVoucherPdf.take(5)), '%PDF-');
      expect(detailedVoucherPdf.length, greaterThan(pdf.length));
      expect(PrintUtils.suggestedPdfName('سند قبض/17'), 'سند_قبض_17.pdf');
      expect(PrintUtils.currencyInArabic('YER'), 'ريال يمني');
      expect(PrintUtils.currencyInArabic('ريال سعودي (SAR)'), 'ريال سعودي');
      expect(
        LeaseContractPdf.formatAmountInWords(3222.5, 'YER'),
        allOf(contains('ريال يمني'), contains('فلس'), isNot(contains('سعودي'))),
      );
      expect(
        LeaseContractPdf.formatAmountInWords(10.5, 'SAR'),
        allOf(contains('ريالات سعودية'), contains('هللة')),
      );

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
    'default lease template embeds the settings logo and fits one page',
    () async {
      final logoFile = File(
        '${Directory.systemTemp.path}/aqari-test-logo-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await logoFile.writeAsBytes(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      try {
        final pdf = await LeaseContractPdf.build(
          companyInfo: {
            'name_ar': 'مؤسسة النقيب التجارية',
            'name_en': 'AL-NAQIB TRADING EST.',
            'activity_name_ar': 'للمقاولات ومواد البناء',
            'activity_name_en': 'Contracting & Building Materials',
            'commercial_register': '4601000613',
            'address_ar': 'شارع عمرو بن العاص - صنعاء',
            'telephone': '0777420665',
            'logo_path': logoFile.path,
            'terms_conditions': LeaseContractTerms.defaultText,
          },
          contract: {
            'id': 7,
            'start_date': '2026-09-09',
            'end_date': '2026-12-12',
            'rent_amount': 3222.0,
            'payment_method': 'شهري',
            'purpose': 'سكني',
            'electricity_reading': '12345',
          },
          owner: {
            'name': 'عبدالله محمد أحمد النقيب',
            'identity_number': '1029836135',
            'identity_issue_date': '1998/01/17',
            'identity_source': 'البيت',
          },
          tenant: {
            'name': 'مستأجر تجريبي',
            'identity_number': '1234567890',
            'mobile': '777000000',
            'nationality_name': 'يمني',
            'profession': 'موظف',
          },
          property: {
            'name': 'عقار الاختبار',
            'address': 'شارع عكرمة بن أبي جهل',
          },
          unit: {'unit_number': '1'},
          unitTypeName: 'غرفة',
        );
        final source = latin1.decode(pdf);
        expect(source, contains('Tajawal'));
        expect(RegExp(r'/Subtype\s*/Image').hasMatch(source), isTrue);
        expect(RegExp(r'/Type\s*/Page\b').allMatches(source).length, 1);
      } finally {
        if (await logoFile.exists()) await logoFile.delete();
      }
    },
  );

  test(
    'long lease terms add pages and keep signatures in the document flow',
    () async {
      final longTerms = List.generate(
        28,
        (index) =>
            'شرط ${index + 1}: يلتزم الطرفان بتنفيذ الالتزامات الواردة في هذا العقد '
            'بما يحفظ حقوق الطرفين ويضمن سلامة العقار وتسوية الالتزامات المالية '
            'وفق الأنظمة والتعليمات المعمول بها طوال مدة الإيجار.',
      ).join('\n');
      final pdf = await LeaseContractPdf.build(
        companyInfo: {'terms_conditions': longTerms},
        contract: {'rent_amount': 1200.0},
        owner: {'name': 'المؤجر'},
        tenant: {'name': 'المستأجر'},
        property: {'name': 'العقار'},
        unit: {'unit_number': '1'},
      );
      final source = latin1.decode(pdf);
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(source).length,
        greaterThan(1),
      );
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
      final receiptHistory = await DatabaseHelper.instance.getVoucherHistory(
        voucherType: 'قبض مستأجر',
      );
      expect(receiptHistory.single['id'], receiptId);
      expect(receiptHistory.single['party_name'], 'مستأجر الاختبار');
      final receiptDetails = await DatabaseHelper.instance.getVoucherDetails(
        receiptId,
      );
      expect(receiptDetails, isNotNull);
      expect((receiptDetails!['journal_lines'] as List).length, 2);
      final paidInstallments = receiptDetails['installments'] as List;
      expect(paidInstallments.length, 2);
      expect(
        paidInstallments
            .map((row) => (row['allocated_amount'] as num).toDouble())
            .toList(),
        [100.0, 50.0],
      );

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
      final generalDetails = await DatabaseHelper.instance.getVoucherDetails(
        generalVoucherId,
      );
      expect(generalDetails, isNotNull);
      expect((generalDetails!['voucher'] as Map)['party_name'], 'اختبار');
      expect((generalDetails['journal_lines'] as List).length, 2);

      final expenseAccount = (await db.query(
        'accounts',
        where: "account_type = 'Expense' AND parent_id IS NOT NULL",
        limit: 1,
      )).single;
      final paymentId = await DatabaseHelper.instance
          .insertTenantPaymentVoucher(
            tenantId: tenantId,
            amount: 25.0,
            voucherDate: '2026-11-10',
            cashAccountId: cashAccountId,
            offsetAccountId: expenseAccount['id'] as int,
            description: 'رد تأمين اختبار',
          );
      final paymentDetails = await DatabaseHelper.instance.getVoucherDetails(
        paymentId,
      );
      expect(paymentDetails, isNotNull);
      expect(
        (paymentDetails!['voucher'] as Map)['party_name'],
        'مستأجر الاختبار',
      );
      expect((paymentDetails['journal_lines'] as List).length, 2);

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

      await expectLater(
        DatabaseHelper.instance.cancelContract(contractId),
        throwsStateError,
      );
      final protectedContract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      final protectedInstallments = await db.query(
        'contract_installments',
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );
      expect(protectedContract['status'], 'Active');
      expect(protectedInstallments, hasLength(12));

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

  test('cancelling a contract preserves its installment history', () async {
    final db = await DatabaseHelper.instance.database;
    final tenant = (await db.query(
      'tenants',
      where: 'name = ?',
      whereArgs: ['مستأجر الاختبار'],
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك عقد الإلغاء'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار عقد الإلغاء',
      'owner_id': ownerId,
    });
    await DatabaseHelper.instance.updateProperty({
      'id': propertyId,
      'name': 'عقار عقد الإلغاء المعدل',
      'owner_id': ownerId,
      'city_id': null,
      'property_type_id': null,
      'cost_center_id': null,
      'address': 'عنوان اختباري',
      'deed_number': 'D-01',
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'CANCEL-01',
    });
    await DatabaseHelper.instance.updateUnit({
      'id': unitId,
      'unit_number': 'CANCEL-EDITED',
      'unit_type_id': null,
      'floor': 'الأول',
      'elec_meter': 'E-01',
      'water_meter': 'W-01',
      'default_rent': 100.0,
    });
    final editedUnit = (await db.query(
      'units',
      where: 'id = ?',
      whereArgs: [unitId],
    )).single;
    expect(editedUnit['unit_number'], 'CANCEL-EDITED');
    expect(editedUnit['status'], 'شاغرة');
    final contractId = await DatabaseHelper.instance
        .insertContractWithInstallments(
          {
            'tenant_id': tenant['id'],
            'unit_id': unitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-09',
            'rent_amount': 100,
            'payment_method': 'شهري',
            'status': 'Active',
          },
          [
            {
              'amount': 100,
              'paid_amount': 0,
              'due_date': '2026-12-10',
              'status': 'Unpaid',
            },
          ],
        );
    final secondOwnerId = await db.insert('owners', {
      'name': 'مالك ثان للاختبار',
    });
    final savedProperty = (await db.query(
      'properties',
      where: 'id = ?',
      whereArgs: [propertyId],
    )).single;
    await expectLater(
      DatabaseHelper.instance.updateProperty({
        ...savedProperty,
        'owner_id': secondOwnerId,
      }),
      throwsStateError,
    );
    final installment = (await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    )).single;

    await DatabaseHelper.instance.cancelContract(contractId);

    final retainedInstallments = await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    );
    final cancelledContract = (await db.query(
      'contracts',
      where: 'id = ?',
      whereArgs: [contractId],
    )).single;
    final releasedUnit = (await db.query(
      'units',
      where: 'id = ?',
      whereArgs: [unitId],
    )).single;
    final dueInstallments = await DatabaseHelper.instance.getDueInstallments(
      3650,
    );
    expect(retainedInstallments, hasLength(1));
    expect(retainedInstallments.single['id'], installment['id']);
    expect(retainedInstallments.single['status'], 'Cancelled');
    expect(cancelledContract['status'], 'Cancelled');
    expect(releasedUnit['status'], 'شاغرة');
    expect(
      dueInstallments.any((row) => row['installment_id'] == installment['id']),
      isFalse,
    );
  });

  testWidgets('voucher history lists persisted tenant and general vouchers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VoucherHistoryScreen())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump();
    expect(find.text('سجل السندات'), findsOneWidget);
    expect(find.textContaining('سند صرف مستأجر رقم'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.textContaining('سند قبض مستأجر رقم'), findsOneWidget);
    expect(find.textContaining('سند قبض عام رقم'), findsOneWidget);
    await tester.tap(find.textContaining('سند قبض مستأجر رقم').first);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('تفاصيل السند رقم'), findsOneWidget);
    expect(find.text('الحسابات والحركة المحاسبية'), findsOneWidget);
    expect(find.text('الأقساط التي سددها هذا السند'), findsOneWidget);
  });

  test(
    'updating a tenant keeps its account link and syncs account name',
    () async {
      final db = await DatabaseHelper.instance.database;
      final tenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر الاختبار'],
      )).single;
      final tenantId = tenant['id'] as int;
      final accountId = tenant['account_id'] as int;

      await DatabaseHelper.instance.updateTenant({
        'id': tenantId,
        'name': 'مستأجر معدل',
        'mobile': tenant['mobile'],
        'identity_number': tenant['identity_number'],
        'identity_issue_date': tenant['identity_issue_date'],
        'identity_source': tenant['identity_source'],
        'profession': tenant['profession'],
        'nationality_id': tenant['nationality_id'],
      });
      final updated = (await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      )).single;
      final account = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [accountId],
      )).single;
      expect(updated['name'], 'مستأجر معدل');
      expect(updated['account_id'], accountId);
      expect(account['name'], 'مستأجر معدل');
    },
  );

  test(
    'updating an owner keeps its account link and syncs account name',
    () async {
      final db = await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.insertOwnerWithAccount({
        'name': 'مالك تعديل الاختبار',
        'mobile': '777111222',
        'commission_rate': 5.0,
      });
      final owner = (await db.query(
        'owners',
        where: 'name = ?',
        whereArgs: ['مالك تعديل الاختبار'],
      )).single;
      final ownerId = owner['id'] as int;
      final accountId = owner['account_id'] as int;

      await DatabaseHelper.instance.updateOwner({
        'id': ownerId,
        'name': 'مالك محدث للاختبار',
        'mobile': owner['mobile'],
        'identity_number': owner['identity_number'],
        'identity_issue_date': owner['identity_issue_date'],
        'identity_source': owner['identity_source'],
        'profession': owner['profession'],
        'iban': owner['iban'],
        'commission_rate': 7.5,
      });
      final updated = (await db.query(
        'owners',
        where: 'id = ?',
        whereArgs: [ownerId],
      )).single;
      final account = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [accountId],
      )).single;
      expect(updated['name'], 'مالك محدث للاختبار');
      expect(updated['account_id'], accountId);
      expect(updated['commission_rate'], 7.5);
      expect(account['name'], 'مالك محدث للاختبار');
    },
  );

  testWidgets('tenant row opens an edit form and updates displayed data', (
    tester,
  ) async {
    final provider = _TestLeasingProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<LeasingProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: TenantsScreen())),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('مستأجر الاختبار').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('تعديل بيانات المستأجر'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'مستأجر معدل');
    await tester.tap(find.text('حفظ التعديلات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('مستأجر معدل'), findsOneWidget);
    expect(provider.tenants.single['account_id'], 81);

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });
}

class _TestLeasingProvider extends LeasingProvider {
  final List<Map<String, dynamic>> _testTenants = [
    {
      'id': 17,
      'name': 'مستأجر الاختبار',
      'mobile': '777000000',
      'identity_number': '12345',
      'identity_issue_date': '2026-01-01',
      'identity_source': 'صنعاء',
      'profession': 'موظف',
      'nationality_id': null,
      'account_id': 81,
    },
  ];

  @override
  List<Map<String, dynamic>> get tenants => _testTenants;

  @override
  List<Map<String, dynamic>> get nationalities => const [];

  @override
  bool get isLoading => false;

  @override
  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    final index = _testTenants.indexWhere((item) => item['id'] == tenant['id']);
    _testTenants[index] = {..._testTenants[index], ...tenant};
    notifyListeners();
  }
}
