import 'dart:io';
import 'dart:convert';

import 'package:app/core/arabic_amount_words.dart';
import 'package:app/core/crypto_utils.dart';
import 'package:app/core/company_logo_storage.dart';
import 'package:app/core/lease_contract_pdf.dart';
import 'package:app/core/contract_party_snapshot.dart';
import 'package:app/core/lease_contract_terms.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/database/database_integrity_migrations.dart';
import 'package:app/features/tenant_financial/voucher_history_screen.dart';
import 'package:app/features/tenants_leasing/tenants_screen.dart';
import 'package:app/providers/leasing_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    'v11 migration preserves legacy units and blocks new duplicates',
    () async {
      sqfliteFfiInit();
      final path =
          '${Directory.systemTemp.path}/aqari-v11-migration-${DateTime.now().microsecondsSinceEpoch}.db';
      final oldDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE units (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              property_id INTEGER NOT NULL,
              unit_number TEXT NOT NULL,
              floor TEXT
            )
          ''');
            await db.execute('''
            CREATE TABLE contracts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id INTEGER NOT NULL,
              rent_amount REAL NOT NULL
            )
          ''');
            await db.insert('units', {
              'property_id': 41,
              'unit_number': 'DUP-01',
              'floor': 'الأرضي',
            });
            await db.insert('units', {
              'property_id': 41,
              'unit_number': ' dup-01 ',
              'floor': 'الأول',
            });
            await db.insert('contracts', {'unit_id': 1, 'rent_amount': 1000.0});
          },
        ),
      );
      await oldDb.close();

      final migratedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 12,
          onUpgrade: (db, oldVersion, newVersion) async {
            expect(oldVersion, 11);
            expect(newVersion, 12);
            await DatabaseIntegrityMigrations.upgradeToV12(db);
          },
        ),
      );
      try {
        expect(
          (await migratedDb.rawQuery(
            'PRAGMA user_version',
          )).single.values.single,
          12,
        );
        final contractColumns = (await migratedDb.rawQuery(
          'PRAGMA table_info(contracts)',
        )).map((row) => row['name']).toSet();
        expect(contractColumns, contains('party_snapshot'));
        expect(await migratedDb.query('units'), hasLength(2));
        expect(await migratedDb.query('contracts'), hasLength(1));
        await expectLater(
          migratedDb.insert('units', {
            'property_id': 41,
            'unit_number': 'DUP-01',
          }),
          throwsA(isA<Exception>()),
        );
        await migratedDb.update(
          'units',
          {'unit_number': 'DUP-01', 'floor': 'الثاني'},
          where: 'id = ?',
          whereArgs: [1],
        );
        await migratedDb.update(
          'units',
          {'unit_number': 'LEGACY-01'},
          where: 'id = ?',
          whereArgs: [1],
        );
        expect(
          (await migratedDb.query(
            'units',
            where: 'id = ?',
            whereArgs: [1],
          )).single['unit_number'],
          'LEGACY-01',
        );
        expect(await migratedDb.query('units'), hasLength(2));
      } finally {
        await migratedDb.close();
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    },
  );

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
      final unitColumns = (await db.rawQuery(
        'PRAGMA table_info(units)',
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
      expect(unitColumns, containsAll(['default_rent', 'default_rent_period']));
      expect(
        contractColumns,
        containsAll([
          'purpose',
          'electricity_reading',
          'unit_rent_amount',
          'unit_rent_period',
          'party_snapshot',
        ]),
      );
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
      expect(latin1.decode(pdf), contains('AqariPDFArabic'));
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
    'restores a validated backup and preserves a verified rollback copy',
    () async {
      final db = await DatabaseHelper.instance.database;
      final companyRows = await db.query('company_info', limit: 1);
      expect(companyRows, isNotEmpty);
      final companyId = companyRows.single['id'];
      final originalName = companyRows.single['name_ar'];
      final backupPath = '$testDocuments/aqari-restore-source.db';
      await DatabaseHelper.instance.backupToFile(backupPath);

      await db.update(
        'company_info',
        {'name_ar': 'تغيير مؤقت لاختبار الاستعادة'},
        where: 'id = ?',
        whereArgs: [companyId],
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        'تغيير مؤقت لاختبار الاستعادة',
      );

      final rollbackPath = await DatabaseHelper.instance.restoreFromFile(
        backupPath,
      );
      expect(File(rollbackPath).existsSync(), isTrue);
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      final rollbackDb = await databaseFactory.openDatabase(
        rollbackPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        expect(
          (await rollbackDb.query('company_info', limit: 1)).single['name_ar'],
          'تغيير مؤقت لاختبار الاستعادة',
        );
      } finally {
        await rollbackDb.close();
      }
      await File(backupPath).delete();
      await File(rollbackPath).delete();
    },
  );

  test(
    'rejects a corrupt restore without changing live data or an existing backup',
    () async {
      final db = await DatabaseHelper.instance.database;
      final originalName = (await DatabaseHelper.instance
          .getCompanyInfo())?['name_ar'];
      final corruptPath = '$testDocuments/not-a-database.db';
      await File(corruptPath).writeAsBytes(List<int>.filled(256, 0));

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(corruptPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );
      expect(await db.rawQuery('PRAGMA integrity_check'), isNotEmpty);

      final existingBackupPath = '$testDocuments/do-not-overwrite.db';
      final existingBackup = File(existingBackupPath);
      await existingBackup.writeAsString('preserve-existing-file');
      await expectLater(
        DatabaseHelper.instance.backupToFile(existingBackupPath),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existingBackup.readAsString(), 'preserve-existing-file');
      await File(corruptPath).delete();
      await existingBackup.delete();
    },
  );

  test(
    'rejects incomplete schemas and uncheckpointed WAL backups before replacement',
    () async {
      final originalName = (await DatabaseHelper.instance
          .getCompanyInfo())?['name_ar'];
      final completeBackupPath = '$testDocuments/complete-schema.db';
      final incompleteBackupPath = '$testDocuments/incomplete-schema.db';
      final missingColumnBackupPath =
          '$testDocuments/missing-contract-column.db';
      await DatabaseHelper.instance.backupToFile(completeBackupPath);
      await File(completeBackupPath).copy(incompleteBackupPath);
      final incompleteDb = await databaseFactory.openDatabase(
        incompleteBackupPath,
      );
      await incompleteDb.execute('DROP TABLE sms_logs');
      await incompleteDb.close();

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(incompleteBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      await File(completeBackupPath).copy(missingColumnBackupPath);
      final missingColumnDb = await databaseFactory.openDatabase(
        missingColumnBackupPath,
      );
      await missingColumnDb.execute(
        'ALTER TABLE contracts DROP COLUMN payment_method',
      );
      await missingColumnDb.close();
      await expectLater(
        DatabaseHelper.instance.restoreFromFile(missingColumnBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      final walBackupPath = '$testDocuments/wal-pending-backup.db';
      await DatabaseHelper.instance.backupToFile(walBackupPath);
      final walDatabase = await databaseFactory.openDatabase(walBackupPath);
      await walDatabase.rawQuery('PRAGMA journal_mode = WAL');
      await walDatabase.execute(
        'CREATE TABLE committed_in_wal (id INTEGER PRIMARY KEY, value TEXT)',
      );
      await walDatabase.insert('committed_in_wal', {'value': 'committed'});
      expect(File('$walBackupPath-wal').lengthSync(), greaterThan(32));

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(walBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );
      await walDatabase.close();

      for (final path in [
        completeBackupPath,
        incompleteBackupPath,
        missingColumnBackupPath,
        walBackupPath,
      ]) {
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('$path$suffix');
          if (await file.exists()) await file.delete();
        }
      }
    },
  );

  test(
    'upgrades a valid v11 backup during restore before replacing live data',
    () async {
      final sourcePath = '$testDocuments/aqari-v11-restore.db';
      await DatabaseHelper.instance.backupToFile(sourcePath);
      final legacyDatabase = await databaseFactory.openDatabase(sourcePath);
      await legacyDatabase.execute(
        'ALTER TABLE contracts DROP COLUMN party_snapshot',
      );
      await legacyDatabase.execute('DROP TRIGGER units_unique_number_insert');
      await legacyDatabase.execute('DROP TRIGGER units_unique_number_update');
      await legacyDatabase.execute('PRAGMA user_version = 11');
      await legacyDatabase.close();

      final rollbackPath = await DatabaseHelper.instance.restoreFromFile(
        sourcePath,
      );
      final restored = await DatabaseHelper.instance.database;
      expect(
        (await restored.rawQuery('PRAGMA user_version')).single.values.single,
        12,
      );
      expect(
        (await restored.rawQuery(
          'PRAGMA table_info(contracts)',
        )).map((row) => row['name']),
        contains('party_snapshot'),
      );
      expect(
        (await restored.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger'",
        )).map((row) => row['name']),
        containsAll([
          'units_unique_number_insert',
          'units_unique_number_update',
        ]),
      );
      expect(File(rollbackPath).existsSync(), isTrue);
      await File(sourcePath).delete();
      await File(rollbackPath).delete();
    },
  );

  test(
    'unit rent period is explicit and legacy rows are not guessed',
    () async {
      final db = await DatabaseHelper.instance.database;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single.values.single,
        12,
      );

      final ownerId = await db.insert('owners', {'name': 'مالك الدورية'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار اختبار الدورية',
        'owner_id': ownerId,
      });
      final legacyUnitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'LEGACY-01',
        'default_rent': 1200.0,
        'status': 'شاغرة',
      });
      await DatabaseHelper.instance.insertTenantWithAccount({
        'name': 'مستأجر اختبار الدورية',
        'mobile': '777000001',
      });
      final tenantId = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر اختبار الدورية'],
      )).single['id'];
      final contractsBefore = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM contracts',
      )).single['count'];

      await expectLater(
        DatabaseHelper.instance.insertContractWithInstallments(
          {
            'tenant_id': tenantId,
            'unit_id': legacyUnitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-10',
            'rent_amount': 1200.0,
            'payment_method': 'سنوي',
            'status': 'Active',
          },
          [
            {
              'amount': 1200.0,
              'paid_amount': 0.0,
              'due_date': '2026-11-10',
              'status': 'Unpaid',
            },
          ],
        ),
        throwsStateError,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [legacyUnitId],
        )).single['default_rent_period'],
        isNull,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM contracts',
        )).single['count'],
        contractsBefore,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [legacyUnitId],
        )).single['status'],
        'شاغرة',
      );

      await expectLater(
        DatabaseHelper.instance.insertUnit({
          'property_id': propertyId,
          'unit_number': 'NEW-NO-PERIOD',
          'default_rent': 100.0,
        }),
        throwsArgumentError,
      );
      final newUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'NEW-ANNUAL',
        'default_rent': 24000.0,
        'default_rent_period': 'annual',
        'status': 'شاغرة',
      });
      final newUnit = (await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [newUnitId],
      )).single;
      expect(newUnit['default_rent'], 24000.0);
      expect(newUnit['default_rent_period'], 'annual');
    },
  );

  test(
    'entity relationships reject missing parents and duplicate units',
    () async {
      final db = await DatabaseHelper.instance.database;
      final accountCountBefore = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM accounts',
      )).single['count'];

      await expectLater(
        DatabaseHelper.instance.insertOwnerWithAccount({
          'name': '   ',
          'commission_rate': 5.0,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertOwnerWithAccount({
          'name': 'مالك عمولة غير صالحة',
          'commission_rate': 101.0,
        }),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM accounts',
        )).single['count'],
        accountCountBefore,
      );

      await DatabaseHelper.instance.insertOwnerWithAccount({
        'name': 'مالك العلاقات',
        'commission_rate': 0.0,
      });
      final owner = (await db.query(
        'owners',
        where: 'name = ?',
        whereArgs: ['مالك العلاقات'],
      )).single;
      final ownerId = owner['id'] as int;

      await expectLater(
        DatabaseHelper.instance.insertProperty({
          'name': 'عقار بلا مالك صحيح',
          'owner_id': 999999,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertProperty({
          'name': 'عقار بمرجع مدينة غير صحيح',
          'owner_id': ownerId,
          'city_id': 999999,
        }),
        throwsArgumentError,
      );
      final propertyId = await DatabaseHelper.instance.insertProperty({
        'name': 'عقار العلاقات',
        'owner_id': ownerId,
      });

      final firstUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'UNIT-01',
        'default_rent': 1000.0,
        'default_rent_period': 'monthly',
        'status': 'شاغرة',
      });
      await expectLater(
        DatabaseHelper.instance.insertUnit({
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
        }),
        throwsStateError,
      );
      await expectLater(
        db.insert('units', {
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
        }),
        throwsA(isA<Exception>()),
      );
      final secondUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'UNIT-02',
        'default_rent_period': 'annual',
        'status': 'شاغرة',
      });
      await expectLater(
        DatabaseHelper.instance.updateUnit({
          'id': secondUnitId,
          'unit_number': 'unit-01',
          'default_rent_period': 'annual',
        }),
        throwsStateError,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [firstUnitId],
        )).single['unit_number'],
        'UNIT-01',
      );

      await db.execute('DROP TRIGGER IF EXISTS units_unique_number_insert');
      await db.execute('DROP TRIGGER IF EXISTS units_unique_number_update');
      late final int legacyDuplicateId;
      try {
        legacyDuplicateId = await db.insert('units', {
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
          'status': 'شاغرة',
        });
      } finally {
        await DatabaseIntegrityMigrations.installUnitNumberGuards(db);
      }
      final duplicateRows = await DatabaseHelper.instance.getUnitsForProperty(
        propertyId,
      );
      expect(
        duplicateRows.where((row) => row['has_duplicate_number'] == 1).length,
        2,
      );
      await DatabaseHelper.instance.updateUnit({
        'id': legacyDuplicateId,
        'unit_number': ' unit-01 ',
        'default_rent_period': 'annual',
      });
      await DatabaseHelper.instance.updateUnit({
        'id': legacyDuplicateId,
        'unit_number': 'UNIT-03',
        'default_rent_period': 'annual',
      });
      final resolvedRows = await DatabaseHelper.instance.getUnitsForProperty(
        propertyId,
      );
      expect(
        resolvedRows.every((row) => row['has_duplicate_number'] == 0),
        isTrue,
      );

      final accountsBeforeInvalidTenant = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM accounts',
      )).single['count'];
      await expectLater(
        DatabaseHelper.instance.insertTenantWithAccount({
          'name': 'مستأجر بجنسية غير موجودة',
          'mobile': '777222333',
          'nationality_id': 999999,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTenantWithAccount({
          'name': 'اسم فقط',
          'mobile': ' ',
        }),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM accounts',
        )).single['count'],
        accountsBeforeInvalidTenant,
      );

      await expectLater(
        DatabaseHelper.instance.updateProperty({
          'id': propertyId,
          'name': 'عقار العلاقات',
          'owner_id': 999999,
        }),
        throwsArgumentError,
      );
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
        expect(source, contains('AqariPDFArabic'));
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
        'default_rent': 100.0,
        'default_rent_period': 'monthly',
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

      final storedContract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      expect(storedContract['rent_amount'], 1200.0);
      expect(storedContract['unit_rent_amount'], 100.0);
      expect(storedContract['unit_rent_period'], 'monthly');
      final partySnapshot = ContractPartySnapshot.decode(storedContract);
      expect(
        ContractPartySnapshot.section(partySnapshot, 'tenant')['name'],
        'مستأجر الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'owner')['name'],
        'مالك الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'property')['name'],
        'عقار الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'unit')['unit_number'],
        'T-01',
      );

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
      final vouchersBeforeMismatch = (await db.query('vouchers')).length;
      final entriesBeforeMismatch = (await db.query('journal_entries')).length;
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'صرف عام',
            'voucher_date': '2026-11-10',
            'amount': 20.0,
            'description': 'سند بنوع مخالف',
          },
          cashAccountId,
          revenueAccount['id'] as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      expect((await db.query('vouchers')).length, vouchersBeforeMismatch);
      expect((await db.query('journal_entries')).length, entriesBeforeMismatch);

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
      'default_rent_period': 'monthly',
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
    final contractBeforeMasterEdits = (await db.query(
      'contracts',
      where: 'id = ?',
      whereArgs: [contractId],
    )).single;
    final originalSnapshot = ContractPartySnapshot.decode(
      contractBeforeMasterEdits,
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'owner')['name'],
      'مالك عقد الإلغاء',
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'property')['name'],
      'عقار عقد الإلغاء المعدل',
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'unit')['unit_number'],
      'CANCEL-EDITED',
    );
    await DatabaseHelper.instance.updateProperty({
      ...((await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [propertyId],
      )).single),
      'name': 'عقار بعد العقد',
      'address': 'عنوان جديد',
    });
    await DatabaseHelper.instance.updateUnit({
      'id': unitId,
      'unit_number': 'CANCEL-RENAMED',
      'unit_type_id': null,
      'floor': 'الأول',
      'elec_meter': 'E-01',
      'water_meter': 'W-01',
      'default_rent': 100.0,
      'default_rent_period': 'monthly',
    });
    await DatabaseHelper.instance.updateOwner({
      'id': ownerId,
      'name': 'مالك بعد العقد',
      'commission_rate': 0.0,
    });
    final persistedSnapshot = ContractPartySnapshot.decode(
      (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single,
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'owner')['name'],
      'مالك عقد الإلغاء',
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'property')['name'],
      'عقار عقد الإلغاء المعدل',
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'unit')['unit_number'],
      'CANCEL-EDITED',
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

    await expectLater(
      DatabaseHelper.instance.deleteUnit(unitId),
      throwsStateError,
    );

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
    await expectLater(
      DatabaseHelper.instance.deleteUnit(unitId),
      throwsStateError,
    );
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
      final contract = (await db.query(
        'contracts',
        where: 'tenant_id = ?',
        whereArgs: [tenantId],
        limit: 1,
      )).single;
      expect(ContractPartySnapshot.tenantName(contract), 'مستأجر الاختبار');

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
      expect(ContractPartySnapshot.tenantName(contract), 'مستأجر الاختبار');
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

  test(
    'factory reset creates a verified rollback copy before reseeding',
    () async {
      final rollbackPath = await DatabaseHelper.instance.factoryReset();
      final rollback = File(rollbackPath);
      expect(await rollback.exists(), isTrue);
      expect(await rollback.length(), greaterThan(100));

      final company = await DatabaseHelper.instance.getCompanyInfo();
      expect(company?['name_ar'], isNotEmpty);
      final db = await DatabaseHelper.instance.database;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single.values.single,
        12,
      );
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      await rollback.delete();
    },
  );
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
