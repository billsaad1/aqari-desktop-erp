import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

import '../core/lease_contract_terms.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  bool _hasCentPrecision(num value) {
    final scaled = value.toDouble() * 100;
    return scaled.isFinite && (scaled - scaled.round()).abs() < 0.000001;
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
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    final db = await database;
    final escapedPath = target.absolute.path.replaceAll("'", "''");
    await db.execute("VACUUM INTO '$escapedPath'");

    Database? snapshot;
    try {
      snapshot = await databaseFactory.openDatabase(
        target.absolute.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final check = await snapshot.rawQuery('PRAGMA quick_check');
      if (check.isEmpty || check.first.values.first != 'ok') {
        throw StateError('فشل فحص سلامة النسخة الاحتياطية');
      }
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      await snapshot?.close();
    }
  }

  Future<void> factoryReset() async {
    final path = await getDbPath();
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    await databaseFactory.deleteDatabase(path);
    // Re-initialize to create schema and seed data
    _database = await _initDB('desktop_erp.db');
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
        version: 10,
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
        must_change_password INTEGER NOT NULL DEFAULT 0
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
        FOREIGN KEY (property_id) REFERENCES properties (id),
        FOREIGN KEY (unit_type_id) REFERENCES unit_types (id)
      )
    ''');

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
        invoice_date TEXT NOT NULL,
        total_amount REAL NOT NULL,
        tax_amount REAL NOT NULL,
        FOREIGN KEY (contract_id) REFERENCES contracts (id)
      )
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

  Future<Map<String, dynamic>?> getUserByUsername(String username) async {
    final db = await instance.database;
    final result = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: [username],
    );
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    final db = await instance.database;
    return await db.query('users');
  }

  Future<int> insertUser(Map<String, dynamic> user) async {
    final db = await instance.database;
    return await db.insert('users', user);
  }

  Future<int> updateUser(Map<String, dynamic> user) async {
    final db = await instance.database;
    return await db.update(
      'users',
      user,
      where: 'id = ?',
      whereArgs: [user['id']],
    );
  }

  Future<int> updateUserPassword(
    int userId,
    String passwordHash, {
    bool mustChangePassword = false,
  }) async {
    final db = await instance.database;
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

  Future<int> deleteUser(int id) async {
    final db = await instance.database;
    return await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  // --- CRUD Operations for Audit Logs ---

  Future<int> insertAuditLog(Map<String, dynamic> log) async {
    final db = await instance.database;
    return await db.insert('audit_logs', log);
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
    final db = await instance.database;
    final rows = await db.query('company_info', columns: ['id'], limit: 1);
    final values = Map<String, dynamic>.from(info)..remove('id');
    if (rows.isEmpty) return db.insert('company_info', values);
    final id = info['id'] ?? rows.first['id'];
    return db.update('company_info', values, where: 'id = ?', whereArgs: [id]);
  }

  // --- Generic CRUD Operations for Lookups ---

  Future<List<Map<String, dynamic>>> getLookupData(String tableName) async {
    final db = await instance.database;
    return await db.query(tableName);
  }

  Future<int> insertLookupData(
    String tableName,
    Map<String, dynamic> data,
  ) async {
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
    final db = await instance.database;
    return await db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [data['id']],
    );
  }

  Future<int> deleteLookupData(String tableName, int id) async {
    final db = await instance.database;
    return await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  // --- Accounting Operations ---

  Future<List<Map<String, dynamic>>> getAllAccounts() async {
    final db = await instance.database;
    return await db.query('accounts');
  }

  Future<Map<String, dynamic>?> getAccountById(int id) async {
    final db = await instance.database;
    final result = await db.query('accounts', where: 'id = ?', whereArgs: [id]);
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<String> generateAccountCode(int parentId) async {
    final db = await instance.database;
    final parentResult = await db.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [parentId],
    );
    if (parentResult.isEmpty) throw Exception('Parent account not found');

    final parentCode = parentResult.first['code'] as String;

    final childrenResult = await db.query(
      'accounts',
      where: 'parent_id = ?',
      whereArgs: [parentId],
      orderBy: 'code DESC',
      limit: 1,
    );

    if (childrenResult.isEmpty) {
      return '${parentCode}0001';
    } else {
      final lastChildCode = childrenResult.first['code'] as String;
      final sequenceStr = lastChildCode.substring(parentCode.length);
      int sequence = int.tryParse(sequenceStr) ?? 0;
      sequence++;
      return '$parentCode${sequence.toString().padLeft(4, '0')}';
    }
  }

  Future<int> insertAccount(Map<String, dynamic> account) async {
    final db = await instance.database;
    return await db.insert('accounts', account);
  }

  // Journal Entries with Transactions
  Future<int> insertJournalEntryWithLines(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> lines,
  ) async {
    if (DateTime.tryParse(header['entry_date']?.toString() ?? '') == null) {
      throw ArgumentError('تاريخ القيد غير صحيح');
    }
    if (lines.length < 2)
      throw ArgumentError('يجب أن يحتوي القيد على سطرين على الأقل');
    int debitCents = 0;
    int creditCents = 0;
    for (final line in lines) {
      final debit = (line['debit'] as num? ?? 0).toDouble();
      final credit = (line['credit'] as num? ?? 0).toDouble();
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
    }
    if (debitCents != creditCents || debitCents == 0) {
      throw ArgumentError(
        'القيد غير متوازن: يجب أن يتساوى إجمالي المدين والدائن',
      );
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      // 1. Insert header
      final journalId = await txn.insert('journal_entries', header);

      // 2. Insert lines
      for (var line in lines) {
        final accountId = line['account_id'];
        final accountRows = accountId == null
            ? <Map<String, Object?>>[]
            : await txn.query(
                'accounts',
                where: 'id = ? AND parent_id IS NOT NULL',
                whereArgs: [accountId],
              );
        if (accountRows.isEmpty)
          throw ArgumentError('اختر حساباً تفصيلياً صالحاً لكل سطر');
        line['journal_entry_id'] = journalId;
        await txn.insert('journal_lines', line);

        // 3. Update account balances
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
    if (voucherType != 'قبض عام' && voucherType != 'صرف عام') {
      throw ArgumentError('نوع السند غير معروف');
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
      final cashRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [cashAccountId],
      );
      final oppositeRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [oppositeAccountId],
      );
      if (cashRows.isEmpty ||
          cashRows.first['account_type'] != 'Asset' ||
          cashRows.first['parent_id'] == null ||
          !(cashRows.first['code'] as String).startsWith('11')) {
        throw ArgumentError('حساب النقدية يجب أن يكون صندوقاً أو بنكاً');
      }
      final allowedCounterpartTypes = voucherType == 'قبض عام'
          ? ['Asset', 'Liability', 'Equity', 'Revenue']
          : ['Asset', 'Liability', 'Equity', 'Expense'];
      if (oppositeRows.isEmpty ||
          oppositeAccountId == cashAccountId ||
          oppositeRows.first['parent_id'] == null ||
          !allowedCounterpartTypes.contains(
            oppositeRows.first['account_type'],
          )) {
        throw ArgumentError('الحساب المقابل غير صالح');
      }
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
    int? currentAccountId = accountId;

    while (currentAccountId != null) {
      final accountResult = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [currentAccountId],
      );
      if (accountResult.isNotEmpty) {
        final accountMap = accountResult.first;
        final accountType = accountMap['account_type'] as String?;
        double currentBalance =
            (accountMap['balance'] as num?)?.toDouble() ?? 0.0;

        if (accountType == 'Asset' || accountType == 'Expense') {
          currentBalance += (debit - credit);
        } else if (accountType == 'Liability' ||
            accountType == 'Revenue' ||
            accountType == 'Equity') {
          currentBalance += (credit - debit);
        }

        await txn.update(
          'accounts',
          {'balance': currentBalance},
          where: 'id = ?',
          whereArgs: [currentAccountId],
        );

        currentAccountId = accountMap['parent_id'] as int?;
      } else {
        break;
      }
    }
  }

  // --- Owner & Property Operations ---

  Future<void> insertOwnerWithAccount(Map<String, dynamic> owner) async {
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
      final parentCode = parentResult.first['code'] as String;

      // 2. Generate Account Code for the new owner
      final childrenResult = await txn.query(
        'accounts',
        where: 'parent_id = ?',
        whereArgs: [parentId],
        orderBy: 'code DESC',
        limit: 1,
      );

      String newCode;
      if (childrenResult.isEmpty) {
        newCode = '${parentCode}0001';
      } else {
        final lastChildCode = childrenResult.first['code'] as String;
        final sequenceStr = lastChildCode.substring(parentCode.length);
        int sequence = int.tryParse(sequenceStr) ?? 0;
        sequence++;
        newCode = '$parentCode${sequence.toString().padLeft(4, '0')}';
      }

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': owner['name'],
        'parent_id': parentId,
        'account_type': 'Liability', // Since '2101' is a liability
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Owner linked to the new account
      owner['account_id'] = accountId;
      await txn.insert('owners', owner);
    });
  }

  Future<List<Map<String, dynamic>>> getAllOwners() async {
    final db = await instance.database;
    return await db.query('owners');
  }

  Future<void> updateOwner(Map<String, dynamic> owner) async {
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
        await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
      }
    });
  }

  Future<int> insertProperty(Map<String, dynamic> property) async {
    final db = await instance.database;
    return await db.insert('properties', property);
  }

  Future<void> updateProperty(Map<String, dynamic> property) async {
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
    final db = await instance.database;
    // Basic join could be done here, but let's fetch plain properties for now
    return await db.query('properties');
  }

  Future<int> insertUnit(Map<String, dynamic> unit) async {
    final db = await instance.database;
    return await db.insert('units', unit);
  }

  Future<List<Map<String, dynamic>>> getUnitsForProperty(int propertyId) async {
    final db = await instance.database;
    return await db.query(
      'units',
      where: 'property_id = ?',
      whereArgs: [propertyId],
    );
  }

  Future<void> updateUnit(Map<String, dynamic> unit) async {
    final db = await instance.database;
    final unitId = unit['id'];
    final number = (unit['unit_number'] as String?)?.trim() ?? '';
    final rent = unit['default_rent'] as num?;
    if (unitId is! int || unitId <= 0 || number.isEmpty) {
      throw ArgumentError('معرف الوحدة ورقمها حقول مطلوبة');
    }
    if (rent != null &&
        (!rent.toDouble().isFinite ||
            rent < 0 ||
            !_hasCentPrecision(rent.toDouble()))) {
      throw ArgumentError(
        'الإيجار الافتراضي يجب أن يكون موجبًا وبمنزلتين عشريتين',
      );
    }

    await db.transaction((txn) async {
      final existing = await txn.query(
        'units',
        columns: ['id', 'property_id'],
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('الوحدة المطلوبة غير موجودة');
      final duplicate = await txn.query(
        'units',
        columns: ['id'],
        where: 'property_id = ? AND unit_number = ? AND id != ?',
        whereArgs: [existing.first['property_id'], number, unitId],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw StateError('رقم الوحدة مستخدم في هذا العقار مسبقًا');
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
        },
        where: 'id = ?',
        whereArgs: [unitId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات الوحدة');
    });
  }

  Future<void> deleteUnit(int id) async {
    final db = await instance.database;
    await db.delete('units', where: 'id = ?', whereArgs: [id]);
  }

  // --- Leasing & Tenants Operations ---

  Future<void> insertTenantWithAccount(Map<String, dynamic> tenant) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Find the parent account for Tenants (code: '1201')
      final parentResult = await txn.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1201'],
      );
      if (parentResult.isEmpty)
        throw Exception('حساب ذمم المستأجرين غير موجود (1201)');

      final parentId = parentResult.first['id'] as int;
      final parentCode = parentResult.first['code'] as String;

      // 2. Generate Account Code for the new tenant
      final childrenResult = await txn.query(
        'accounts',
        where: 'parent_id = ?',
        whereArgs: [parentId],
        orderBy: 'code DESC',
        limit: 1,
      );

      String newCode;
      if (childrenResult.isEmpty) {
        newCode = '${parentCode}0001';
      } else {
        final lastChildCode = childrenResult.first['code'] as String;
        final sequenceStr = lastChildCode.substring(parentCode.length);
        int sequence = int.tryParse(sequenceStr) ?? 0;
        sequence++;
        newCode = '$parentCode${sequence.toString().padLeft(4, '0')}';
      }

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': tenant['name'],
        'parent_id': parentId,
        'account_type': 'Asset', // Since '1201' is an asset
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Tenant linked to the new account
      tenant['account_id'] = accountId;
      await txn.insert('tenants', tenant);
    });
  }

  Future<List<Map<String, dynamic>>> getAllTenants() async {
    final db = await instance.database;
    return await db.query('tenants');
  }

  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    final tenantId = tenant['id'];
    final name = (tenant['name'] as String?)?.trim() ?? '';
    final mobile = (tenant['mobile'] as String?)?.trim() ?? '';
    if (tenantId is! int || tenantId <= 0 || name.isEmpty || mobile.isEmpty) {
      throw ArgumentError('معرف المستأجر والاسم والجوال حقول مطلوبة');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
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
        await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
      }
    });
  }

  Future<int> insertContractWithInstallments(
    Map<String, dynamic> contract,
    List<Map<String, dynamic>> installments,
  ) async {
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
      if (tenantId == null ||
          (await txn.query(
            'tenants',
            where: 'id = ?',
            whereArgs: [tenantId],
          )).isEmpty) {
        throw ArgumentError('المستأجر المحدد غير موجود');
      }
      final unitRows = await txn.query(
        'units',
        where: 'id = ?',
        whereArgs: [unitId],
      );
      if (unitRows.isEmpty || unitRows.first['status'] != 'شاغرة') {
        throw StateError('الوحدة لم تعد شاغرة؛ حدّث القائمة واختر وحدة أخرى');
      }
      final activeContracts = await txn.query(
        'contracts',
        columns: ['id'],
        where: "unit_id = ? AND status = 'Active'",
        whereArgs: [unitId],
        limit: 1,
      );
      if (activeContracts.isNotEmpty) throw StateError('للوحدة عقد نشط بالفعل');

      final contractId = await txn.insert('contracts', contract);
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
    final db = await instance.database;
    return await db.query('units', where: 'status = ?', whereArgs: ['شاغرة']);
  }

  Future<List<Map<String, dynamic>>> getAllContracts() async {
    final db = await instance.database;
    return await db.query('contracts');
  }

  Future<List<Map<String, dynamic>>> getInstallmentsForContract(
    int contractId,
  ) async {
    final db = await instance.database;
    return await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    );
  }

  // --- Tenant Financial Operations ---

  Future<int> insertTenantReceiptVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required List<Map<String, dynamic>> installmentsToUpdate,
  }) async {
    if (amount <= 0 ||
        !_hasCentPrecision(amount) ||
        DateTime.tryParse(voucherDate) == null ||
        installmentsToUpdate.isEmpty) {
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
      final cashRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [cashAccountId],
      );
      if (cashRows.isEmpty ||
          cashRows.first['account_type'] != 'Asset' ||
          cashRows.first['parent_id'] == null ||
          !(cashRows.first['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }

      var allocatedCents = 0;
      final verifiedUpdates = <Map<String, dynamic>>[];
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
        allocatedCents += ((newPaid - oldPaid) * 100).round();
        verifiedUpdates.add({
          'id': requested['id'],
          'old_paid': oldPaid,
          'paid_amount': newPaid,
          'status': status,
        });
      }
      if (allocatedCents != (amount * 100).round()) {
        throw ArgumentError('مجموع توزيع الدفعة لا يساوي مبلغ السند');
      }

      final journalId = await txn.insert('journal_entries', {
        'entry_date': voucherDate,
        'description': 'سند قبض مستأجر',
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': amount,
        'credit': 0.0,
        'description': 'تحصيل دفعة مستأجر',
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': 0.0,
        'credit': amount,
        'description': 'تحصيل دفعة مستأجر',
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
        'description': 'تحصيل دفعة إيجار',
      });
      for (final installment in verifiedUpdates) {
        final allocatedAmount =
            (installment['paid_amount'] as num).toDouble() -
            (installment['old_paid'] as num).toDouble();
        await txn.insert('voucher_installment_allocations', {
          'voucher_id': voucherId,
          'installment_id': installment['id'],
          'amount': allocatedAmount,
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
      final cashRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [cashAccountId],
      );
      final offsetRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [offsetAccountId],
      );
      if (cashRows.isEmpty ||
          cashRows.first['account_type'] != 'Asset' ||
          cashRows.first['parent_id'] == null ||
          !(cashRows.first['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }
      if (offsetRows.isEmpty ||
          offsetAccountId == cashAccountId ||
          offsetRows.first['parent_id'] == null ||
          ![
            'Liability',
            'Expense',
            'Revenue',
          ].contains(offsetRows.first['account_type'])) {
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
    return {
      'voucher': headers.first,
      'journal_lines': lines,
      'installments': installments,
    };
  }

  Future<int> insertTaxInvoice({
    required int contractId,
    required int tenantId,
    required String invoiceDate,
    required double totalAmount,
    required double taxAmount,
    required int revenueAccountId,
    required int taxAccountId,
  }) async {
    if (totalAmount <= 0 ||
        !_hasCentPrecision(totalAmount) ||
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
      final duplicates = await txn.query(
        'tax_invoices',
        where:
            'contract_id = ? AND invoice_date = ? AND total_amount = ? AND tax_amount = ?',
        whereArgs: [
          contractId,
          invoiceDate,
          totalAmount + taxAmount,
          taxAmount,
        ],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        throw StateError(
          'هذه الفاتورة صادرة مسبقاً لهذا العقد والتاريخ والمبلغ',
        );
      }
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      final tenantAccountId = tenantRows.first['account_id'] as int;
      final revenueRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [revenueAccountId],
      );
      final taxRows = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [taxAccountId],
      );
      if (revenueRows.isEmpty ||
          revenueRows.first['account_type'] != 'Revenue' ||
          revenueRows.first['parent_id'] == null) {
        throw ArgumentError('اختر حساب إيراد صالحاً');
      }
      if (taxRows.isEmpty ||
          taxRows.first['account_type'] != 'Liability' ||
          taxRows.first['parent_id'] == null) {
        throw ArgumentError('اختر حساب ضريبة من الخصوم');
      }

      final grossAmount = totalAmount + taxAmount;
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
        'credit': totalAmount,
        'description': 'إيراد إيجار',
      });
      if (taxAmount > 0) {
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': taxAccountId,
          'debit': 0.0,
          'credit': taxAmount,
          'description': 'ضريبة قيمة مضافة',
        });
      }
      await _updateBalanceTx(txn, tenantAccountId, grossAmount, 0.0);
      await _updateBalanceTx(txn, revenueAccountId, 0.0, totalAmount);
      if (taxAmount > 0) {
        await _updateBalanceTx(txn, taxAccountId, 0.0, taxAmount);
      }

      return txn.insert('tax_invoices', {
        'contract_id': contractId,
        'invoice_date': invoiceDate,
        'total_amount': grossAmount,
        'tax_amount': taxAmount,
      });
    });
  }

  Future<void> cancelContract(int contractId) async {
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
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM properties) AS properties_count,
        (SELECT COUNT(*) FROM units) AS units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'مؤجرة') AS rented_units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'شاغرة') AS vacant_units_count,
        (SELECT COUNT(*) FROM tenants) AS tenants_count,
        (SELECT COUNT(*) FROM contracts WHERE status = 'Active') AS active_contracts_count,
        (SELECT COALESCE(SUM(MAX(ci.amount - ci.paid_amount, 0)), 0)
          FROM contract_installments ci JOIN contracts c ON c.id = ci.contract_id
          WHERE c.status = 'Active' AND ci.status != 'Paid') AS outstanding_amount
    ''');
    return rows.first;
  }

  Future<double> getAccountOpeningBalance(
    int accountId,
    String startDate,
  ) async {
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
        (SELECT SUM(amount) FROM contract_installments WHERE contract_id = c.id) as total_amount,
        (SELECT SUM(paid_amount) FROM contract_installments WHERE contract_id = c.id) as paid_amount
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
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);

    return await db.rawQuery(
      '''
      SELECT
        ci.id as installment_id,
        ci.due_date,
        ci.amount,
        ci.paid_amount,
        (ci.amount - ci.paid_amount) AS remaining_amount,
        ci.status,
        t.name as tenant_name,
        t.id as tenant_id
      FROM contract_installments ci
      JOIN contracts c ON ci.contract_id = c.id
      JOIN tenants t ON c.tenant_id = t.id
      WHERE ci.status != 'Paid'
        AND c.status = 'Active'
        AND ci.due_date <= ?
      ORDER BY ci.due_date ASC
    ''',
      [targetDateStr],
    );
  }

  Future<List<Map<String, dynamic>>> getExpiringContracts(int days) async {
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

  Future<Map<String, dynamic>?> getSmsSettings() async {
    final db = await instance.database;
    final result = await db.query('sms_settings');
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<void> saveSmsSettings(Map<String, dynamic> settings) async {
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
    final db = await instance.database;
    await db.insert('sms_logs', log);
  }

  Future<List<Map<String, dynamic>>> getAllSmsLogs() async {
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
