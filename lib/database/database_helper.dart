import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

import '../core/internal_tax.dart';
import '../core/lease_contract_terms.dart';
import '../core/permission_policy.dart';
import '../core/rent_period.dart';
import 'database_integrity_migrations.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static const int _schemaVersion = 15;
  static const Set<String> _lookupTables = {
    'cities',
    'nationalities',
    'banks',
    'property_types',
    'unit_types',
    'cost_centers',
  };
  static const Map<String, String> _accountTypeRootCodes = {
    'Asset': '1',
    'Liability': '2',
    'Equity': '3',
    'Revenue': '4',
    'Expense': '5',
  };
  static const Set<String> _protectedSystemAccountCodes = {
    '1',
    '11',
    '1101',
    '1102',
    '1201',
    '2',
    '2101',
    '2102',
    '2103',
    '4',
    '4101',
    '4102',
    '5',
    '5101',
    '5102',
    '5103',
  };

  DatabaseHelper._init();

  bool _hasCentPrecision(num value) {
    final scaled = value.toDouble() * 100;
    return scaled.isFinite && (scaled - scaled.round()).abs() < 0.000001;
  }

  void _requireAnyView(Iterable<String> modules) {
    if (!modules.any(
      (module) => PermissionRuntime.allows(module, AppPermissionAction.view),
    )) {
      throw StateError('لا تملك صلاحية عرض هذه البيانات');
    }
  }

  void _validateLookupTable(String tableName) {
    if (!_lookupTables.contains(tableName)) {
      throw ArgumentError.value(tableName, 'tableName', 'جدول مرجعي غير مسموح');
    }
  }

  void _requireLookupReadPermission(String tableName) {
    final modules = switch (tableName) {
      'cities' || 'property_types' || 'unit_types' => ['lookups', 'properties'],
      'nationalities' => ['lookups', 'leasing', 'properties'],
      'cost_centers' => ['lookups', 'properties', 'accounting'],
      'banks' => ['lookups', 'accounting', 'tenant_financial'],
      _ => ['lookups'],
    };
    _requireAnyView(modules);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('desktop_erp.db');
    return _database!;
  }

  Future<String> getDbPath() async {
    final dbPath = await getApplicationDocumentsDirectory();
    return join(dbPath.path, 'AbdullahAlNaqeebERP', 'desktop_erp.db');
  }

  Future<void> backupToFile(String targetPath) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    final target = File(targetPath).absolute;
    final livePath = File(await getDbPath()).absolute.path;
    if (target.path == livePath) {
      throw ArgumentError('لا يمكن اختيار قاعدة التشغيل كوجهة للنسخ');
    }
    if (await target.exists()) {
      throw FileSystemException(
        'ملف النسخة موجود مسبقًا؛ لن يُستبدل',
        target.path,
      );
    }
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.partial-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      final db = await database;
      final escapedPath = temporary.path.replaceAll("'", "''");
      await db.execute("VACUUM INTO '$escapedPath'");
      final snapshot = await databaseFactory.openDatabase(
        temporary.path,
        options: OpenDatabaseOptions(readOnly: false),
      );
      try {
        await snapshot.update('sms_settings', {'api_key': null});
      } finally {
        await snapshot.close();
      }
      await _validateDatabaseFile(temporary.path, requireCurrentSchema: true);
      if (await target.exists()) {
        throw FileSystemException(
          'ملف النسخة ظهر أثناء العملية؛ لم يتم استبداله',
          target.path,
        );
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<String> restoreFromFile(String sourcePath) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    final source = File(sourcePath).absolute;
    final livePath = File(await getDbPath()).absolute;
    if (source.path == livePath.path) {
      throw ArgumentError('اختر ملف نسخة احتياطية، وليس قاعدة التشغيل');
    }
    await _rejectUncheckpointedWal(source.path);
    final sourceVersion = await _validateDatabaseFile(source.path);
    if (sourceVersion > _schemaVersion) {
      throw StateError(
        'إصدار النسخة ($sourceVersion) أحدث من إصدار هذا البرنامج ($_schemaVersion)',
      );
    }

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staged = File('${livePath.path}.restore-$stamp');
    final rollback = File(
      join(livePath.parent.path, 'aqari_pre_restore_$stamp.db'),
    );
    var liveReplacementStarted = false;
    await livePath.parent.create(recursive: true);
    try {
      final sourceStatBefore = await source.stat();
      await source.copy(staged.path);
      await _rejectUncheckpointedWal(source.path);
      final sourceStatAfter = await source.stat();
      if (sourceStatBefore.size != sourceStatAfter.size ||
          sourceStatBefore.modified != sourceStatAfter.modified) {
        throw StateError(
          'تغير ملف النسخة أثناء قراءته؛ أوقف أي برنامج يستخدمه ثم أعد المحاولة',
        );
      }
      final candidate = await databaseFactory.openDatabase(
        staged.path,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
          onUpgrade: _upgradeDB,
        ),
      );
      try {
        await _validateOpenDatabase(candidate, requireCurrentSchema: true);
      } finally {
        await candidate.close();
      }

      // Preserve a verified copy before disconnecting or replacing the live DB.
      await backupToFile(rollback.path);
      final current = await database;
      await current.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await current.close();
      _database = null;
      liveReplacementStarted = true;
      await _deleteSqliteSidecars(livePath.path);
      await staged.rename(livePath.path);
      _database = await _initDB('desktop_erp.db');
      await _validateOpenDatabase(_database!, requireCurrentSchema: true);
      return rollback.path;
    } catch (error) {
      if (liveReplacementStarted) {
        Object? rollbackError;
        try {
          if (_database != null) await _database!.close();
          _database = null;
          if (await livePath.exists()) await livePath.delete();
          await _deleteSqliteSidecars(livePath.path);
          if (!await rollback.exists()) {
            throw StateError('ملف نسخة الرجوع غير موجود');
          }
          await rollback.copy(livePath.path);
          _database = await _initDB('desktop_erp.db');
          await _validateOpenDatabase(_database!, requireCurrentSchema: true);
        } catch (failure) {
          rollbackError = failure;
        }
        if (rollbackError != null) {
          throw StateError(
            'فشلت الاستعادة ($error)، وتعذرت الاستعادة التلقائية ($rollbackError). احتفظ بنسخة الرجوع إن وُجدت: ${rollback.path}',
          );
        }
        throw StateError(
          'فشلت الاستعادة، لكن أُعيدت قاعدة التشغيل من نسخة الرجوع المحفوظة في ${rollback.path}. السبب: $error',
        );
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<int> _validateDatabaseFile(
    String path, {
    bool requireCurrentSchema = false,
  }) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < 100) {
      throw StateError('ملف النسخة غير موجود أو غير مكتمل');
    }
    await _rejectUncheckpointedWal(file.absolute.path);
    Database? candidate;
    try {
      candidate = await databaseFactory.openDatabase(
        file.absolute.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      final version = (versionRows.first.values.first as num).toInt();
      if (version < 1 || version > _schemaVersion) {
        throw StateError('إصدار قاعدة البيانات غير مدعوم: $version');
      }
      final integrity = await candidate.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty ||
          integrity.any((row) => row.values.first != 'ok')) {
        throw StateError('فشل فحص سلامة ملف قاعدة البيانات');
      }
      final violations = await candidate.rawQuery('PRAGMA foreign_key_check');
      if (violations.isNotEmpty) {
        throw StateError('تحتوي النسخة على علاقات مرجعية غير سليمة');
      }
      if (requireCurrentSchema) {
        await _validateOpenDatabase(candidate, requireCurrentSchema: true);
      }
      await _rejectUncheckpointedWal(file.absolute.path);
      return version;
    } on StateError {
      rethrow;
    } catch (error) {
      throw StateError('تعذر فتح/فحص ملف قاعدة البيانات: $error');
    } finally {
      await candidate?.close();
    }
  }

  Future<void> _validateOpenDatabase(
    DatabaseExecutor db, {
    required bool requireCurrentSchema,
  }) async {
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    if (integrity.isEmpty || integrity.any((row) => row.values.first != 'ok')) {
      throw StateError('فشل فحص سلامة قاعدة البيانات');
    }
    final violations = await db.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('تحتوي قاعدة البيانات على علاقات مرجعية غير سليمة');
    }
    if (!requireCurrentSchema) return;
    final versionRows = await db.rawQuery('PRAGMA user_version');
    final version = (versionRows.first.values.first as num).toInt();
    if (version != _schemaVersion) {
      throw StateError('إصدار مخطط قاعدة البيانات غير متوقع: $version');
    }
    const requiredColumns = <String, List<String>>{
      'company_info': [
        'id',
        'name_ar',
        'name_en',
        'activity',
        'address',
        'default_currency',
        'tax_number',
        'tax_rate',
        'commercial_register',
        'logo_path',
        'terms_conditions',
        'activity_name_ar',
        'activity_name_en',
        'address_ar',
        'address_en',
        'po_box',
        'telephone',
        'fax',
        'mobile',
      ],
      'users': [
        'id',
        'username',
        'password_hash',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
      ],
      'user_permissions': [
        'id',
        'user_id',
        'screen_name',
        'can_view',
        'can_add',
        'can_edit',
        'can_delete',
        'can_print',
        'can_post',
      ],
      'audit_logs': ['id', 'user_id', 'action', 'details', 'timestamp'],
      'cities': ['id', 'name'],
      'nationalities': ['id', 'name'],
      'banks': ['id', 'name', 'account_id'],
      'property_types': ['id', 'name'],
      'unit_types': ['id', 'name'],
      'cost_centers': ['id', 'code', 'name'],
      'accounts': [
        'id',
        'code',
        'name',
        'parent_id',
        'account_type',
        'balance',
      ],
      'owners': [
        'id',
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
        'iban',
        'account_id',
        'commission_rate',
      ],
      'properties': [
        'id',
        'name',
        'owner_id',
        'city_id',
        'property_type_id',
        'cost_center_id',
        'address',
        'deed_number',
      ],
      'units': [
        'id',
        'property_id',
        'unit_number',
        'unit_type_id',
        'floor',
        'elec_meter',
        'water_meter',
        'status',
        'default_rent',
        'default_rent_period',
      ],
      'tenants': [
        'id',
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
        'account_id',
        'nationality_id',
      ],
      'contracts': [
        'id',
        'tenant_id',
        'unit_id',
        'start_date',
        'end_date',
        'rent_amount',
        'unit_rent_amount',
        'unit_rent_period',
        'party_snapshot',
        'payment_method',
        'purpose',
        'electricity_reading',
        'status',
      ],
      'contract_installments': [
        'id',
        'contract_id',
        'amount',
        'paid_amount',
        'due_date',
        'status',
      ],
      'tax_invoices': [
        'id',
        'contract_id',
        'installment_id',
        'journal_entry_id',
        'invoice_date',
        'net_amount',
        'total_amount',
        'tax_amount',
        'tax_rate',
      ],
      'credit_notes': ['id', 'invoice_id', 'note_date', 'amount'],
      'vouchers': [
        'id',
        'voucher_type',
        'voucher_date',
        'amount',
        'tenant_id',
        'party_name',
        'journal_entry_id',
        'description',
      ],
      'voucher_installment_allocations': [
        'id',
        'voucher_id',
        'installment_id',
        'amount',
      ],
      'voucher_invoice_allocations': [
        'id',
        'voucher_id',
        'invoice_id',
        'amount',
      ],
      'journal_entries': ['id', 'entry_date', 'description', 'is_posted'],
      'journal_lines': [
        'id',
        'journal_entry_id',
        'account_id',
        'debit',
        'credit',
        'cost_center_id',
        'description',
      ],
      'sms_settings': [
        'id',
        'api_url',
        'api_key',
        'sender_name',
        'reminder_template',
        'receipt_template',
      ],
      'sms_logs': [
        'id',
        'recipient_number',
        'message_text',
        'sent_at',
        'status',
      ],
    };
    final missingSchema = <String>[];
    for (final entry in requiredColumns.entries) {
      final columns = (await db.rawQuery(
        'PRAGMA table_info("${entry.key}")',
      )).map((row) => row['name']?.toString()).toSet();
      final missing = entry.value.where((column) => !columns.contains(column));
      missingSchema.addAll(missing.map((column) => '${entry.key}.$column'));
    }
    if (missingSchema.isNotEmpty) {
      throw StateError(
        'مخطط النسخة غير مكتمل؛ الجداول/الأعمدة المفقودة: ${missingSchema.join('، ')}',
      );
    }
    final triggers = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    )).map((row) => row['name']?.toString()).toSet();
    const requiredTriggers = [
      'units_unique_number_insert',
      'units_unique_number_update',
    ];
    final missingTriggers = requiredTriggers
        .where((trigger) => !triggers.contains(trigger))
        .toList();
    if (missingTriggers.isNotEmpty) {
      throw StateError(
        'مخطط النسخة يفتقد حواجز سلامة الوحدات: ${missingTriggers.join('، ')}',
      );
    }
    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    )).map((row) => row['name']?.toString()).toSet();
    const requiredIndexes = [
      'tax_invoices_installment_unique',
      'voucher_invoice_unique',
    ];
    final missingIndexes = requiredIndexes
        .where((index) => !indexes.contains(index))
        .toList();
    if (missingIndexes.isNotEmpty) {
      throw StateError(
        'مخطط النسخة يفتقد فهارس الربط المالي: ${missingIndexes.join('، ')}',
      );
    }
  }

  Future<void> _rejectUncheckpointedWal(String databasePath) async {
    final walFile = File('$databasePath-wal');
    if (await walFile.exists() && await walFile.length() > 0) {
      throw StateError(
        'ملف قاعدة البيانات يحتوي على سجل WAL منفصل. أوقف البرنامج الذي يستخدمه وأنشئ نسخة مكتملة من داخل Aqari قبل الاستعادة.',
      );
    }
  }

  Future<void> _deleteSqliteSidecars(String path) async {
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$path$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
  }

  Future<String> factoryReset() async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    final path = await getDbPath();
    final rollbackPath = join(
      File(path).parent.path,
      'aqari_pre_reset_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    await backupToFile(rollbackPath);
    final current = await database;
    await current.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    await current.close();
    _database = null;
    try {
      await _deleteSqliteSidecars(path);
      await databaseFactory.deleteDatabase(path);
      _database = await _initDB('desktop_erp.db');
      await _validateOpenDatabase(_database!, requireCurrentSchema: true);
      return rollbackPath;
    } catch (error) {
      Object? rollbackError;
      try {
        if (_database != null) await _database!.close();
        _database = null;
        await _deleteSqliteSidecars(path);
        final live = File(path);
        if (await live.exists()) await live.delete();
        await File(rollbackPath).copy(path);
        _database = await _initDB('desktop_erp.db');
        await _validateOpenDatabase(_database!, requireCurrentSchema: true);
      } catch (failure) {
        rollbackError = failure;
      }
      if (rollbackError != null) {
        throw StateError(
          'فشلت التهيئة ($error)، وتعذرت الاستعادة التلقائية. نسخة الرجوع: $rollbackPath. الخطأ: $rollbackError',
        );
      }
      throw StateError(
        'فشلت التهيئة، وأُعيدت قاعدة التشغيل من نسخة الرجوع المحفوظة في $rollbackPath. السبب: $error',
      );
    }
  }

  Future<Database> _initDB(String filePath) async {
    // Initialize FFI for Windows desktop
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, 'AbdullahAlNaqeebERP', filePath);

    // Ensure the directory exists
    await Directory(
      join(dbPath.path, 'AbdullahAlNaqeebERP'),
    ).create(recursive: true);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _ensureColumn(db, 'owners', 'iban', 'TEXT');
    }
    if (oldVersion < 3) {
      await _ensureColumn(db, 'properties', 'property_type_id', 'INTEGER');
      await _ensureColumn(db, 'units', 'floor', 'TEXT');
      await _ensureColumn(db, 'units', 'elec_meter', 'TEXT');
      await _ensureColumn(db, 'units', 'water_meter', 'TEXT');
    }
    if (oldVersion < 4) {
      await _ensureColumn(db, 'sms_settings', 'reminder_template', 'TEXT');
      await _ensureColumn(db, 'sms_settings', 'receipt_template', 'TEXT');
    }
    if (oldVersion < 5) {
      await _ensureColumn(db, 'company_info', 'logo_path', 'TEXT');
      await _ensureColumn(db, 'company_info', 'terms_conditions', 'TEXT');
    }
    if (oldVersion < 6) {
      final columnsToAdd = [
        'activity_name_ar',
        'activity_name_en',
        'address_ar',
        'address_en',
        'po_box',
        'telephone',
        'fax',
        'mobile',
      ];
      for (final col in columnsToAdd) {
        await _ensureColumn(db, 'company_info', col, 'TEXT');
      }
    }
    if (oldVersion < 7) {
      await _ensureColumn(
        db,
        'users',
        'must_change_password',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(db, 'vouchers', 'description', 'TEXT');
      await db.execute(
        "UPDATE users SET must_change_password = 1 WHERE username = 'admin' AND password_hash = '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92';",
      );
    }
    if (oldVersion < 8) {
      for (final column in [
        'identity_issue_date',
        'identity_source',
        'profession',
      ]) {
        await _ensureColumn(db, 'owners', column, 'TEXT');
        await _ensureColumn(db, 'tenants', column, 'TEXT');
      }
      await _ensureColumn(db, 'contracts', 'purpose', 'TEXT');
      await _ensureColumn(db, 'contracts', 'electricity_reading', 'TEXT');
    }
    if (oldVersion < 9) {
      await _ensureColumn(db, 'vouchers', 'party_name', 'TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS voucher_installment_allocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voucher_id INTEGER NOT NULL,
          installment_id INTEGER NOT NULL,
          amount REAL NOT NULL CHECK (amount > 0),
          UNIQUE (voucher_id, installment_id),
          FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
          FOREIGN KEY (installment_id) REFERENCES contract_installments (id)
        )
      ''');
    }
    if (oldVersion < 10) {
      const legacySeed =
          '1. يلتزم المستأجر بسداد الإيجار في المواعيد المحددة.\n'
          '2. لا يحق للمستأجر تأجير العين بالباطن.';
      await db.update(
        'company_info',
        {'terms_conditions': LeaseContractTerms.defaultText},
        where:
            'terms_conditions IS NULL OR TRIM(terms_conditions) = ? OR terms_conditions = ?',
        whereArgs: ['', legacySeed],
      );
    }
    if (oldVersion < 11) {
      await _ensureColumn(
        db,
        'units',
        'default_rent_period',
        "TEXT CHECK (default_rent_period IN ('monthly', 'annual') OR default_rent_period IS NULL)",
      );
      await _ensureColumn(db, 'contracts', 'unit_rent_amount', 'REAL');
      await _ensureColumn(
        db,
        'contracts',
        'unit_rent_period',
        "TEXT CHECK (unit_rent_period IN ('monthly', 'annual') OR unit_rent_period IS NULL)",
      );
    }
    if (oldVersion < 12) {
      await DatabaseIntegrityMigrations.upgradeToV12(db);
    }
    if (oldVersion < 13) {
      await _ensureColumn(
        db,
        'users',
        'is_active',
        'INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 14) {
      await _ensureColumn(
        db,
        'company_info',
        'tax_rate',
        'REAL NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100)',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'net_amount',
        'REAL NOT NULL DEFAULT 0',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'tax_rate',
        'REAL CHECK (tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100))',
      );
      // Historical invoices did not retain a rate. Preserve their recorded
      // gross/tax and derive only the net; leave tax_rate NULL rather than
      // inventing the setting that was in effect at the time.
      await db.execute('''
        UPDATE tax_invoices
        SET net_amount = ROUND(MAX(total_amount - tax_amount, 0), 2)
      ''');
    }
    if (oldVersion < 15) {
      await _ensureColumn(
        db,
        'tax_invoices',
        'installment_id',
        'INTEGER REFERENCES contract_installments(id)',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'journal_entry_id',
        'INTEGER REFERENCES journal_entries(id)',
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS voucher_invoice_allocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voucher_id INTEGER NOT NULL,
          invoice_id INTEGER NOT NULL,
          amount REAL NOT NULL CHECK (amount > 0),
          FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
          FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
        )
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS tax_invoices_installment_unique
        ON tax_invoices(installment_id)
        WHERE installment_id IS NOT NULL
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS voucher_invoice_unique
        ON voucher_invoice_allocations(voucher_id, invoice_id)
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS voucher_invoice_invoice_idx
        ON voucher_invoice_allocations(invoice_id)
      ''');
    }
  }

  Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String declaration,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info("$table")');
    if (columns.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE "$table" ADD COLUMN "$column" $declaration');
  }

  Future _createDB(Database db, int version) async {
    // 1. Company Info
    await db.execute('''
      CREATE TABLE company_info (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name_ar TEXT NOT NULL,
        name_en TEXT,
        activity TEXT,
        address TEXT,
        default_currency TEXT,
        tax_number TEXT,
        tax_rate REAL NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100),
        commercial_register TEXT,
        logo_path TEXT,
        terms_conditions TEXT,
        activity_name_ar TEXT,
        activity_name_en TEXT,
        address_ar TEXT,
        address_en TEXT,
        po_box TEXT,
        telephone TEXT,
        fax TEXT,
        mobile TEXT
      )
    ''');

    // 2. Users and Permissions
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL,
        cash_box_account_id INTEGER,
        must_change_password INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE user_permissions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        screen_name TEXT NOT NULL,
        can_view INTEGER DEFAULT 0,
        can_add INTEGER DEFAULT 0,
        can_edit INTEGER DEFAULT 0,
        can_delete INTEGER DEFAULT 0,
        can_print INTEGER DEFAULT 0,
        can_post INTEGER DEFAULT 0,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    // 3. Audit Logs
    await db.execute('''
      CREATE TABLE audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        action TEXT NOT NULL,
        details TEXT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users (id)
      )
    ''');

    // 4. Lookups
    await db.execute('''
      CREATE TABLE cities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE nationalities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE banks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        account_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE property_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE unit_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE cost_centers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL
      )
    ''');

    // 5. Chart of Accounts
    await db.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        parent_id INTEGER,
        account_type TEXT,
        balance REAL DEFAULT 0.0,
        FOREIGN KEY (parent_id) REFERENCES accounts (id)
      )
    ''');

    // 6. Owners, Properties, Units
    await db.execute('''
      CREATE TABLE owners (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        identity_number TEXT,
        identity_issue_date TEXT,
        identity_source TEXT,
        profession TEXT,
        mobile TEXT,
        iban TEXT,
        account_id INTEGER,
        commission_rate REAL,
        FOREIGN KEY (account_id) REFERENCES accounts (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE properties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        owner_id INTEGER NOT NULL,
        city_id INTEGER,
        property_type_id INTEGER,
        cost_center_id INTEGER,
        address TEXT,
        deed_number TEXT,
        FOREIGN KEY (owner_id) REFERENCES owners (id),
        FOREIGN KEY (city_id) REFERENCES cities (id),
        FOREIGN KEY (property_type_id) REFERENCES property_types (id),
        FOREIGN KEY (cost_center_id) REFERENCES cost_centers (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER NOT NULL,
        unit_number TEXT NOT NULL,
        unit_type_id INTEGER,
        floor TEXT,
        elec_meter TEXT,
        water_meter TEXT,
        status TEXT DEFAULT 'شاغرة',
        default_rent REAL,
        default_rent_period TEXT CHECK (default_rent_period IN ('monthly', 'annual') OR default_rent_period IS NULL),
        FOREIGN KEY (property_id) REFERENCES properties (id),
        FOREIGN KEY (unit_type_id) REFERENCES unit_types (id)
      )
    ''');
    await DatabaseIntegrityMigrations.installUnitNumberGuards(db);

    // 7. Tenants and Contracts
    await db.execute('''
      CREATE TABLE tenants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        identity_number TEXT,
        identity_issue_date TEXT,
        identity_source TEXT,
        profession TEXT,
        mobile TEXT,
        account_id INTEGER,
        nationality_id INTEGER,
        FOREIGN KEY (account_id) REFERENCES accounts (id),
        FOREIGN KEY (nationality_id) REFERENCES nationalities (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE contracts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tenant_id INTEGER NOT NULL,
        unit_id INTEGER NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        rent_amount REAL NOT NULL,
        unit_rent_amount REAL,
        unit_rent_period TEXT CHECK (unit_rent_period IN ('monthly', 'annual') OR unit_rent_period IS NULL),
        party_snapshot TEXT,
        payment_method TEXT,
        purpose TEXT,
        electricity_reading TEXT,
        status TEXT DEFAULT 'Active',
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (unit_id) REFERENCES units (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE contract_installments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        paid_amount REAL DEFAULT 0.0,
        due_date TEXT NOT NULL,
        status TEXT DEFAULT 'Unpaid',
        FOREIGN KEY (contract_id) REFERENCES contracts (id)
      )
    ''');

    // 8. Invoices and Vouchers
    await db.execute('''
      CREATE TABLE tax_invoices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id INTEGER,
        installment_id INTEGER,
        journal_entry_id INTEGER,
        invoice_date TEXT NOT NULL,
        net_amount REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL,
        tax_amount REAL NOT NULL,
        tax_rate REAL CHECK (tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100)),
        FOREIGN KEY (contract_id) REFERENCES contracts (id),
        FOREIGN KEY (installment_id) REFERENCES contract_installments (id),
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX tax_invoices_installment_unique
      ON tax_invoices(installment_id)
      WHERE installment_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE TABLE credit_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_id INTEGER,
        note_date TEXT NOT NULL,
        amount REAL NOT NULL,
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE vouchers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_type TEXT NOT NULL,
        voucher_date TEXT NOT NULL,
        amount REAL NOT NULL,
        tenant_id INTEGER,
        party_name TEXT,
        journal_entry_id INTEGER,
        description TEXT,
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE voucher_installment_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_id INTEGER NOT NULL,
        installment_id INTEGER NOT NULL,
        amount REAL NOT NULL CHECK (amount > 0),
        UNIQUE (voucher_id, installment_id),
        FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (installment_id) REFERENCES contract_installments (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE voucher_invoice_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_id INTEGER NOT NULL,
        invoice_id INTEGER NOT NULL,
        amount REAL NOT NULL CHECK (amount > 0),
        FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX voucher_invoice_unique
      ON voucher_invoice_allocations(voucher_id, invoice_id)
    ''');
    await db.execute('''
      CREATE INDEX voucher_invoice_invoice_idx
      ON voucher_invoice_allocations(invoice_id)
    ''');

    // 9. General Accounting (Journal Entries)
    await db.execute('''
      CREATE TABLE journal_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entry_date TEXT NOT NULL,
        description TEXT,
        is_posted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE journal_lines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        journal_entry_id INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        debit REAL DEFAULT 0.0,
        credit REAL DEFAULT 0.0,
        cost_center_id INTEGER,
        description TEXT,
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id),
        FOREIGN KEY (account_id) REFERENCES accounts (id),
        FOREIGN KEY (cost_center_id) REFERENCES cost_centers (id)
      )
    ''');

    // 10. SMS
    await db.execute('''
      CREATE TABLE sms_settings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        api_url TEXT,
        api_key TEXT,
        sender_name TEXT,
        reminder_template TEXT,
        receipt_template TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sms_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipient_number TEXT NOT NULL,
        message_text TEXT NOT NULL,
        sent_at TEXT,
        status TEXT
      )
    ''');

    await _insertSeedData(db);
  }

  Future _insertSeedData(Database db) async {
    // Seed Company Info
    await db.insert('company_info', {
      'name_ar': 'مؤسسة عبدالله النقيب التجارية',
      'name_en': 'Abdullah Al-Naqeeb Trading Est.',
      'activity': 'إدارة وتطوير العقارات والتأجير',
      'address': 'اليمن',
      'default_currency': 'ريال يمني (YER)',
      'terms_conditions': LeaseContractTerms.defaultText,
    });

    // Seed Admin User (password: 123456 encrypted in SHA-256 in production logic, here we place the pre-hashed string for 123456)
    // SHA-256 for '123456' is '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
    await db.insert('users', {
      'username': 'admin',
      'password_hash':
          '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
      'full_name': 'مدير النظام',
      'role': 'SuperAdmin',
      'must_change_password': 1,
    });

    // Seed Lookups
    final cities = ['صنعاء', 'الحديدة', 'عدن', 'تعز', 'إب'];
    for (var city in cities) {
      await db.insert('cities', {'name': city});
    }

    final propertyTypes = [
      'عمارة سكنية',
      'مجمع تجاري',
      'فيلا',
      'مستودع',
      'أرض',
    ];
    for (var pType in propertyTypes) {
      await db.insert('property_types', {'name': pType});
    }

    final unitTypes = ['شقة', 'محل تجاري', 'مكتب', 'معرض', 'ملحق', 'مستودع'];
    for (var uType in unitTypes) {
      await db.insert('unit_types', {'name': uType});
    }

    // Seed Chart of Accounts
    final accounts = [
      {
        'code': '1',
        'name': 'الأصول',
        'parent_id': null,
        'account_type': 'Asset',
      },
      {
        'code': '11',
        'name': 'النقدية والبنوك',
        'parent_id': 1,
        'account_type': 'Asset',
      },
      {
        'code': '1101',
        'name': 'الصندوق الرئيسي',
        'parent_id': 2,
        'account_type': 'Asset',
      },
      {
        'code': '1102',
        'name': 'البنك',
        'parent_id': 2,
        'account_type': 'Asset',
      },
      {
        'code': '1201',
        'name': 'ذمم المستأجرين',
        'parent_id': 1,
        'account_type': 'Asset',
      },
      {
        'code': '2',
        'name': 'الخصوم',
        'parent_id': null,
        'account_type': 'Liability',
      },
      {
        'code': '2101',
        'name': 'حسابات الملاك الجارية',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '2102',
        'name': 'تأمينات المستأجرين المستردة',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '2103',
        'name': 'ضريبة القيمة المضافة',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '4',
        'name': 'الإيرادات',
        'parent_id': null,
        'account_type': 'Revenue',
      },
      {
        'code': '4101',
        'name': 'إيرادات إيجارات العقارات',
        'parent_id': 10,
        'account_type': 'Revenue',
      },
      {
        'code': '4102',
        'name': 'إيرادات عمولات السعي والإدارة',
        'parent_id': 10,
        'account_type': 'Revenue',
      },
      {
        'code': '5',
        'name': 'المصروفات',
        'parent_id': null,
        'account_type': 'Expense',
      },
      {
        'code': '5101',
        'name': 'المصروفات الإدارية والنثرية',
        'parent_id': 13,
        'account_type': 'Expense',
      },
      {
        'code': '5102',
        'name': 'رواتب وأجور الموظفين',
        'parent_id': 13,
        'account_type': 'Expense',
      },
      {
        'code': '5103',
        'name': 'مصاريف صيانة العقارات',
        'parent_id': 13,
        'account_type': 'Expense',
      },
    ];

    for (var acc in accounts) {
      await db.insert('accounts', acc);
    }
  }

  // --- CRUD Operations for Authentication and Users ---

  /// Credential lookup for AuthProvider only; this is not a UI user model.
  Future<Map<String, dynamic>?> getAuthenticationRecordByUsername(
    String username,
  ) async {
    if (PermissionRuntime.hasSession) {
      throw StateError('واجهة بيانات الاعتماد مخصصة لما قبل تسجيل الدخول');
    }
    final db = await instance.database;
    final result = await db.query(
      'users',
      columns: [
        'id',
        'username',
        'password_hash',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
      ],
      where: 'username = ?',
      whereArgs: [username],
    );
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<bool> isUserSessionValid({
    required int userId,
    required String expectedRole,
    required String expectedPasswordHash,
  }) async {
    if (PermissionRuntime.userId != userId) return false;
    final db = await instance.database;
    final rows = await db.query(
      'users',
      columns: ['role', 'is_active', 'password_hash'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    return (row['is_active'] as num?)?.toInt() == 1 &&
        row['role'] == expectedRole &&
        row['password_hash'] == expectedPasswordHash;
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    PermissionRuntime.require('system_settings', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query(
      'users',
      columns: [
        'id',
        'username',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
      ],
      orderBy: 'full_name COLLATE NOCASE',
    );
  }

  Future<int> insertUser(Map<String, dynamic> user) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.add);
    final username = user['username']?.toString().trim() ?? '';
    final fullName = user['full_name']?.toString().trim() ?? '';
    final passwordHash = user['password_hash']?.toString() ?? '';
    final role = user['role']?.toString() ?? '';
    if (username.isEmpty || fullName.isEmpty || passwordHash.isEmpty) {
      throw ArgumentError('اسم المستخدم والاسم الكامل وكلمة المرور مطلوبة');
    }
    if (!const {
      'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    }.contains(role)) {
      throw ArgumentError('الدور المحدد غير صالح');
    }
    if (role == 'SuperAdmin' && PermissionRuntime.role != 'SuperAdmin') {
      throw StateError('إنشاء مدير نظام أعلى يتطلب صلاحية مدير النظام الأعلى');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final id = await txn.insert('users', {
        'username': username,
        'full_name': fullName,
        'password_hash': passwordHash,
        'role': role,
        'cash_box_account_id': user['cash_box_account_id'],
        'must_change_password': user['must_change_password'] ?? 1,
      });
      await txn.insert('audit_logs', {
        'user_id': PermissionRuntime.userId,
        'action': 'USER_CREATE',
        'details': 'تم إنشاء المستخدم $username بدور $role',
        'timestamp': DateTime.now().toIso8601String(),
      });
      return id;
    });
  }

  Future<int> updateUser(Map<String, dynamic> user) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    final id = (user['id'] as num?)?.toInt();
    if (id == null) throw ArgumentError('معرف المستخدم مطلوب');
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('المستخدم غير موجود');
      final currentRole = rows.first['role']?.toString() ?? '';
      final nextRole = user['role']?.toString() ?? currentRole;
      if (currentRole == 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تعديل حساب مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (!const {
        'SuperAdmin',
        'Admin',
        'Accountant',
        'DataEntry',
      }.contains(nextRole)) {
        throw ArgumentError('الدور المحدد غير صالح');
      }
      if (id == PermissionRuntime.userId && nextRole != currentRole) {
        throw StateError('لا يمكن تغيير دور المستخدم المسجل دخوله');
      }
      if (currentRole == 'SuperAdmin' &&
          nextRole != 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تخفيض مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (nextRole == 'SuperAdmin' &&
          currentRole != 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('ترقية مستخدم إلى مدير نظام أعلى تتطلب صلاحية خاصة');
      }
      if (currentRole == 'SuperAdmin' && nextRole != 'SuperAdmin') {
        final countRows = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin'",
        );
        final count = (countRows.first['count'] as num).toInt();
        if (count <= 1) throw StateError('لا يمكن تخفيض آخر مدير نظام أعلى');
      }
      final changes = <String, Object?>{};
      if (user.containsKey('username')) {
        final value = user['username']?.toString().trim() ?? '';
        if (value.isEmpty) throw ArgumentError('اسم المستخدم مطلوب');
        changes['username'] = value;
      }
      if (user.containsKey('full_name')) {
        final value = user['full_name']?.toString().trim() ?? '';
        if (value.isEmpty) throw ArgumentError('الاسم الكامل مطلوب');
        changes['full_name'] = value;
      }
      if (user.containsKey('role')) changes['role'] = nextRole;
      if (user.containsKey('cash_box_account_id')) {
        changes['cash_box_account_id'] = user['cash_box_account_id'];
      }
      if (changes.isEmpty) return 0;
      final updated = await txn.update(
        'users',
        changes,
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated > 0) {
        await txn.insert('audit_logs', {
          'user_id': PermissionRuntime.userId,
          'action': 'USER_UPDATE',
          'details': 'تم تحديث بيانات المستخدم رقم $id',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
      return updated;
    });
  }

  Future<int> updateUserPassword(
    int userId,
    String passwordHash, {
    bool mustChangePassword = false,
  }) async {
    if (PermissionRuntime.userId != userId) {
      PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    }
    final db = await instance.database;
    if (PermissionRuntime.userId != userId) {
      final target = await db.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (target.isNotEmpty &&
          target.first['role'] == 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError(
          'إعادة تعيين كلمة مرور مدير النظام الأعلى تتطلب صلاحية خاصة',
        );
      }
    }
    return db.update(
      'users',
      {
        'password_hash': passwordHash,
        'must_change_password': mustChangePassword ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<int> setUserActive(int userId, bool isActive) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    if (!isActive && userId == PermissionRuntime.userId) {
      throw StateError('لا يمكن إيقاف حساب المستخدم المسجل دخوله');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      final role = rows.first['role']?.toString() ?? '';
      final currentlyActive = (rows.first['is_active'] as num?)?.toInt() == 1;
      if (currentlyActive == isActive) return 0;
      if (role == 'SuperAdmin' && PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تغيير حالة مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (!isActive && role == 'SuperAdmin') {
        final activeSuperAdmins = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin' AND is_active = 1",
        );
        if ((activeSuperAdmins.first['count'] as num).toInt() <= 1) {
          throw StateError('لا يمكن إيقاف آخر مدير نظام أعلى نشط');
        }
      }
      final updated = await txn.update(
        'users',
        {'is_active': isActive ? 1 : 0},
        where: 'id = ?',
        whereArgs: [userId],
      );
      if (updated > 0) {
        await txn.insert('audit_logs', {
          'user_id': PermissionRuntime.userId,
          'action': isActive ? 'USER_ACTIVATE' : 'USER_DEACTIVATE',
          'details': 'تم ${isActive ? 'تفعيل' : 'إيقاف'} المستخدم رقم $userId',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
      return updated;
    });
  }

  Future<int> deleteUser(int id) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    if (id == PermissionRuntime.userId) {
      throw StateError('لا يمكن حذف حساب المستخدم المسجل دخوله');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      if (rows.first['role'] == 'SuperAdmin') {
        if (PermissionRuntime.role != 'SuperAdmin') {
          throw StateError('حذف مدير النظام الأعلى يتطلب صلاحية خاصة');
        }
        final countRows = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin'",
        );
        if ((countRows.first['count'] as num).toInt() <= 1) {
          throw StateError('لا يمكن حذف آخر مدير نظام أعلى');
        }
      }
      return txn.delete('users', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Map<String, dynamic>>> getUserPermissions(int userId) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.view);
    return _readUserPermissions(userId);
  }

  /// Used only after successful credential verification to establish the
  /// authenticated user's session before protected routes are shown.
  Future<List<Map<String, dynamic>>> getUserPermissionsForAuthentication(
    int userId,
  ) async {
    if (PermissionRuntime.userId != userId) {
      throw StateError('يمكن تحميل صلاحيات جلسة المستخدم الحالي فقط');
    }
    return _readUserPermissions(userId);
  }

  Future<List<Map<String, dynamic>>> _readUserPermissions(int userId) async {
    final db = await instance.database;
    return db.query(
      'user_permissions',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'screen_name',
    );
  }

  Future<void> replaceUserPermissions(
    int userId,
    List<Map<String, dynamic>> permissions,
  ) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    if (userId == PermissionRuntime.userId) {
      throw StateError('لا يمكن للمستخدم تعديل صلاحيات حسابه بنفسه');
    }
    final normalized = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final permission in permissions) {
      final code = permission['screen_name']?.toString() ?? '';
      if (AppPermissionCatalog.module(code) == null || !seen.add(code)) {
        throw ArgumentError('مجموعة الصلاحيات تحتوي قسمًا غير معروف أو مكررًا');
      }
      final normalizedRow = <String, Object?>{
        'screen_name': code,
        for (final action in AppPermissionAction.values)
          action.databaseColumn: _permissionValue(
            permission[action.databaseColumn],
          ),
      };
      if (normalizedRow['can_view'] == 0 &&
          AppPermissionAction.values
              .where((action) => action != AppPermissionAction.view)
              .any((action) => normalizedRow[action.databaseColumn] == 1)) {
        throw ArgumentError('لا يمكن منح إجراء دون منح صلاحية عرض القسم');
      }
      normalized.add(normalizedRow);
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final users = await txn.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty) throw StateError('المستخدم غير موجود');
      if (users.first['role'] == 'SuperAdmin' && normalized.isNotEmpty) {
        throw StateError('مدير النظام الأعلى يمتلك جميع الصلاحيات دائمًا');
      }
      await txn.delete(
        'user_permissions',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      for (final permission in normalized) {
        await txn.insert('user_permissions', {
          'user_id': userId,
          ...permission,
        });
      }
      await txn.insert('audit_logs', {
        'user_id': PermissionRuntime.userId,
        'action': 'USER_PERMISSIONS_UPDATE',
        'details': 'تم تحديث صلاحيات المستخدم رقم $userId',
        'timestamp': DateTime.now().toIso8601String(),
      });
    });
  }

  int _permissionValue(Object? value) =>
      value == true || (value is num && value.toInt() == 1) ? 1 : 0;

  // --- CRUD Operations for Audit Logs ---

  Future<int> recordAuthenticationAudit({
    required int expectedUserId,
    required bool isLogin,
  }) async {
    final userId = PermissionRuntime.userId;
    if (userId == null || userId != expectedUserId) {
      throw StateError('لا توجد جلسة مطابقة لتسجيل حدث التدقيق');
    }
    final db = await instance.database;
    return db.insert('audit_logs', {
      'user_id': userId,
      'action': isLogin ? 'LOGIN' : 'LOGOUT',
      'details': isLogin ? 'تم تسجيل الدخول بنجاح' : 'تم تسجيل الخروج',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // --- CRUD Operations for Company Info ---

  Future<Map<String, dynamic>?> getCompanyInfo() async {
    final db = await instance.database;
    final result = await db.query('company_info');
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<int> updateCompanyInfo(Map<String, dynamic> info) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    final db = await instance.database;
    final rows = await db.query('company_info', columns: ['id'], limit: 1);
    final values = Map<String, dynamic>.from(info)..remove('id');
    if (values.containsKey('tax_rate')) {
      final rawRate = values['tax_rate'];
      final rate = rawRate is num
          ? rawRate.toDouble()
          : double.tryParse(rawRate?.toString() ?? '') ?? double.nan;
      if (!InternalTax.isValidRate(rate)) {
        throw ArgumentError('نسبة الضريبة يجب أن تكون بين 0 و100');
      }
      values['tax_rate'] = rate;
    }
    if (rows.isEmpty) return db.insert('company_info', values);
    final id = info['id'] ?? rows.first['id'];
    return db.update('company_info', values, where: 'id = ?', whereArgs: [id]);
  }

  // --- Generic CRUD Operations for Lookups ---

  Future<List<Map<String, dynamic>>> getLookupData(String tableName) async {
    _validateLookupTable(tableName);
    _requireLookupReadPermission(tableName);
    final db = await instance.database;
    return await db.query(tableName);
  }

  Future<int> insertLookupData(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.add);
    final db = await instance.database;

    // Auto-generate code for cost_centers
    if (tableName == 'cost_centers' &&
        (!data.containsKey('code') ||
            data['code'] == null ||
            data['code'].toString().isEmpty)) {
      final List<Map<String, dynamic>> maps = await db.rawQuery(
        'SELECT code FROM cost_centers ORDER BY id DESC LIMIT 1',
      );
      String newCode = 'CC001';
      if (maps.isNotEmpty && maps.first['code'] != null) {
        final lastCode = maps.first['code'] as String;
        if (lastCode.startsWith('CC') && lastCode.length > 2) {
          final numericPart = int.tryParse(lastCode.substring(2));
          if (numericPart != null) {
            newCode = 'CC${(numericPart + 1).toString().padLeft(3, '0')}';
          }
        }
      }
      data['code'] = newCode;
    }

    return await db.insert(tableName, data);
  }

  Future<int> updateLookupData(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.edit);
    final db = await instance.database;
    return await db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [data['id']],
    );
  }

  Future<int> deleteLookupData(String tableName, int id) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.delete);
    final db = await instance.database;
    return await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  // --- Accounting Operations ---

  Future<List<Map<String, dynamic>>> getAllAccounts() async {
    final canViewAccounting = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.view,
    );
    final canViewFinancial = PermissionRuntime.allows(
      'tenant_financial',
      AppPermissionAction.view,
    );
    final canViewReports = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    if (!canViewAccounting && !canViewFinancial && !canViewReports) {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    }
    final db = await instance.database;
    if (canViewAccounting) return db.query('accounts');
    return db.query(
      'accounts',
      columns: ['id', 'code', 'name', 'parent_id', 'account_type'],
    );
  }

  Future<Map<String, dynamic>?> getAccountById(int id) async {
    final canViewAccounting = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.view,
    );
    final canViewFinancial = PermissionRuntime.allows(
      'tenant_financial',
      AppPermissionAction.view,
    );
    final canViewReports = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    if (!canViewAccounting && !canViewFinancial && !canViewReports) {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    }
    final db = await instance.database;
    final result = await db.query(
      'accounts',
      columns: canViewAccounting
          ? null
          : ['id', 'code', 'name', 'parent_id', 'account_type'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<String> generateAccountCode(int parentId) async {
    PermissionRuntime.require('accounting', AppPermissionAction.add);
    final db = await instance.database;
    return _nextAccountCodeTx(db, parentId);
  }

  Future<String> _nextAccountCodeTx(
    DatabaseExecutor executor,
    int parentId,
  ) async {
    final parentRows = await executor.query(
      'accounts',
      columns: ['id', 'code', 'parent_id', 'account_type', 'balance'],
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (parentRows.isEmpty) throw StateError('الحساب الأعلى غير موجود');
    final parent = parentRows.first;
    final parentCode = parent['code']?.toString() ?? '';
    final accountType = parent['account_type']?.toString();
    if (parentCode.isEmpty || !_accountTypeRootCodes.containsKey(accountType)) {
      throw StateError('نوع أو رمز الحساب الأعلى غير صالح');
    }

    final children = await executor.query(
      'accounts',
      columns: ['code'],
      where: 'parent_id = ?',
      whereArgs: [parentId],
    );
    const linkedEntityColumns = {
      'owners': 'account_id',
      'tenants': 'account_id',
      'banks': 'account_id',
      'users': 'cash_box_account_id',
    };
    for (final reference in linkedEntityColumns.entries) {
      final linkedRows = await executor.query(
        reference.key,
        columns: ['id'],
        where: '${reference.value} = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (linkedRows.isNotEmpty) {
        throw StateError('لا يمكن إضافة حساب فرعي لحساب مرتبط بسجل تشغيلي');
      }
    }
    if (children.isEmpty) {
      final activity = await executor.query(
        'journal_lines',
        columns: ['id'],
        where: 'account_id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      final balance = (parent['balance'] as num?)?.toDouble() ?? 0.0;
      if (activity.isNotEmpty || !balance.isFinite || balance.abs() >= 0.005) {
        throw StateError('لا يمكن تحويل حساب له رصيد أو حركة إلى حساب تجميعي');
      }
    }

    final suffixLength = parent['parent_id'] == null ? 1 : 2;
    final maximumSequence = suffixLength == 1 ? 9 : 99;
    final allCodes = (await executor.query(
      'accounts',
      columns: ['code'],
    )).map((account) => account['code']?.toString() ?? '').toList();
    var sequence = 0;
    for (final child in children) {
      final childCode = child['code']?.toString() ?? '';
      if (!childCode.startsWith(parentCode) ||
          childCode.length <= parentCode.length) {
        continue;
      }
      final suffix = childCode.substring(parentCode.length);
      if (suffix.length > suffixLength) continue;
      final parsed = int.tryParse(suffix);
      if (parsed != null && parsed > sequence) sequence = parsed;
    }

    while (sequence < maximumSequence) {
      sequence++;
      final code =
          '$parentCode${sequence.toString().padLeft(suffixLength, '0')}';
      final isAmbiguousPrefix = allCodes.any(
        (existingCode) =>
            existingCode.length > code.length && existingCode.startsWith(code),
      );
      if (!allCodes.contains(code) && !isAmbiguousPrefix) return code;
    }
    throw StateError('اكتمل عدد الحسابات الفرعية المتاح لهذا الحساب');
  }

  Future<int> insertAccount(Map<String, dynamic> account) async {
    PermissionRuntime.require('accounting', AppPermissionAction.add);
    final name = (account['name'] as String?)?.trim() ?? '';
    final parentValue = account['parent_id'];
    if (name.isEmpty) throw ArgumentError('اسم الحساب مطلوب');
    if (parentValue != null && (parentValue is! int || parentValue <= 0)) {
      throw ArgumentError('الحساب الأعلى غير صالح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      late final String code;
      late final String accountType;
      if (parentValue == null) {
        accountType = account['account_type']?.toString() ?? '';
        final rootCode = _accountTypeRootCodes[accountType];
        if (rootCode == null)
          throw ArgumentError('نوع الحساب الرئيسي غير صالح');
        final existingType = await txn.query(
          'accounts',
          columns: ['id'],
          where: 'parent_id IS NULL AND account_type = ?',
          whereArgs: [accountType],
          limit: 1,
        );
        if (existingType.isNotEmpty) {
          throw StateError('يوجد حساب رئيسي لهذا النوع بالفعل');
        }
        code = rootCode;
      } else {
        final parentId = parentValue as int;
        final parentRows = await txn.query(
          'accounts',
          columns: ['id', 'account_type'],
          where: 'id = ?',
          whereArgs: [parentId],
          limit: 1,
        );
        if (parentRows.isEmpty) throw StateError('الحساب الأعلى غير موجود');
        accountType = parentRows.first['account_type']?.toString() ?? '';
        if (!_accountTypeRootCodes.containsKey(accountType)) {
          throw StateError('نوع الحساب الأعلى غير صالح');
        }
        final requestedType = account['account_type']?.toString();
        if (requestedType != null && requestedType != accountType) {
          throw ArgumentError('الحساب الفرعي يرث نوع الحساب الأعلى');
        }
        code = await _nextAccountCodeTx(txn, parentId);
      }

      final codeCollision = await txn.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: [code],
        limit: 1,
      );
      if (codeCollision.isNotEmpty)
        throw StateError('رمز الحساب مستخدم بالفعل');

      final id = await txn.insert('accounts', {
        'code': code,
        'name': name,
        'parent_id': parentValue,
        'account_type': accountType,
        'balance': 0.0,
      });
      await txn.insert('audit_logs', {
        'user_id': PermissionRuntime.userId,
        'action': 'ACCOUNT_CREATE',
        'details': 'إنشاء الحساب $code - $name',
        'timestamp': DateTime.now().toIso8601String(),
      });
      return id;
    });
  }

  Future<int> updateAccount(int accountId, String accountName) async {
    PermissionRuntime.require('accounting', AppPermissionAction.edit);
    final name = accountName.trim();
    if (accountId <= 0 || name.isEmpty) {
      throw ArgumentError('معرف الحساب والاسم حقول مطلوبة');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        columns: ['id', 'code', 'name'],
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الحساب غير موجود');
      final oldName = rows.first['name']?.toString() ?? '';
      final changed = await txn.update(
        'accounts',
        {'name': name},
        where: 'id = ?',
        whereArgs: [accountId],
      );
      if (changed != 1) throw StateError('تعذر تحديث الحساب');
      await txn.insert('audit_logs', {
        'user_id': PermissionRuntime.userId,
        'action': 'ACCOUNT_RENAME',
        'details': 'تعديل اسم الحساب ${rows.first['code']}: $oldName ← $name',
        'timestamp': DateTime.now().toIso8601String(),
      });
      return changed;
    });
  }

  Future<int> deleteAccount(int accountId) async {
    PermissionRuntime.require('accounting', AppPermissionAction.delete);
    if (accountId <= 0) throw ArgumentError('معرف الحساب غير صالح');
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        columns: ['id', 'code', 'name', 'balance'],
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الحساب غير موجود');
      final account = rows.first;
      final code = account['code']?.toString() ?? '';
      final balance = (account['balance'] as num?)?.toDouble() ?? 0.0;
      if (_protectedSystemAccountCodes.contains(code)) {
        throw StateError('لا يمكن حذف حساب أساسي يستخدمه النظام');
      }
      if (!balance.isFinite || balance.abs() >= 0.005) {
        throw StateError('لا يمكن حذف حساب له رصيد');
      }

      const references = {
        'accounts': 'parent_id',
        'journal_lines': 'account_id',
        'owners': 'account_id',
        'tenants': 'account_id',
        'banks': 'account_id',
        'users': 'cash_box_account_id',
      };
      for (final entry in references.entries) {
        final linkedRows = await txn.query(
          entry.key,
          columns: ['id'],
          where: '${entry.value} = ?',
          whereArgs: [accountId],
          limit: 1,
        );
        if (linkedRows.isNotEmpty) {
          throw StateError('لا يمكن حذف حساب مرتبط بحركات أو بيانات أخرى');
        }
      }

      await txn.insert('audit_logs', {
        'user_id': PermissionRuntime.userId,
        'action': 'ACCOUNT_DELETE',
        'details': 'حذف الحساب $code - ${account['name']}',
        'timestamp': DateTime.now().toIso8601String(),
      });
      return txn.delete('accounts', where: 'id = ?', whereArgs: [accountId]);
    });
  }

  // Journal Entries with Transactions
  Future<int> insertJournalEntryWithLines(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> lines,
  ) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    final rawDate = header['entry_date']?.toString().trim() ?? '';
    final dateText = rawDate.length >= 10 ? rawDate.substring(0, 10) : '';
    final parsedDate = DateTime.tryParse(rawDate);
    final parsedDay = DateTime.tryParse(dateText);
    if (parsedDate == null ||
        parsedDay == null ||
        parsedDay.toIso8601String().substring(0, 10) != dateText ||
        (rawDate.length > 10 && rawDate[10] != 'T' && rawDate[10] != ' ')) {
      throw ArgumentError('تاريخ القيد غير صحيح');
    }
    final description = (header['description'] as String?)?.trim() ?? '';
    if (description.isEmpty) throw ArgumentError('بيان القيد مطلوب');
    if (lines.length < 2) {
      throw ArgumentError('يجب أن يحتوي القيد على سطرين على الأقل');
    }
    int debitCents = 0;
    int creditCents = 0;
    final validatedLines = <Map<String, dynamic>>[];
    for (final line in lines) {
      final accountId = line['account_id'];
      final debit = (line['debit'] as num? ?? 0).toDouble();
      final credit = (line['credit'] as num? ?? 0).toDouble();
      final costCenterId = line['cost_center_id'];
      if (accountId is! int || accountId <= 0) {
        throw ArgumentError('اختر حساباً صالحاً لكل سطر');
      }
      if (costCenterId != null && (costCenterId is! int || costCenterId <= 0)) {
        throw ArgumentError('مركز تكلفة أحد الأسطر غير صالح');
      }
      if (!_hasCentPrecision(debit) ||
          !_hasCentPrecision(credit) ||
          debit < 0 ||
          credit < 0 ||
          (debit > 0 && credit > 0) ||
          (debit == 0 && credit == 0)) {
        throw ArgumentError('قيمة أحد أسطر القيد غير صحيحة');
      }
      debitCents += (debit * 100).round();
      creditCents += (credit * 100).round();
      validatedLines.add({
        'account_id': accountId,
        'debit': debit,
        'credit': credit,
        'cost_center_id': costCenterId,
        'description': (line['description'] as String?)?.trim(),
      });
    }
    if (debitCents != creditCents || debitCents == 0) {
      throw ArgumentError(
        'القيد غير متوازن: يجب أن يتساوى إجمالي المدين والدائن',
      );
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      final journalId = await txn.insert('journal_entries', {
        'entry_date': dateText,
        'description': description,
        'is_posted': 1,
      });

      for (final line in validatedLines) {
        final accountId = line['account_id'] as int;
        await _requireLeafAccountTx(txn, accountId);
        await _requireCostCenterTx(txn, line['cost_center_id']);
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': accountId,
          'debit': line['debit'],
          'credit': line['credit'],
          'cost_center_id': line['cost_center_id'],
          'description': line['description'],
        });
        final debit = (line['debit'] as num? ?? 0).toDouble();
        final credit = (line['credit'] as num? ?? 0).toDouble();
        await _updateBalanceTx(txn, accountId, debit, credit);
      }
      return journalId;
    });
  }

  // General Vouchers (Receipts/Payments) with Auto-Posting
  Future<int> insertGeneralVoucher(
    Map<String, dynamic> voucher,
    int cashAccountId,
    int oppositeAccountId,
    int? costCenterId,
    String voucherType,
  ) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    if (voucherType != 'قبض عام' && voucherType != 'صرف عام') {
      throw ArgumentError('نوع السند غير معروف');
    }
    if (voucher['voucher_type'] != voucherType) {
      throw ArgumentError('نوع السند المخزن لا يطابق نوع الترحيل');
    }
    final amountValue = voucher['amount'];
    if (amountValue is! num ||
        amountValue <= 0 ||
        !_hasCentPrecision(amountValue) ||
        DateTime.tryParse(voucher['voucher_date']?.toString() ?? '') == null) {
      throw ArgumentError('مبلغ أو تاريخ السند غير صحيح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      final oppositeAccount = await _requireLeafAccountTx(
        txn,
        oppositeAccountId,
      );
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('حساب النقدية يجب أن يكون صندوقاً أو بنكاً');
      }
      final allowedCounterpartTypes = voucherType == 'قبض عام'
          ? ['Asset', 'Liability', 'Equity', 'Revenue']
          : ['Asset', 'Liability', 'Equity', 'Expense'];
      if (oppositeAccountId == cashAccountId ||
          !allowedCounterpartTypes.contains(oppositeAccount['account_type'])) {
        throw ArgumentError('الحساب المقابل غير صالح');
      }
      await _requireCostCenterTx(txn, costCenterId);
      final amount = (voucher['amount'] as num).toDouble();
      final date = voucher['voucher_date'];
      final description =
          (voucher['description'] as String?)?.trim().isNotEmpty == true
          ? (voucher['description'] as String).trim()
          : 'سند $voucherType';
      final partyName = (voucher['party_name'] as String?)?.trim();
      voucher['party_name'] = partyName?.isNotEmpty == true
          ? partyName
          : description;

      // 1. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': date,
        'description': description,
        'is_posted': 1,
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 2. Insert Journal Lines
      Map<String, dynamic> line1 = {'journal_entry_id': journalId};
      Map<String, dynamic> line2 = {'journal_entry_id': journalId};

      if (voucherType == 'قبض عام') {
        // Cash Account (Debit)
        line1['account_id'] = cashAccountId;
        line1['debit'] = amount;
        line1['credit'] = 0.0;
        line1['description'] = description;

        // Revenue/Opposite Account (Credit)
        line2['account_id'] = oppositeAccountId;
        line2['debit'] = 0.0;
        line2['credit'] = amount;
        line2['description'] = description;
        line2['cost_center_id'] = costCenterId;
      } else if (voucherType == 'صرف عام') {
        // Expense/Opposite Account (Debit)
        line1['account_id'] = oppositeAccountId;
        line1['debit'] = amount;
        line1['credit'] = 0.0;
        line1['description'] = description;
        line1['cost_center_id'] = costCenterId;

        // Cash Account (Credit)
        line2['account_id'] = cashAccountId;
        line2['debit'] = 0.0;
        line2['credit'] = amount;
        line2['description'] = description;
      }

      await txn.insert('journal_lines', line1);
      await txn.insert('journal_lines', line2);

      // Update balances (simplified logic here for brevity, in production we might use a trigger or shared function)
      // Debit line
      await _updateBalanceTx(
        txn,
        line1['account_id'],
        line1['debit'],
        line1['credit'],
      );
      // Credit line
      await _updateBalanceTx(
        txn,
        line2['account_id'],
        line2['debit'],
        line2['credit'],
      );

      // 3. Insert Voucher
      voucher['journal_entry_id'] = journalId;
      final voucherId = await txn.insert('vouchers', voucher);
      return voucherId;
    });
  }

  Future<void> _updateBalanceTx(
    Transaction txn,
    int accountId,
    double debit,
    double credit,
  ) async {
    if (!_hasCentPrecision(debit) ||
        !_hasCentPrecision(credit) ||
        debit < 0 ||
        credit < 0 ||
        (debit > 0 && credit > 0)) {
      throw ArgumentError('قيمة حركة الحساب غير صحيحة');
    }
    final debitCents = (debit * 100).round();
    final creditCents = (credit * 100).round();
    int? currentAccountId = accountId;

    while (currentAccountId != null) {
      final accountResult = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [currentAccountId],
      );
      if (accountResult.isEmpty) {
        throw StateError('تعذر تحديث رصيد حساب غير موجود');
      }
      final accountMap = accountResult.first;
      final accountType = accountMap['account_type']?.toString();
      final currentBalance = (accountMap['balance'] as num?)?.toDouble() ?? 0.0;
      if (!currentBalance.isFinite ||
          !_accountTypeRootCodes.containsKey(accountType)) {
        throw StateError('رصيد أو نوع الحساب غير صالح');
      }
      final currentCents = (currentBalance * 100).round();
      final deltaCents = accountType == 'Asset' || accountType == 'Expense'
          ? debitCents - creditCents
          : creditCents - debitCents;
      final nextBalance = (currentCents + deltaCents) / 100.0;
      await txn.update(
        'accounts',
        {'balance': nextBalance},
        where: 'id = ?',
        whereArgs: [currentAccountId],
      );
      currentAccountId = accountMap['parent_id'] as int?;
    }
  }

  Future<Map<String, dynamic>> _requireLeafAccountTx(
    DatabaseExecutor executor,
    int accountId, {
    String? expectedType,
  }) async {
    final rows = await executor.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['parent_id'] == null) {
      throw ArgumentError('اختر حساباً تفصيلياً صالحاً');
    }
    final account = rows.first;
    final accountType = account['account_type']?.toString();
    if (!_accountTypeRootCodes.containsKey(accountType) ||
        (expectedType != null && accountType != expectedType)) {
      throw ArgumentError('نوع الحساب لا يناسب هذه الحركة');
    }
    final children = await executor.query(
      'accounts',
      columns: ['id'],
      where: 'parent_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (children.isNotEmpty)
      throw ArgumentError('لا يمكن الترحيل على حساب تجميعي');

    final visited = <int>{accountId};
    var parentId = account['parent_id'] as int?;
    while (parentId != null) {
      if (!visited.add(parentId)) throw StateError('تسلسل الحسابات يحتوي دورة');
      final parentRows = await executor.query(
        'accounts',
        columns: ['parent_id', 'account_type'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (parentRows.isEmpty ||
          parentRows.first['account_type'] != accountType) {
        throw StateError('نوع الحساب لا يطابق سلسلة الحسابات الأعلى');
      }
      parentId = parentRows.first['parent_id'] as int?;
    }
    return account;
  }

  Future<void> _requireCostCenterTx(
    DatabaseExecutor executor,
    Object? costCenterId,
  ) async {
    if (costCenterId == null) return;
    if (costCenterId is! int || costCenterId <= 0) {
      throw ArgumentError('مركز التكلفة غير صالح');
    }
    final rows = await executor.query(
      'cost_centers',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [costCenterId],
      limit: 1,
    );
    if (rows.isEmpty) throw ArgumentError('مركز التكلفة المحدد غير موجود');
  }

  // --- Owner & Property Operations ---

  Future<void> _requireOptionalLookup(
    DatabaseExecutor executor,
    String table,
    Object? id,
    String label,
  ) async {
    if (id == null) return;
    if (id is! int || id <= 0) throw ArgumentError('$label غير صالح');
    final rows = await executor.query(
      table,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw ArgumentError('$label المحدد غير موجود');
  }

  Future<void> insertOwnerWithAccount(Map<String, dynamic> owner) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final name = (owner['name'] as String?)?.trim() ?? '';
    final commission = (owner['commission_rate'] as num?)?.toDouble() ?? 0;
    if (name.isEmpty) throw ArgumentError('اسم المالك مطلوب');
    if (!commission.isFinite || commission < 0 || commission > 100) {
      throw ArgumentError('نسبة العمولة يجب أن تكون بين صفر و100');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Find the parent account for Owners (code: '2101')
      final parentResult = await txn.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['2101'],
      );
      if (parentResult.isEmpty)
        throw Exception('حساب الملاك الرئيسي غير موجود (2101)');

      final parentId = parentResult.first['id'] as int;
      final newCode = await _nextAccountCodeTx(txn, parentId);

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': name,
        'parent_id': parentId,
        'account_type': 'Liability', // Since '2101' is a liability
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Owner linked to the new account
      final ownerValues = Map<String, dynamic>.from(owner)
        ..remove('id')
        ..remove('account_id')
        ..['name'] = name
        ..['commission_rate'] = commission
        ..['account_id'] = accountId;
      await txn.insert('owners', ownerValues);
    });
  }

  Future<List<Map<String, dynamic>>> getAllOwners() async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('owners');
  }

  Future<void> updateOwner(Map<String, dynamic> owner) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final ownerId = owner['id'];
    final name = (owner['name'] as String?)?.trim() ?? '';
    final commission = (owner['commission_rate'] as num?)?.toDouble() ?? 0;
    if (ownerId is! int || ownerId <= 0 || name.isEmpty) {
      throw ArgumentError('معرف المالك والاسم حقول مطلوبة');
    }
    if (!commission.isFinite || commission < 0 || commission > 100) {
      throw ArgumentError('نسبة العمولة يجب أن تكون بين صفر و100');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'owners',
        columns: ['id', 'account_id'],
        where: 'id = ?',
        whereArgs: [ownerId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('المالك المطلوب غير موجود');

      final changed = await txn.update(
        'owners',
        {
          'name': name,
          'identity_number': owner['identity_number'],
          'identity_issue_date': owner['identity_issue_date'],
          'identity_source': owner['identity_source'],
          'profession': owner['profession'],
          'mobile': owner['mobile'],
          'iban': owner['iban'],
          'commission_rate': commission,
        },
        where: 'id = ?',
        whereArgs: [ownerId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات المالك');

      final accountId = existing.first['account_id'] as int?;
      if (accountId != null) {
        final changedAccount = await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
        if (changedAccount != 1) {
          throw StateError('الحساب المحاسبي المرتبط بالمالك غير موجود');
        }
      }
    });
  }

  Future<int> insertProperty(Map<String, dynamic> property) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final name = (property['name'] as String?)?.trim() ?? '';
    final ownerId = property['owner_id'];
    if (name.isEmpty || ownerId is! int || ownerId <= 0) {
      throw ArgumentError('اسم العقار والمالك حقول مطلوبة');
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      await _requireOptionalLookup(txn, 'owners', ownerId, 'مالك العقار');
      await _requireOptionalLookup(
        txn,
        'cities',
        property['city_id'],
        'المدينة',
      );
      await _requireOptionalLookup(
        txn,
        'property_types',
        property['property_type_id'],
        'نوع العقار',
      );
      await _requireOptionalLookup(
        txn,
        'cost_centers',
        property['cost_center_id'],
        'مركز التكلفة',
      );
      final values = Map<String, dynamic>.from(property)
        ..remove('id')
        ..['name'] = name;
      return txn.insert('properties', values);
    });
  }

  Future<void> updateProperty(Map<String, dynamic> property) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final propertyId = property['id'];
    final name = (property['name'] as String?)?.trim() ?? '';
    final ownerId = property['owner_id'];
    if (propertyId is! int ||
        propertyId <= 0 ||
        name.isEmpty ||
        ownerId is! int) {
      throw ArgumentError('معرف العقار والاسم والمالك حقول مطلوبة');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(txn, 'owners', ownerId, 'مالك العقار');
      await _requireOptionalLookup(
        txn,
        'cities',
        property['city_id'],
        'المدينة',
      );
      await _requireOptionalLookup(
        txn,
        'property_types',
        property['property_type_id'],
        'نوع العقار',
      );
      await _requireOptionalLookup(
        txn,
        'cost_centers',
        property['cost_center_id'],
        'مركز التكلفة',
      );
      final existing = await txn.query(
        'properties',
        columns: ['id', 'owner_id'],
        where: 'id = ?',
        whereArgs: [propertyId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('العقار المطلوب غير موجود');
      final previousOwnerId = existing.first['owner_id'] as int;
      if (previousOwnerId != ownerId) {
        final history = await txn.rawQuery(
          'SELECT COUNT(*) AS count FROM units u JOIN contracts c ON c.unit_id = u.id WHERE u.property_id = ?',
          [propertyId],
        );
        if ((history.first['count'] as int) > 0) {
          throw StateError(
            'لا يمكن تغيير مالك عقار له عقود محفوظة؛ سجّل نقل الملكية كإجراء مستقل حتى لا يتغير تاريخ العقود.',
          );
        }
      }
      final changed = await txn.update(
        'properties',
        {
          'name': name,
          'owner_id': ownerId,
          'city_id': property['city_id'],
          'property_type_id': property['property_type_id'],
          'cost_center_id': property['cost_center_id'],
          'address': property['address'],
          'deed_number': property['deed_number'],
        },
        where: 'id = ?',
        whereArgs: [propertyId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات العقار');
    });
  }

  Future<List<Map<String, dynamic>>> getProperties() async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    // Basic join could be done here, but let's fetch plain properties for now
    return await db.query('properties');
  }

  Future<List<Map<String, dynamic>>> getPropertiesForLeasing() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return db.query(
      'properties',
      columns: ['id', 'name'],
      orderBy: 'name COLLATE NOCASE, id',
    );
  }

  Future<int> insertUnit(Map<String, dynamic> unit) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final db = await instance.database;
    final propertyId = unit['property_id'];
    final number = (unit['unit_number'] as String?)?.trim() ?? '';
    final rent = unit['default_rent'] as num?;
    final rentPeriod = unit['default_rent_period'];
    if (propertyId is! int || propertyId <= 0 || number.isEmpty) {
      throw ArgumentError('العقار ورقم الوحدة حقول مطلوبة');
    }
    if (!RentPeriod.isValid(rentPeriod)) {
      throw ArgumentError('حدد دورية الإيجار الشهري أو السنوي');
    }
    if (rent != null &&
        (!rent.toDouble().isFinite ||
            rent < 0 ||
            !_hasCentPrecision(rent.toDouble()))) {
      throw ArgumentError(
        'الإيجار الافتراضي يجب أن يكون غير سالب وبمنزلتين عشريتين',
      );
    }

    return db.transaction((txn) async {
      final property = await txn.query(
        'properties',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [propertyId],
        limit: 1,
      );
      if (property.isEmpty) throw StateError('العقار المطلوب غير موجود');
      await _requireOptionalLookup(
        txn,
        'unit_types',
        unit['unit_type_id'],
        'نوع الوحدة',
      );
      final duplicate = await txn.query(
        'units',
        columns: ['id'],
        where: 'property_id = ? AND lower(trim(unit_number)) = lower(trim(?))',
        whereArgs: [propertyId, number],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw StateError('رقم الوحدة مستخدم في هذا العقار مسبقًا');
      }
      return txn.insert('units', {
        ...unit,
        'unit_number': number,
        'default_rent': rent?.toDouble(),
        'default_rent_period': rentPeriod,
      });
    });
  }

  Future<List<Map<String, dynamic>>> getUnitsForProperty(int propertyId) async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    return await db.rawQuery(
      '''
      SELECT u.*,
             CASE WHEN EXISTS (
               SELECT 1 FROM units duplicate
               WHERE duplicate.property_id = u.property_id
                 AND lower(trim(duplicate.unit_number)) =
                     lower(trim(u.unit_number))
                 AND duplicate.id != u.id
             ) THEN 1 ELSE 0 END AS has_duplicate_number
      FROM units u
      WHERE u.property_id = ?
      ORDER BY u.unit_number COLLATE NOCASE, u.id
      ''',
      [propertyId],
    );
  }

  Future<void> updateUnit(Map<String, dynamic> unit) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final db = await instance.database;
    final unitId = unit['id'];
    final number = (unit['unit_number'] as String?)?.trim() ?? '';
    final rent = unit['default_rent'] as num?;
    final rentPeriod = unit['default_rent_period'];
    if (unitId is! int || unitId <= 0 || number.isEmpty) {
      throw ArgumentError('معرف الوحدة ورقمها حقول مطلوبة');
    }
    if (!RentPeriod.isValid(rentPeriod)) {
      throw ArgumentError('حدد دورية الإيجار الشهري أو السنوي');
    }
    if (rent != null &&
        (!rent.toDouble().isFinite ||
            rent < 0 ||
            !_hasCentPrecision(rent.toDouble()))) {
      throw ArgumentError(
        'الإيجار الافتراضي يجب أن يكون غير سالب وبمنزلتين عشريتين',
      );
    }

    await db.transaction((txn) async {
      final existing = await txn.query(
        'units',
        columns: ['id', 'property_id', 'unit_number'],
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('الوحدة المطلوبة غير موجودة');
      await _requireOptionalLookup(
        txn,
        'unit_types',
        unit['unit_type_id'],
        'نوع الوحدة',
      );
      final previousNumber =
          existing.first['unit_number']?.toString().trim().toLowerCase() ?? '';
      if (previousNumber != number.toLowerCase()) {
        final duplicate = await txn.query(
          'units',
          columns: ['id'],
          where:
              'property_id = ? AND lower(trim(unit_number)) = lower(trim(?)) AND id != ?',
          whereArgs: [existing.first['property_id'], number, unitId],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw StateError('رقم الوحدة مستخدم في هذا العقار مسبقًا');
        }
      }
      final changed = await txn.update(
        'units',
        {
          'unit_number': number,
          'unit_type_id': unit['unit_type_id'],
          'floor': unit['floor'],
          'elec_meter': unit['elec_meter'],
          'water_meter': unit['water_meter'],
          'default_rent': rent?.toDouble(),
          'default_rent_period': rentPeriod,
        },
        where: 'id = ?',
        whereArgs: [unitId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات الوحدة');
    });
  }

  Future<void> deleteUnit(int id) async {
    PermissionRuntime.require('properties', AppPermissionAction.delete);
    final db = await instance.database;
    if (id <= 0) throw ArgumentError('معرف الوحدة غير صالح');
    await db.transaction((txn) async {
      final units = await txn.query(
        'units',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (units.isEmpty) throw StateError('الوحدة المطلوبة غير موجودة');
      final history = await txn.query(
        'contracts',
        columns: ['id'],
        where: 'unit_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (history.isNotEmpty) {
        throw StateError(
          'لا يمكن حذف وحدة مرتبطة بعقد؛ غيّر حالتها أو أرشفها للحفاظ على السجل التاريخي.',
        );
      }
      final deleted = await txn.delete(
        'units',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (deleted != 1) throw StateError('تعذر حذف الوحدة');
    });
  }

  // --- Leasing & Tenants Operations ---

  Future<void> insertTenantWithAccount(Map<String, dynamic> tenant) async {
    PermissionRuntime.require('leasing', AppPermissionAction.add);
    final name = (tenant['name'] as String?)?.trim() ?? '';
    final mobile = (tenant['mobile'] as String?)?.trim() ?? '';
    if (name.isEmpty || mobile.isEmpty) {
      throw ArgumentError('اسم المستأجر ورقم الجوال حقول مطلوبة');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(
        txn,
        'nationalities',
        tenant['nationality_id'],
        'الجنسية',
      );
      // 1. Find the parent account for Tenants (code: '1201')
      final parentResult = await txn.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1201'],
      );
      if (parentResult.isEmpty)
        throw Exception('حساب ذمم المستأجرين غير موجود (1201)');

      final parentId = parentResult.first['id'] as int;
      final newCode = await _nextAccountCodeTx(txn, parentId);

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': name,
        'parent_id': parentId,
        'account_type': 'Asset', // Since '1201' is an asset
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Tenant linked to the new account
      final tenantValues = Map<String, dynamic>.from(tenant)
        ..remove('id')
        ..remove('account_id')
        ..['name'] = name
        ..['mobile'] = mobile
        ..['account_id'] = accountId;
      await txn.insert('tenants', tenantValues);
    });
  }

  Future<List<Map<String, dynamic>>> getAllTenants() async {
    final db = await instance.database;
    if (PermissionRuntime.allows('leasing', AppPermissionAction.view)) {
      return db.query('tenants');
    }
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    return db.query(
      'tenants',
      columns: ['id', 'name', 'mobile', 'account_id'],
      orderBy: 'name COLLATE NOCASE',
    );
  }

  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    PermissionRuntime.require('leasing', AppPermissionAction.edit);
    final tenantId = tenant['id'];
    final name = (tenant['name'] as String?)?.trim() ?? '';
    final mobile = (tenant['mobile'] as String?)?.trim() ?? '';
    if (tenantId is! int || tenantId <= 0 || name.isEmpty || mobile.isEmpty) {
      throw ArgumentError('معرف المستأجر والاسم والجوال حقول مطلوبة');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(
        txn,
        'nationalities',
        tenant['nationality_id'],
        'الجنسية',
      );
      final existing = await txn.query(
        'tenants',
        columns: ['id', 'account_id'],
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('المستأجر المطلوب غير موجود');

      final accountId = existing.first['account_id'] as int?;
      final values = <String, Object?>{
        'name': name,
        'mobile': mobile,
        'identity_number': tenant['identity_number'],
        'identity_issue_date': tenant['identity_issue_date'],
        'identity_source': tenant['identity_source'],
        'profession': tenant['profession'],
        'nationality_id': tenant['nationality_id'],
      };
      final changed = await txn.update(
        'tenants',
        values,
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات المستأجر');

      if (accountId != null) {
        final changedAccount = await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
        if (changedAccount != 1) {
          throw StateError('الحساب المحاسبي المرتبط بالمستأجر غير موجود');
        }
      }
    });
  }

  Future<Map<String, dynamic>> _captureContractPartySnapshot(
    DatabaseExecutor txn,
    Map<String, dynamic> tenant,
    Map<String, dynamic> unit,
  ) async {
    final propertyRows = await txn.query(
      'properties',
      where: 'id = ?',
      whereArgs: [unit['property_id']],
      limit: 1,
    );
    if (propertyRows.isEmpty)
      throw StateError('العقار المرتبط بالوحدة غير موجود');
    final property = propertyRows.first;
    final ownerRows = await txn.query(
      'owners',
      where: 'id = ?',
      whereArgs: [property['owner_id']],
      limit: 1,
    );
    if (ownerRows.isEmpty) throw StateError('مالك العقار المرتبط غير موجود');
    final owner = ownerRows.first;

    Future<String?> lookupName(String table, Object? id) async {
      if (id == null) return null;
      final rows = await txn.query(
        table,
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first['name']?.toString();
    }

    final tenantSnapshot = <String, dynamic>{
      for (final field in [
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
      ])
        field: tenant[field],
      'nationality_name': await lookupName(
        'nationalities',
        tenant['nationality_id'],
      ),
    };

    return {
      'owner': {
        for (final field in [
          'name',
          'identity_number',
          'identity_issue_date',
          'identity_source',
        ])
          field: owner[field],
      },
      'tenant': tenantSnapshot,
      'property': {'name': property['name'], 'address': property['address']},
      'unit': {'unit_number': unit['unit_number']},
      'city_name': await lookupName('cities', property['city_id']),
      'unit_type_name': await lookupName('unit_types', unit['unit_type_id']),
      'property_type_name': await lookupName(
        'property_types',
        property['property_type_id'],
      ),
    };
  }

  Future<int> insertContractWithInstallments(
    Map<String, dynamic> contract,
    List<Map<String, dynamic>> installments,
  ) async {
    PermissionRuntime.require('leasing', AppPermissionAction.add);
    final rent = (contract['rent_amount'] as num?)?.toDouble() ?? 0;
    final startDate = DateTime.tryParse(
      contract['start_date']?.toString() ?? '',
    );
    final endDate = DateTime.tryParse(contract['end_date']?.toString() ?? '');
    if (rent <= 0 ||
        !_hasCentPrecision(rent) ||
        startDate == null ||
        endDate == null ||
        startDate.isAfter(endDate)) {
      throw ArgumentError('بيانات العقد أو مدة الإيجار غير صحيحة');
    }
    if (installments.isEmpty)
      throw ArgumentError('يجب إضافة قسط واحد على الأقل');
    var installmentCents = 0;
    for (final installment in installments) {
      final amount = (installment['amount'] as num?)?.toDouble() ?? 0;
      final dueDate = DateTime.tryParse(
        installment['due_date']?.toString() ?? '',
      );
      if (amount <= 0 ||
          !_hasCentPrecision(amount) ||
          dueDate == null ||
          dueDate.isBefore(startDate) ||
          dueDate.isAfter(endDate)) {
        throw ArgumentError(
          'مبلغ أو تاريخ أحد الأقساط غير صحيح أو خارج مدة العقد',
        );
      }
      installmentCents += (amount * 100).round();
    }
    if (installmentCents != (rent * 100).round()) {
      throw ArgumentError('مجموع الأقساط لا يساوي قيمة العقد');
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantId = contract['tenant_id'];
      final unitId = contract['unit_id'];
      if (tenantId is! int || tenantId <= 0) {
        throw ArgumentError('المستأجر المحدد غير موجود');
      }
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty) {
        throw ArgumentError('المستأجر المحدد غير موجود');
      }
      if (unitId is! int || unitId <= 0) {
        throw ArgumentError('الوحدة المحددة غير موجودة');
      }
      final unitRows = await txn.query(
        'units',
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (unitRows.isEmpty || unitRows.first['status'] != 'شاغرة') {
        throw StateError('الوحدة لم تعد شاغرة؛ حدّث القائمة واختر وحدة أخرى');
      }
      final unitRentPeriod = unitRows.first['default_rent_period'];
      final unitRent = unitRows.first['default_rent'] as num?;
      if (!RentPeriod.isValid(unitRentPeriod)) {
        throw StateError(
          'دورية إيجار الوحدة غير محددة؛ حدّث بيانات الوحدة قبل إنشاء العقد',
        );
      }
      if (unitRent != null &&
          (!unitRent.toDouble().isFinite ||
              unitRent < 0 ||
              !_hasCentPrecision(unitRent.toDouble()))) {
        throw StateError(
          'سعر الوحدة الافتراضي غير صالح؛ حدّث بيانات الوحدة قبل إنشاء العقد',
        );
      }
      final activeContracts = await txn.query(
        'contracts',
        columns: ['id'],
        where: "unit_id = ? AND status = 'Active'",
        whereArgs: [unitId],
        limit: 1,
      );
      if (activeContracts.isNotEmpty) throw StateError('للوحدة عقد نشط بالفعل');

      final partySnapshot = await _captureContractPartySnapshot(
        txn,
        tenantRows.first,
        unitRows.first,
      );

      final contractId = await txn.insert('contracts', {
        ...contract,
        'unit_rent_amount': unitRent?.toDouble(),
        'unit_rent_period': unitRentPeriod,
        'party_snapshot': jsonEncode(partySnapshot),
      });
      for (final item in installments) {
        final installment = Map<String, dynamic>.from(item)
          ..['contract_id'] = contractId;
        await txn.insert('contract_installments', installment);
      }
      final updated = await txn.update(
        'units',
        {'status': 'مؤجرة'},
        where: "id = ? AND status = 'شاغرة'",
        whereArgs: [unitId],
      );
      if (updated != 1) throw StateError('تعذر اعتماد الوحدة؛ أُلغيت المعاملة');
      return contractId;
    });
  }

  Future<List<Map<String, dynamic>>> getVacantUnits() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('units', where: 'status = ?', whereArgs: ['شاغرة']);
  }

  Future<List<Map<String, dynamic>>> getAllContracts() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('contracts');
  }

  Future<List<Map<String, dynamic>>>
  getActiveTenantContractsForFinancial() async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.query(
      'contracts',
      columns: ['id', 'tenant_id', 'status'],
      where: "status = 'Active'",
    );
  }

  Future<List<Map<String, dynamic>>> getInstallmentsForContract(
    int contractId,
  ) async {
    if (!PermissionRuntime.allows('leasing', AppPermissionAction.view) &&
        !PermissionRuntime.allows(
          'tenant_financial',
          AppPermissionAction.view,
        )) {
      throw StateError('لا تملك صلاحية عرض بيانات أقساط التأجير');
    }
    final db = await instance.database;
    return await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    );
  }

  Future<List<Map<String, dynamic>>> getUnbilledInstallmentsForContract(
    int contractId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT ci.*
      FROM contract_installments ci
      JOIN contracts c ON c.id = ci.contract_id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      WHERE ci.contract_id = ? AND c.status = 'Active' AND ti.id IS NULL
      ORDER BY ci.due_date, ci.id
      ''',
      [contractId],
    );
  }

  Future<List<Map<String, dynamic>>> getUnbilledInstallmentsForTenant(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT ci.*
      FROM contract_installments ci
      JOIN contracts c ON c.id = ci.contract_id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      WHERE c.tenant_id = ?
        AND c.status = 'Active'
        AND ci.status != 'Paid'
        AND ti.id IS NULL
      ORDER BY ci.due_date, ci.id
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getOpenTaxInvoicesForTenant(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        ti.id,
        ti.contract_id,
        ti.installment_id,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        ci.due_date,
        ci.amount AS installment_amount,
        ci.paid_amount AS installment_paid_amount,
        COALESCE(SUM(via.amount), 0) AS paid_amount,
        ROUND(MAX(ti.total_amount - COALESCE(SUM(via.amount), 0), 0), 2)
          AS remaining_amount
      FROM tax_invoices ti
      JOIN contracts c ON c.id = ti.contract_id
      JOIN contract_installments ci ON ci.id = ti.installment_id
      LEFT JOIN voucher_invoice_allocations via ON via.invoice_id = ti.id
      WHERE c.tenant_id = ? AND c.status = 'Active'
      GROUP BY ti.id
      HAVING ROUND(MAX(ti.total_amount - COALESCE(SUM(via.amount), 0), 0), 2) > 0
      ORDER BY ci.due_date, ti.invoice_date, ti.id
      ''',
      [tenantId],
    );
  }

  // --- Tenant Financial Operations ---

  Future<int> insertTenantReceiptVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required List<Map<String, dynamic>> installmentsToUpdate,
    int? invoiceId,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (amount <= 0 ||
        !_hasCentPrecision(amount) ||
        DateTime.tryParse(voucherDate) == null ||
        (invoiceId == null && installmentsToUpdate.isEmpty) ||
        (invoiceId != null && installmentsToUpdate.isNotEmpty)) {
      throw ArgumentError('المبلغ والأقساط المطلوب تسديدها يجب أن تكون صحيحة');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      final tenantAccountId = tenantRows.first['account_id'] as int;
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }

      var allocatedCents = 0;
      final verifiedUpdates = <Map<String, dynamic>>[];
      if (invoiceId != null) {
        final invoices = await txn.rawQuery(
          '''
          SELECT
            ti.id,
            ti.total_amount,
            ti.net_amount,
            ti.tax_amount,
            ti.installment_id,
            c.tenant_id,
            ci.amount AS installment_amount,
            ci.paid_amount AS installment_paid_amount
          FROM tax_invoices ti
          JOIN contracts c ON c.id = ti.contract_id
          JOIN contract_installments ci ON ci.id = ti.installment_id
          WHERE ti.id = ? AND c.status = 'Active'
          LIMIT 1
          ''',
          [invoiceId],
        );
        if (invoices.isEmpty || invoices.first['tenant_id'] != tenantId) {
          throw StateError(
            'الفاتورة المحددة لا تخص هذا المستأجر أو عقدها غير نشط',
          );
        }
        final invoice = invoices.first;
        final invoiceTotal = (invoice['total_amount'] as num).toDouble();
        final invoiceNet = (invoice['net_amount'] as num).toDouble();
        final invoiceTax = (invoice['tax_amount'] as num).toDouble();
        if (!_hasCentPrecision(invoiceTotal) ||
            !_hasCentPrecision(invoiceNet) ||
            !_hasCentPrecision(invoiceTax)) {
          throw StateError('بيانات الفاتورة غير متسقة؛ لا يمكن تحصيلها');
        }
        final invoiceTotalCents = InternalTax.toMinorUnits(invoiceTotal);
        if (invoiceTotalCents !=
            InternalTax.toMinorUnits(invoiceNet + invoiceTax)) {
          throw StateError('بيانات الفاتورة غير متسقة؛ لا يمكن تحصيلها');
        }
        final paidRows = await txn.rawQuery(
          '''
          SELECT COALESCE(SUM(amount), 0) AS paid_amount
          FROM voucher_invoice_allocations
          WHERE invoice_id = ?
          ''',
          [invoiceId],
        );
        final invoicePaid = (paidRows.first['paid_amount'] as num).toDouble();
        if (!_hasCentPrecision(invoicePaid)) {
          throw StateError('تخصيصات الفاتورة السابقة غير دقيقة ماليًا');
        }
        final remainingInvoiceCents =
            invoiceTotalCents - InternalTax.toMinorUnits(invoicePaid);
        final receiptCents = (amount * 100).round();
        if (remainingInvoiceCents <= 0 ||
            receiptCents > remainingInvoiceCents) {
          throw StateError('المبلغ يتجاوز المتبقي على الفاتورة؛ أعد تحميلها');
        }

        final installmentTotal = (invoice['installment_amount'] as num)
            .toDouble();
        final oldPaid =
            (invoice['installment_paid_amount'] as num?)?.toDouble() ?? 0;
        if (!_hasCentPrecision(installmentTotal) ||
            !_hasCentPrecision(oldPaid) ||
            oldPaid < 0 ||
            oldPaid > installmentTotal ||
            InternalTax.toMinorUnits(installmentTotal) !=
                InternalTax.toMinorUnits(invoiceNet)) {
          throw StateError('مبلغ القسط أو تحصيله غير متسق مع الفاتورة');
        }
        final installmentRemainingCents =
            InternalTax.toMinorUnits(installmentTotal) -
            InternalTax.toMinorUnits(oldPaid);
        final principalCents = receiptCents < installmentRemainingCents
            ? receiptCents
            : installmentRemainingCents;
        if (principalCents > 0) {
          final newPaidCents =
              InternalTax.toMinorUnits(oldPaid) + principalCents;
          final newPaid = newPaidCents / 100;
          final status =
              newPaidCents >= InternalTax.toMinorUnits(installmentTotal)
              ? 'Paid'
              : 'Partially Paid';
          verifiedUpdates.add({
            'id': invoice['installment_id'],
            'old_paid': oldPaid,
            'paid_amount': newPaid,
            'status': status,
            'allocated_amount': principalCents / 100,
          });
        }
        allocatedCents = receiptCents;
      } else {
        for (final requested in installmentsToUpdate) {
          final rows = await txn.rawQuery(
            '''
            SELECT ci.* FROM contract_installments ci
            JOIN contracts c ON c.id = ci.contract_id
            WHERE ci.id = ? AND c.tenant_id = ? AND c.status = 'Active'
            ''',
            [requested['id'], tenantId],
          );
          if (rows.isEmpty)
            throw StateError(
              'القسط المحدد لا يتبع هذا المستأجر أو أن عقده غير نشط',
            );
          final current = rows.first;
          final linkedInvoices = await txn.query(
            'tax_invoices',
            columns: ['id'],
            where: 'installment_id = ?',
            whereArgs: [requested['id']],
            limit: 1,
          );
          if (linkedInvoices.isNotEmpty) {
            throw StateError(
              'القسط مرتبط بفاتورة؛ سجل القبض من وضع سداد الفاتورة',
            );
          }
          final total = (current['amount'] as num).toDouble();
          final oldPaid = (current['paid_amount'] as num?)?.toDouble() ?? 0;
          final newPaid = (requested['paid_amount'] as num?)?.toDouble();
          if (newPaid == null ||
              !_hasCentPrecision(newPaid) ||
              !_hasCentPrecision(oldPaid) ||
              newPaid <= oldPaid ||
              newPaid > total + 0.001) {
            throw StateError(
              'تغير رصيد القسط أو أن المبلغ يتجاوز المستحق؛ أعد تحميل الأقساط',
            );
          }
          final status = newPaid >= total - 0.001 ? 'Paid' : 'Partially Paid';
          if (requested['status'] != status)
            throw ArgumentError('حالة القسط لا تطابق المبلغ المدفوع');
          final allocatedAmount = newPaid - oldPaid;
          allocatedCents += (allocatedAmount * 100).round();
          verifiedUpdates.add({
            'id': requested['id'],
            'old_paid': oldPaid,
            'paid_amount': newPaid,
            'status': status,
            'allocated_amount': allocatedAmount,
          });
        }
      }
      if (allocatedCents != (amount * 100).round()) {
        throw ArgumentError('مجموع تخصيص الدفعة لا يساوي مبلغ السند');
      }

      final journalId = await txn.insert('journal_entries', {
        'entry_date': voucherDate,
        'description': invoiceId == null
            ? 'سند قبض مستأجر'
            : 'سداد فاتورة داخلية رقم $invoiceId',
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': amount,
        'credit': 0.0,
        'description': invoiceId == null
            ? 'تحصيل دفعة مستأجر'
            : 'سداد فاتورة داخلية رقم $invoiceId',
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': 0.0,
        'credit': amount,
        'description': invoiceId == null
            ? 'تحصيل دفعة مستأجر'
            : 'سداد فاتورة داخلية رقم $invoiceId',
      });
      await _updateBalanceTx(txn, cashAccountId, amount, 0.0);
      await _updateBalanceTx(txn, tenantAccountId, 0.0, amount);

      final voucherId = await txn.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'party_name': tenantRows.first['name'],
        'journal_entry_id': journalId,
        'description': invoiceId == null
            ? 'تحصيل دفعة إيجار'
            : 'سداد فاتورة رقم $invoiceId',
      });
      if (invoiceId != null) {
        await txn.insert('voucher_invoice_allocations', {
          'voucher_id': voucherId,
          'invoice_id': invoiceId,
          'amount': amount,
        });
      }
      for (final installment in verifiedUpdates) {
        await txn.insert('voucher_installment_allocations', {
          'voucher_id': voucherId,
          'installment_id': installment['id'],
          'amount': installment['allocated_amount'],
        });
      }
      for (final installment in verifiedUpdates) {
        final changed = await txn.update(
          'contract_installments',
          {
            'paid_amount': installment['paid_amount'],
            'status': installment['status'],
          },
          where: 'id = ? AND paid_amount = ?',
          whereArgs: [installment['id'], installment['old_paid']],
        );
        if (changed != 1)
          throw StateError('تم تحديث القسط من عملية أخرى؛ أُلغيت المعاملة');
      }
      return voucherId;
    });
  }

  Future<int> insertTenantPaymentVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required int offsetAccountId,
    required String description,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (amount <= 0 ||
        !_hasCentPrecision(amount) ||
        DateTime.tryParse(voucherDate) == null ||
        description.trim().isEmpty) {
      throw ArgumentError('المبلغ أو التاريخ أو البيان غير صحيح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      final tenantAccountId = tenantRows.first['account_id'] as int;
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      final offsetAccount = await _requireLeafAccountTx(txn, offsetAccountId);
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }
      if (offsetAccountId == cashAccountId ||
          ![
            'Liability',
            'Expense',
            'Revenue',
          ].contains(offsetAccount['account_type'])) {
        throw ArgumentError('الحساب المقابل غير صالح');
      }

      final journalId = await txn.insert('journal_entries', {
        'entry_date': voucherDate,
        'description': description,
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': offsetAccountId,
        'debit': amount,
        'credit': 0.0,
        'description': description,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': 0.0,
        'credit': amount,
        'description': description,
      });
      await _updateBalanceTx(txn, offsetAccountId, amount, 0.0);
      await _updateBalanceTx(txn, cashAccountId, 0.0, amount);

      return txn.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'party_name': tenantRows.first['name'],
        'journal_entry_id': journalId,
        'description': description,
      });
    });
  }

  Future<List<Map<String, dynamic>>> getVoucherHistory({
    String? voucherType,
  }) async {
    PermissionRuntime.require('voucher_history', AppPermissionAction.view);
    final db = await instance.database;
    final where = voucherType == null ? '' : 'WHERE v.voucher_type = ?';
    final args = voucherType == null ? <Object?>[] : <Object?>[voucherType];
    return db.rawQuery('''
      SELECT
        v.id,
        v.voucher_type,
        v.voucher_date,
        v.amount,
        v.tenant_id,
        COALESCE(NULLIF(TRIM(v.party_name), ''), t.name, v.description, '') AS party_name,
        v.description,
        v.journal_entry_id
      FROM vouchers v
      LEFT JOIN tenants t ON t.id = v.tenant_id
      $where
      ORDER BY v.voucher_date DESC, v.id DESC
      ''', args);
  }

  Future<Map<String, dynamic>?> getVoucherDetails(int voucherId) async {
    PermissionRuntime.require('voucher_history', AppPermissionAction.view);
    final db = await instance.database;
    final headers = await db.rawQuery(
      '''
      SELECT
        v.id,
        v.voucher_type,
        v.voucher_date,
        v.amount,
        v.tenant_id,
        COALESCE(NULLIF(TRIM(v.party_name), ''), t.name, v.description, '') AS party_name,
        t.name AS current_tenant_name,
        v.description,
        v.journal_entry_id
      FROM vouchers v
      LEFT JOIN tenants t ON t.id = v.tenant_id
      WHERE v.id = ?
      LIMIT 1
      ''',
      [voucherId],
    );
    if (headers.isEmpty) return null;

    final journalEntryId = headers.first['journal_entry_id'] as int?;
    final lines = journalEntryId == null
        ? <Map<String, Object?>>[]
        : await db.rawQuery(
            '''
            SELECT
              jl.id,
              jl.account_id,
              a.code AS account_code,
              a.name AS account_name,
              jl.debit,
              jl.credit,
              jl.description AS line_description,
              jl.cost_center_id,
              cc.name AS cost_center_name
            FROM journal_lines jl
            JOIN accounts a ON a.id = jl.account_id
            LEFT JOIN cost_centers cc ON cc.id = jl.cost_center_id
            WHERE jl.journal_entry_id = ?
            ORDER BY jl.id
            ''',
            [journalEntryId],
          );
    final installments = await db.rawQuery(
      '''
      SELECT
        via.installment_id,
        via.amount AS allocated_amount,
        ci.contract_id,
        ci.amount AS installment_amount,
        ci.paid_amount,
        ci.due_date,
        ci.status,
        p.name AS property_name,
        u.unit_number
      FROM voucher_installment_allocations via
      JOIN contract_installments ci ON ci.id = via.installment_id
      JOIN contracts c ON c.id = ci.contract_id
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE via.voucher_id = ?
      ORDER BY ci.due_date, ci.id
      ''',
      [voucherId],
    );
    final invoices = await db.rawQuery(
      '''
      SELECT
        via.invoice_id,
        via.amount AS allocated_amount,
        ti.contract_id,
        ti.installment_id,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        ci.due_date
      FROM voucher_invoice_allocations via
      JOIN tax_invoices ti ON ti.id = via.invoice_id
      LEFT JOIN contract_installments ci ON ci.id = ti.installment_id
      WHERE via.voucher_id = ?
      ORDER BY ti.invoice_date, ti.id
      ''',
      [voucherId],
    );
    return {
      'voucher': headers.first,
      'journal_lines': lines,
      'installments': installments,
      'invoices': invoices,
    };
  }

  Future<int> insertTaxInvoice({
    required int contractId,
    required int tenantId,
    required int installmentId,
    required String invoiceDate,
    required double netAmount,
    required double taxAmount,
    required int revenueAccountId,
    required int? taxAccountId,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (netAmount <= 0 ||
        !_hasCentPrecision(netAmount) ||
        !_hasCentPrecision(taxAmount) ||
        taxAmount < 0 ||
        DateTime.tryParse(invoiceDate) == null) {
      throw ArgumentError('مبالغ أو تاريخ الفاتورة غير صحيح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final contractRows = await txn.query(
        'contracts',
        where: "id = ? AND tenant_id = ? AND status = 'Active'",
        whereArgs: [contractId, tenantId],
      );
      if (contractRows.isEmpty) {
        throw StateError('العقد المحدد لا يتبع المستأجر المختار');
      }
      final installmentRows = await txn.rawQuery(
        '''
        SELECT ci.*
        FROM contract_installments ci
        JOIN contracts c ON c.id = ci.contract_id
        WHERE ci.id = ? AND c.id = ? AND c.tenant_id = ? AND c.status = 'Active'
        LIMIT 1
        ''',
        [installmentId, contractId, tenantId],
      );
      if (installmentRows.isEmpty) {
        throw StateError('القسط المحدد لا يتبع العقد أو المستأجر المختار');
      }
      final installment = installmentRows.first;
      final scheduledNet = (installment['amount'] as num).toDouble();
      final paidBeforeInvoice =
          (installment['paid_amount'] as num?)?.toDouble() ?? 0.0;
      if (!_hasCentPrecision(scheduledNet) ||
          !_hasCentPrecision(paidBeforeInvoice) ||
          paidBeforeInvoice < 0 ||
          paidBeforeInvoice > scheduledNet ||
          InternalTax.toMinorUnits(netAmount) !=
              InternalTax.toMinorUnits(scheduledNet)) {
        throw StateError('صافي الفاتورة يجب أن يطابق مبلغ القسط المسجل');
      }
      final priorAllocations = await txn.rawQuery(
        '''
        SELECT via.voucher_id, via.amount, v.tenant_id, v.voucher_type
        FROM voucher_installment_allocations via
        JOIN vouchers v ON v.id = via.voucher_id
        WHERE via.installment_id = ?
        ORDER BY via.id
        ''',
        [installmentId],
      );
      var priorAllocatedCents = 0;
      for (final allocation in priorAllocations) {
        final amount = (allocation['amount'] as num).toDouble();
        if (!_hasCentPrecision(amount) ||
            (allocation['tenant_id'] as num?)?.toInt() != tenantId ||
            allocation['voucher_type'] != 'قبض مستأجر') {
          throw StateError(
            'توجد تخصيصات قبض غير متسقة للقسط؛ راجعها يدويًا قبل إصدار الفاتورة',
          );
        }
        priorAllocatedCents += InternalTax.toMinorUnits(amount);
      }
      if (priorAllocatedCents != InternalTax.toMinorUnits(paidBeforeInvoice)) {
        throw StateError(
          'لا يمكن مطابقة المدفوع السابق مع سندات قبض القسط؛ راجع السجل يدويًا قبل إصدار الفاتورة',
        );
      }
      final companyRows = await txn.query(
        'company_info',
        columns: ['tax_rate'],
        limit: 1,
      );
      final configuredTaxRate = companyRows.isEmpty
          ? 0.0
          : (companyRows.first['tax_rate'] as num?)?.toDouble() ?? 0.0;
      if (!InternalTax.isValidRate(configuredTaxRate)) {
        throw StateError(
          'نسبة الضريبة المحفوظة غير صالحة؛ راجع إعدادات المنشأة',
        );
      }
      final calculatedTaxAmount = InternalTax.calculate(
        netAmount,
        configuredTaxRate,
      );
      if (InternalTax.toMinorUnits(calculatedTaxAmount) !=
          InternalTax.toMinorUnits(taxAmount)) {
        throw ArgumentError(
          'مبلغ الضريبة لا يطابق نسبة المنشأة الحالية؛ أعد تحميل إعدادات الفاتورة',
        );
      }
      if (calculatedTaxAmount > 0 && taxAccountId == null) {
        throw ArgumentError('اختر حساب ضريبة تفصيليًا قبل إصدار الفاتورة');
      }
      final duplicates = await txn.query(
        'tax_invoices',
        where: 'installment_id = ?',
        whereArgs: [installmentId],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        throw StateError('صدرت فاتورة لهذا القسط مسبقًا');
      }
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      final tenantAccountId = tenantRows.first['account_id'] as int;
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      await _requireLeafAccountTx(
        txn,
        revenueAccountId,
        expectedType: 'Revenue',
      );
      if (calculatedTaxAmount > 0) {
        await _requireLeafAccountTx(
          txn,
          taxAccountId!,
          expectedType: 'Liability',
        );
      }

      final grossAmount = netAmount + calculatedTaxAmount;
      final journalId = await txn.insert('journal_entries', {
        'entry_date': invoiceDate,
        'description': 'إثبات فاتورة ضريبية إيجار',
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': grossAmount,
        'credit': 0.0,
        'description': 'استحقاق فاتورة إيجار',
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': revenueAccountId,
        'debit': 0.0,
        'credit': netAmount,
        'description': 'إيراد إيجار',
      });
      if (calculatedTaxAmount > 0) {
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': taxAccountId!,
          'debit': 0.0,
          'credit': calculatedTaxAmount,
          'description': 'ضريبة قيمة مضافة',
        });
      }
      await _updateBalanceTx(txn, tenantAccountId, grossAmount, 0.0);
      await _updateBalanceTx(txn, revenueAccountId, 0.0, netAmount);
      if (calculatedTaxAmount > 0) {
        await _updateBalanceTx(txn, taxAccountId!, 0.0, calculatedTaxAmount);
      }

      final invoiceId = await txn.insert('tax_invoices', {
        'contract_id': contractId,
        'installment_id': installmentId,
        'journal_entry_id': journalId,
        'invoice_date': invoiceDate,
        'net_amount': netAmount,
        'total_amount': grossAmount,
        'tax_amount': calculatedTaxAmount,
        'tax_rate': configuredTaxRate,
      });
      for (final allocation in priorAllocations) {
        await txn.insert('voucher_invoice_allocations', {
          'voucher_id': allocation['voucher_id'],
          'invoice_id': invoiceId,
          'amount': allocation['amount'],
        });
      }
      return invoiceId;
    });
  }

  Future<void> cancelContract(int contractId) async {
    PermissionRuntime.require('leasing', AppPermissionAction.edit);
    final db = await instance.database;
    await db.transaction((txn) async {
      final contractResult = await txn.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
        limit: 1,
      );
      if (contractResult.isEmpty) throw StateError('العقد غير موجود');
      if (contractResult.first['status'] == 'Cancelled') return;

      // Never erase a financial schedule or leave an invoice without reversal.
      final installments = await txn.query(
        'contract_installments',
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );
      bool hasPaid = installments.any(
        (inst) => (inst['paid_amount'] as num) > 0,
      );
      if (hasPaid) {
        throw StateError(
          'لا يمكن إلغاء العقد بشكل مباشر. يوجد دفعات مسددة، يتطلب عمل تسوية أو إشعار دائن.',
        );
      }
      final invoices = await txn.query(
        'tax_invoices',
        columns: ['id'],
        where: 'contract_id = ?',
        whereArgs: [contractId],
        limit: 1,
      );
      if (invoices.isNotEmpty) {
        throw StateError(
          'لا يمكن إلغاء العقد بعد إصدار فاتورة؛ أصدر إشعاراً دائناً أو تسوية موثقة أولاً.',
        );
      }
      final unitId = contractResult.first['unit_id'] as int;

      // Retain the original schedule for audit and mark it cancelled.
      await txn.update(
        'contract_installments',
        {'status': 'Cancelled'},
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );

      await txn.update(
        'contracts',
        {'status': 'Cancelled'},
        where: 'id = ?',
        whereArgs: [contractId],
      );

      final otherActiveContracts = await txn.rawQuery(
        "SELECT COUNT(*) AS count FROM contracts WHERE unit_id = ? AND status = 'Active'",
        [unitId],
      );
      if ((otherActiveContracts.first['count'] as int) == 0) {
        await txn.update(
          'units',
          {'status': 'شاغرة'},
          where: 'id = ?',
          whereArgs: [unitId],
        );
      }
    });
  }

  // --- Reports & Alerts Queries ---
  // --- Reports & Alerts Queries ---

  Future<Map<String, dynamic>> getDashboardSummary() async {
    PermissionRuntime.require('dashboard', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM properties) AS properties_count,
        (SELECT COUNT(*) FROM units) AS units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'مؤجرة') AS rented_units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'شاغرة') AS vacant_units_count,
        (SELECT COUNT(*) FROM tenants) AS tenants_count,
        (SELECT COUNT(*) FROM contracts WHERE status = 'Active') AS active_contracts_count,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NOT NULL
            THEN MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0)
            ELSE MAX(ci.amount - ci.paid_amount, 0)
          END
        ), 0)
          FROM contract_installments ci
          JOIN contracts c ON c.id = ci.contract_id
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          LEFT JOIN (
            SELECT invoice_id, SUM(amount) AS paid_amount
            FROM voucher_invoice_allocations GROUP BY invoice_id
          ) vip ON vip.invoice_id = ti.id
          WHERE c.status = 'Active') AS outstanding_amount
    ''');
    return rows.first;
  }

  Future<double> getAccountOpeningBalance(
    int accountId,
    String startDate,
  ) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    final accounts = await db.query(
      'accounts',
      columns: ['account_type'],
      where: 'id = ?',
      whereArgs: [accountId],
    );
    if (accounts.isEmpty) throw StateError('الحساب غير موجود');
    final totals = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(jl.debit), 0) AS debit_total,
             COALESCE(SUM(jl.credit), 0) AS credit_total
      FROM journal_lines jl
      JOIN journal_entries je ON jl.journal_entry_id = je.id
      WHERE jl.account_id = ? AND je.entry_date < ? AND je.is_posted = 1
    ''',
      [accountId, startDate],
    );
    final debit = (totals.first['debit_total'] as num).toDouble();
    final credit = (totals.first['credit_total'] as num).toDouble();
    final type = accounts.first['account_type'];
    return (type == 'Liability' || type == 'Revenue' || type == 'Equity')
        ? credit - debit
        : debit - credit;
  }

  Future<List<Map<String, dynamic>>> getAccountStatement(
    int accountId,
    String startDate,
    String endDate,
  ) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return await db.rawQuery(
      '''
      SELECT
        je.entry_date as date,
        je.id as voucher_no,
        jl.description as description,
        jl.debit as debit,
        jl.credit as credit
      FROM journal_lines jl
      JOIN journal_entries je ON jl.journal_entry_id = je.id
      WHERE jl.account_id = ? AND je.entry_date >= ? AND je.entry_date <= ? AND je.is_posted = 1
      ORDER BY je.entry_date ASC, je.id ASC, jl.id ASC
    ''',
      [accountId, startDate, endDate],
    );
  }

  Future<List<Map<String, dynamic>>> getUnitOccupancyStats() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT
        p.name as property_name,
        COUNT(u.id) as total_units,
        SUM(CASE WHEN u.status = 'مؤجرة' THEN 1 ELSE 0 END) as rented_units,
        SUM(CASE WHEN u.status = 'شاغرة' THEN 1 ELSE 0 END) as vacant_units
      FROM properties p
      LEFT JOIN units u ON p.id = u.property_id
      GROUP BY p.id, p.name
    ''');
  }

  Future<List<Map<String, dynamic>>> searchTenantsAndContracts(
    String query,
  ) async {
    _requireAnyView(['leasing', 'reports']);
    final db = await instance.database;
    final searchTerm = '%$query%';
    return await db.rawQuery(
      '''
      SELECT
        t.name as tenant_name,
        t.mobile as mobile,
        c.id as contract_id,
        p.name as property_name,
        u.unit_number as unit_number,
        c.status as contract_status,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NULL THEN ci.amount ELSE ti.total_amount END
        ), 0)
          FROM contract_installments ci
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          WHERE ci.contract_id = c.id) as total_amount,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NULL THEN ci.paid_amount
            ELSE COALESCE((
              SELECT SUM(via.amount) FROM voucher_invoice_allocations via
              WHERE via.invoice_id = ti.id
            ), 0)
          END
        ), 0)
          FROM contract_installments ci
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          WHERE ci.contract_id = c.id) as paid_amount
      FROM tenants t
      LEFT JOIN contracts c ON t.id = c.tenant_id
      LEFT JOIN units u ON c.unit_id = u.id
      LEFT JOIN properties p ON u.property_id = p.id
      WHERE t.name LIKE ? OR t.mobile LIKE ? OR u.unit_number LIKE ?
    ''',
      [searchTerm, searchTerm, searchTerm],
    );
  }

  Future<List<Map<String, dynamic>>> getDueInstallments(int days) async {
    _requireAnyView(['reports', 'system_services']);
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);

    return await db.rawQuery(
      '''
      SELECT
        ci.id as installment_id,
        ci.due_date,
        ci.amount AS installment_amount,
        COALESCE(ti.total_amount, ci.amount) AS amount,
        CASE WHEN ti.id IS NULL THEN ci.paid_amount
          ELSE COALESCE(vip.paid_amount, 0)
        END AS paid_amount,
        CASE WHEN ti.id IS NULL
          THEN ROUND(MAX(ci.amount - ci.paid_amount, 0), 2)
          ELSE ROUND(MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0), 2)
        END AS remaining_amount,
        ti.id AS invoice_id,
        ci.status,
        t.name as tenant_name,
        t.id as tenant_id
      FROM contract_installments ci
      JOIN contracts c ON ci.contract_id = c.id
      JOIN tenants t ON c.tenant_id = t.id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      LEFT JOIN (
        SELECT invoice_id, SUM(amount) AS paid_amount
        FROM voucher_invoice_allocations GROUP BY invoice_id
      ) vip ON vip.invoice_id = ti.id
      WHERE c.status = 'Active'
        AND (CASE WHEN ti.id IS NULL
          THEN MAX(ci.amount - ci.paid_amount, 0)
          ELSE MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0)
        END) > 0
        AND ci.due_date <= ?
      ORDER BY ci.due_date ASC
    ''',
      [targetDateStr],
    );
  }

  Future<List<Map<String, dynamic>>> getExpiringContracts(int days) async {
    _requireAnyView(['reports', 'system_services']);
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);

    return await db.rawQuery(
      '''
      SELECT
        c.id as contract_id,
        c.end_date,
        t.name as tenant_name,
        p.name as property_name,
        u.unit_number
      FROM contracts c
      JOIN tenants t ON c.tenant_id = t.id
      JOIN units u ON c.unit_id = u.id
      JOIN properties p ON u.property_id = p.id
      WHERE c.status = 'Active' AND c.end_date >= ? AND c.end_date <= ?
      ORDER BY c.end_date ASC
    ''',
      [todayStr, targetDateStr],
    );
  }

  // --- SMS Operations ---

  Future<Map<String, dynamic>?> getSmsSettingsForEditing() async {
    PermissionRuntime.require('sms', AppPermissionAction.edit);
    final db = await instance.database;
    final result = await db.query('sms_settings');
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<Map<String, dynamic>?> getSmsSettingsForDashboard() async {
    PermissionRuntime.require('sms', AppPermissionAction.view);
    final db = await instance.database;
    final result = await db.query(
      'sms_settings',
      columns: [
        'id',
        'api_url',
        'sender_name',
        'reminder_template',
        'receipt_template',
      ],
    );
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<Map<String, dynamic>?> getSmsSettingsForSending() async {
    PermissionRuntime.require('sms', AppPermissionAction.add);
    final db = await instance.database;
    final result = await db.query('sms_settings');
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<void> saveSmsSettings(Map<String, dynamic> settings) async {
    PermissionRuntime.require('sms', AppPermissionAction.edit);
    final db = await instance.database;
    final existing = await db.query('sms_settings');
    if (existing.isEmpty) {
      await db.insert('sms_settings', settings);
    } else {
      await db.update(
        'sms_settings',
        settings,
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
  }

  Future<void> insertSmsLog(Map<String, dynamic> log) async {
    PermissionRuntime.require('sms', AppPermissionAction.add);
    final db = await instance.database;
    await db.insert('sms_logs', log);
  }

  Future<List<Map<String, dynamic>>> getAllSmsLogs() async {
    PermissionRuntime.require('sms', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('sms_logs', orderBy: 'sent_at DESC');
  }

  Future close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
