import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('desktop_erp.db');
    return _database!;
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
    await Directory(join(dbPath.path, 'AbdullahAlNaqeebERP')).create(recursive: true);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE owners ADD COLUMN iban TEXT;');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE properties ADD COLUMN property_type_id INTEGER;');
      await db.execute('ALTER TABLE units ADD COLUMN floor TEXT;');
      await db.execute('ALTER TABLE units ADD COLUMN elec_meter TEXT;');
      await db.execute('ALTER TABLE units ADD COLUMN water_meter TEXT;');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE sms_settings ADD COLUMN reminder_template TEXT;');
      await db.execute('ALTER TABLE sms_settings ADD COLUMN receipt_template TEXT;');
    }
    if (oldVersion < 5) {
      try {
        await db.execute('ALTER TABLE company_info ADD COLUMN logo_path TEXT;');
      } catch (e) {
        // Ignored if already exists
      }
      try {
        await db.execute('ALTER TABLE company_info ADD COLUMN terms_conditions TEXT;');
      } catch (e) {
        // Ignored if already exists
      }
    }
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
        terms_conditions TEXT
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
        cash_box_account_id INTEGER
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
        journal_entry_id INTEGER,
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id)
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
      'terms_conditions': '1. يلتزم المستأجر بسداد الإيجار في المواعيد المحددة.\n2. لا يحق للمستأجر تأجير العين بالباطن.'
    });

    // Seed Admin User (password: 123456 encrypted in SHA-256 in production logic, here we place the pre-hashed string for 123456)
    // SHA-256 for '123456' is '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
    await db.insert('users', {
      'username': 'admin',
      'password_hash': '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
      'full_name': 'مدير النظام',
      'role': 'SuperAdmin',
    });

    // Seed Lookups
    final cities = ['صنعاء', 'الحديدة', 'عدن', 'تعز', 'إب'];
    for (var city in cities) {
      await db.insert('cities', {'name': city});
    }

    final propertyTypes = ['عمارة سكنية', 'مجمع تجاري', 'فيلا', 'مستودع', 'أرض'];
    for (var pType in propertyTypes) {
      await db.insert('property_types', {'name': pType});
    }

    final unitTypes = ['شقة', 'محل تجاري', 'مكتب', 'معرض', 'ملحق', 'مستودع'];
    for (var uType in unitTypes) {
      await db.insert('unit_types', {'name': uType});
    }

    // Seed Chart of Accounts
    final accounts = [
      {'code': '1', 'name': 'الأصول', 'parent_id': null, 'account_type': 'Asset'},
      {'code': '11', 'name': 'النقدية والبنوك', 'parent_id': 1, 'account_type': 'Asset'},
      {'code': '1101', 'name': 'الصندوق الرئيسي', 'parent_id': 2, 'account_type': 'Asset'},
      {'code': '1102', 'name': 'البنك', 'parent_id': 2, 'account_type': 'Asset'},
      {'code': '1201', 'name': 'ذمم المستأجرين', 'parent_id': 1, 'account_type': 'Asset'},
      {'code': '2', 'name': 'الخصوم', 'parent_id': null, 'account_type': 'Liability'},
      {'code': '2101', 'name': 'حسابات الملاك الجارية', 'parent_id': 6, 'account_type': 'Liability'},
      {'code': '2102', 'name': 'تأمينات المستأجرين المستردة', 'parent_id': 6, 'account_type': 'Liability'},
      {'code': '2103', 'name': 'ضريبة القيمة المضافة', 'parent_id': 6, 'account_type': 'Liability'},
      {'code': '4', 'name': 'الإيرادات', 'parent_id': null, 'account_type': 'Revenue'},
      {'code': '4101', 'name': 'إيرادات إيجارات العقارات', 'parent_id': 10, 'account_type': 'Revenue'},
      {'code': '4102', 'name': 'إيرادات عمولات السعي والإدارة', 'parent_id': 10, 'account_type': 'Revenue'},
      {'code': '5', 'name': 'المصروفات', 'parent_id': null, 'account_type': 'Expense'},
      {'code': '5101', 'name': 'المصروفات الإدارية والنثرية', 'parent_id': 13, 'account_type': 'Expense'},
      {'code': '5102', 'name': 'رواتب وأجور الموظفين', 'parent_id': 13, 'account_type': 'Expense'},
      {'code': '5103', 'name': 'مصاريف صيانة العقارات', 'parent_id': 13, 'account_type': 'Expense'},
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

  Future<int> deleteUser(int id) async {
    final db = await instance.database;
    return await db.delete(
      'users',
      where: 'id = ?',
      whereArgs: [id],
    );
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
    // Assuming there's only one company info record with id = 1
    return await db.update(
      'company_info',
      info,
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  // --- Generic CRUD Operations for Lookups ---

  Future<List<Map<String, dynamic>>> getLookupData(String tableName) async {
    final db = await instance.database;
    return await db.query(tableName);
  }

  Future<int> insertLookupData(String tableName, Map<String, dynamic> data) async {
    final db = await instance.database;

    // Auto-generate code for cost_centers
    if (tableName == 'cost_centers' && (!data.containsKey('code') || data['code'] == null || data['code'].toString().isEmpty)) {
      final List<Map<String, dynamic>> maps = await db.rawQuery('SELECT code FROM cost_centers ORDER BY id DESC LIMIT 1');
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

  Future<int> updateLookupData(String tableName, Map<String, dynamic> data) async {
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
    return await db.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
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
    final parentResult = await db.query('accounts', where: 'id = ?', whereArgs: [parentId]);
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
      return '${parentCode}01';
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
  Future<void> insertJournalEntryWithLines(Map<String, dynamic> header, List<Map<String, dynamic>> lines) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Insert header
      final journalId = await txn.insert('journal_entries', header);

      // 2. Insert lines
      for (var line in lines) {
        line['journal_entry_id'] = journalId;
        await txn.insert('journal_lines', line);

        // 3. Update account balances
        final accountId = line['account_id'];
        final debit = line['debit'] ?? 0.0;
        final credit = line['credit'] ?? 0.0;

        await _updateBalanceTx(txn, accountId, debit, credit);
      }
    });
  }

  // General Vouchers (Receipts/Payments) with Auto-Posting
  Future<void> insertGeneralVoucher(Map<String, dynamic> voucher, int cashAccountId, int oppositeAccountId, int? costCenterId, String voucherType) async {
    final db = await instance.database;
    await db.transaction((txn) async {

      final amount = (voucher['amount'] as num).toDouble();
      final date = voucher['voucher_date'];
      final description = "سند $voucherType رقم آلي";

      // 1. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': date,
        'description': description,
        'is_posted': 1
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 2. Insert Journal Lines
      Map<String, dynamic> line1 = {
        'journal_entry_id': journalId,
      };
      Map<String, dynamic> line2 = {
        'journal_entry_id': journalId,
      };

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
      await _updateBalanceTx(txn, line1['account_id'], line1['debit'], line1['credit']);
      // Credit line
      await _updateBalanceTx(txn, line2['account_id'], line2['debit'], line2['credit']);

      // 3. Insert Voucher
      voucher['journal_entry_id'] = journalId;
      await txn.insert('vouchers', voucher);
    });
  }

  Future<void> _updateBalanceTx(Transaction txn, int accountId, double debit, double credit) async {
     int? currentAccountId = accountId;

     while (currentAccountId != null) {
        final accountResult = await txn.query('accounts', where: 'id = ?', whereArgs: [currentAccountId]);
        if (accountResult.isNotEmpty) {
          final accountMap = accountResult.first;
          final accountType = accountMap['account_type'] as String?;
          double currentBalance = (accountMap['balance'] as num?)?.toDouble() ?? 0.0;

          if (accountType == 'Asset' || accountType == 'Expense') {
             currentBalance += (debit - credit);
          } else if (accountType == 'Liability' || accountType == 'Revenue' || accountType == 'Equity') {
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
      final parentResult = await txn.query('accounts', where: 'code = ?', whereArgs: ['2101']);
      if (parentResult.isEmpty) throw Exception('حساب الملاك الرئيسي غير موجود (2101)');

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

  Future<int> insertProperty(Map<String, dynamic> property) async {
    final db = await instance.database;
    return await db.insert('properties', property);
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
    return await db.query('units', where: 'property_id = ?', whereArgs: [propertyId]);
  }

  Future<void> updateUnit(Map<String, dynamic> unit) async {
    final db = await instance.database;
    await db.update(
      'units',
      unit,
      where: 'id = ?',
      whereArgs: [unit['id']],
    );
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
      final parentResult = await txn.query('accounts', where: 'code = ?', whereArgs: ['1201']);
      if (parentResult.isEmpty) throw Exception('حساب ذمم المستأجرين غير موجود (1201)');

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

  Future<void> insertContractWithInstallments(Map<String, dynamic> contract, List<Map<String, dynamic>> installments) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Insert contract
      final contractId = await txn.insert('contracts', contract);

      // 2. Insert installments
      for (var inst in installments) {
        inst['contract_id'] = contractId;
        await txn.insert('contract_installments', inst);
      }

      // 3. Update unit status to 'مؤجرة'
      final unitId = contract['unit_id'];
      await txn.update(
        'units',
        {'status': 'مؤجرة'},
        where: 'id = ?',
        whereArgs: [unitId],
      );
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

  Future<List<Map<String, dynamic>>> getInstallmentsForContract(int contractId) async {
    final db = await instance.database;
    return await db.query('contract_installments', where: 'contract_id = ?', whereArgs: [contractId]);
  }

  // --- Tenant Financial Operations ---

  Future<void> insertTenantReceiptVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required List<Map<String, dynamic>> installmentsToUpdate,
  }) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Fetch Tenant's Account ID
      final tenantResult = await txn.query('tenants', where: 'id = ?', whereArgs: [tenantId]);
      if (tenantResult.isEmpty) throw Exception('المستأجر غير موجود');
      final tenantAccountId = tenantResult.first['account_id'] as int;

      // 2. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': voucherDate,
        'description': 'سند قبض مستأجر رقم آلي',
        'is_posted': 1
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 3. Insert Journal Lines (Cash Debit, Tenant Asset Credit)
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

      // 4. Update balances
      await _updateBalanceTx(txn, cashAccountId, amount, 0.0);
      await _updateBalanceTx(txn, tenantAccountId, 0.0, amount);

      // 5. Insert Voucher
      final voucher = {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'journal_entry_id': journalId,
      };
      await txn.insert('vouchers', voucher);

      // 6. Update Installments
      for (var inst in installmentsToUpdate) {
        await txn.update(
          'contract_installments',
          {'paid_amount': inst['paid_amount'], 'status': inst['status']},
          where: 'id = ?',
          whereArgs: [inst['id']],
        );
      }
    });
  }

  Future<void> insertTenantPaymentVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required String description,
  }) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Fetch Tenant's Account ID
      final tenantResult = await txn.query('tenants', where: 'id = ?', whereArgs: [tenantId]);
      if (tenantResult.isEmpty) throw Exception('المستأجر غير موجود');
      final tenantAccountId = tenantResult.first['account_id'] as int;

      // 2. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': voucherDate,
        'description': description,
        'is_posted': 1
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 3. Insert Journal Lines (Tenant Asset Debit, Cash Credit)
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
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

      // 4. Update balances
      await _updateBalanceTx(txn, tenantAccountId, amount, 0.0);
      await _updateBalanceTx(txn, cashAccountId, 0.0, amount);

      // 5. Insert Voucher
      final voucher = {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'journal_entry_id': journalId,
      };
      await txn.insert('vouchers', voucher);
    });
  }

  Future<void> insertTaxInvoice({
    required int contractId,
    required int tenantId,
    required String invoiceDate,
    required double totalAmount, // Net Rent
    required double taxAmount,
    required int revenueAccountId,
    required int taxAccountId,
  }) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Fetch Tenant's Account ID
      final tenantResult = await txn.query('tenants', where: 'id = ?', whereArgs: [tenantId]);
      if (tenantResult.isEmpty) throw Exception('المستأجر غير موجود');
      final tenantAccountId = tenantResult.first['account_id'] as int;

      double grossAmount = totalAmount + taxAmount;

      // 2. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': invoiceDate,
        'description': 'إثبات فاتورة ضريبية إيجار',
        'is_posted': 1
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 3. Insert Journal Lines
      // Debit: Tenant (Asset) for Gross
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': grossAmount,
        'credit': 0.0,
        'description': 'استحقاق فاتورة إيجار',
      });
      // Credit: Revenue Account for Net
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': revenueAccountId,
        'debit': 0.0,
        'credit': totalAmount,
        'description': 'إيراد إيجار',
      });
      // Credit: Tax Account (Liability) for Tax
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': taxAccountId,
        'debit': 0.0,
        'credit': taxAmount,
        'description': 'ضريبة قيمة مضافة',
      });

      // 4. Update balances
      await _updateBalanceTx(txn, tenantAccountId, grossAmount, 0.0);
      await _updateBalanceTx(txn, revenueAccountId, 0.0, totalAmount);
      await _updateBalanceTx(txn, taxAccountId, 0.0, taxAmount);

      // 5. Insert Tax Invoice
      await txn.insert('tax_invoices', {
        'contract_id': contractId,
        'invoice_date': invoiceDate,
        'total_amount': grossAmount, // Conventionally gross total is saved, but depends on design
        'tax_amount': taxAmount,
      });
    });
  }

  Future<void> cancelContract(int contractId) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Check if any installments are paid
      final installments = await txn.query('contract_installments', where: 'contract_id = ?', whereArgs: [contractId]);
      bool hasPaid = installments.any((inst) => (inst['paid_amount'] as num) > 0);
      if (hasPaid) {
        throw Exception('لا يمكن إلغاء العقد بشكل مباشر. يوجد دفعات مسددة، يتطلب عمل تسوية أو إشعار دائن.');
      }

      // 2. Get Unit ID before deleting/updating
      final contractResult = await txn.query('contracts', where: 'id = ?', whereArgs: [contractId]);
      if (contractResult.isEmpty) throw Exception('العقد غير موجود');
      final unitId = contractResult.first['unit_id'] as int;

      // 3. Delete unpaid installments
      await txn.delete('contract_installments', where: 'contract_id = ?', whereArgs: [contractId]);

      // 4. Update Contract Status
      await txn.update(
        'contracts',
        {'status': 'Cancelled'},
        where: 'id = ?',
        whereArgs: [contractId],
      );

      // 5. Update Unit Status back to 'شاغرة'
      await txn.update(
        'units',
        {'status': 'شاغرة'},
        where: 'id = ?',
        whereArgs: [unitId],
      );
    });
  }

  // --- Reports & Alerts Queries ---

  Future<List<Map<String, dynamic>>> getAccountStatement(int accountId, String startDate, String endDate) async {
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT
        je.entry_date as date,
        je.id as voucher_no,
        jl.description as description,
        jl.debit as debit,
        jl.credit as credit
      FROM journal_lines jl
      JOIN journal_entries je ON jl.journal_entry_id = je.id
      WHERE jl.account_id = ? AND je.entry_date >= ? AND je.entry_date <= ?
      ORDER BY je.entry_date ASC, je.id ASC
    ''', [accountId, startDate, endDate]);
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

  Future<List<Map<String, dynamic>>> searchTenantsAndContracts(String query) async {
    final db = await instance.database;
    final searchTerm = '%$query%';
    return await db.rawQuery('''
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
    ''', [searchTerm, searchTerm, searchTerm]);
  }

  Future<List<Map<String, dynamic>>> getDueInstallments(int days) async {
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);

    return await db.rawQuery('''
      SELECT
        ci.id as installment_id,
        ci.due_date,
        ci.amount,
        ci.paid_amount,
        ci.status,
        t.name as tenant_name,
        t.id as tenant_id
      FROM contract_installments ci
      JOIN contracts c ON ci.contract_id = c.id
      JOIN tenants t ON c.tenant_id = t.id
      WHERE ci.status != 'Paid' AND ci.due_date <= ?
      ORDER BY ci.due_date ASC
    ''', [targetDateStr]);
  }

  Future<List<Map<String, dynamic>>> getExpiringContracts(int days) async {
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);

    return await db.rawQuery('''
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
      WHERE c.status = 'Active' AND c.end_date <= ?
      ORDER BY c.end_date ASC
    ''', [targetDateStr]);
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
      await db.update('sms_settings', settings, where: 'id = ?', whereArgs: [existing.first['id']]);
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
    final db = await instance.database;
    db.close();
  }
}
