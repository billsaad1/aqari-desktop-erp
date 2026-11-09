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
        version: 1,
        onCreate: _createDB,
      ),
    );
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
        logo_path TEXT
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
        cost_center_id INTEGER,
        address TEXT,
        deed_number TEXT,
        FOREIGN KEY (owner_id) REFERENCES owners (id),
        FOREIGN KEY (city_id) REFERENCES cities (id),
        FOREIGN KEY (cost_center_id) REFERENCES cost_centers (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER NOT NULL,
        unit_number TEXT NOT NULL,
        unit_type_id INTEGER,
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
        sender_name TEXT
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
      'default_currency': 'ريال يمني (YER)'
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

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
