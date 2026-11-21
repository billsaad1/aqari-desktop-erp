import 'dart:convert';
import 'dart:io';

import 'package:app/core/crypto_utils.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/audit/audit_trail_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_audit_trail_flutter_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return testDocuments;
          }
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
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    await helper.close();
  });

  /// Resolves a seeded leaf account by code; the chart is created by _createDB.
  Future<int> seededAccount(String code) async {
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

  /// Seeds an owner, property, unit, tenant and an active contract with two
  /// installments — the minimum state the leasing writers require.
  Future<({int tenantId, int contractId, List<Map<String, Object?>> installments})>
  seedActiveContract({String suffix = ''}) async {
    final db = await helper.database;
    final ownerId = await db.insert('owners', {'name': 'مالك تدقيق$suffix'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار تدقيق$suffix',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'AUD-$suffix',
      'default_rent': 100.0,
      'default_rent_period': 'monthly',
    });
    await helper.insertTenantWithAccount({
      'name': 'مستأجر تدقيق$suffix',
      'mobile': '7770000$suffix',
    });
    final tenantId =
        (await db.query(
              'tenants',
              where: 'name = ?',
              whereArgs: ['مستأجر تدقيق$suffix'],
            )).single['id']
            as int;

    final contractId = await helper.insertContractWithInstallments({
      'tenant_id': tenantId,
      'unit_id': unitId,
      'start_date': '2026-11-10',
      'end_date': '2027-11-09',
      'rent_amount': 200.0,
      'payment_method': 'شهري',
      'status': 'Active',
    }, [
      {
        'amount': 100.0,
        'paid_amount': 0.0,
        'due_date': '2026-11-10',
        'status': 'Unpaid',
      },
      {
        'amount': 100.0,
        'paid_amount': 0.0,
        'due_date': '2026-12-10',
        'status': 'Unpaid',
      },
    ]);

    final installments = await helper.getInstallmentsForContract(contractId);
    return (
      tenantId: tenantId,
      contractId: contractId,
      installments: installments,
    );
  }

  group('audit trail is append-only', () {
    test('update and delete are rejected by database triggers', () async {
      final db = await helper.database;
      await db.insert('audit_logs', {
        'user_id': 1,
        'actor_name': 'مدير النظام',
        'action': 'TEST_APPEND_ONLY',
        'details': jsonEncode({'probe': true}),
        'timestamp': DateTime.now().toIso8601String(),
      });

      await expectLater(
        db.update(
          'audit_logs',
          {'action': 'TAMPERED'},
          where: "action = 'TEST_APPEND_ONLY'",
        ),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.delete('audit_logs', where: "action = 'TEST_APPEND_ONLY'"),
        throwsA(isA<DatabaseException>()),
      );

      final rows = await db.query(
        'audit_logs',
        where: "action = 'TEST_APPEND_ONLY'",
      );
      expect(rows, hasLength(1));
    });

    test('append-only triggers are present in the schema', () async {
      final db = await helper.database;
      final triggers = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'audit_logs'",
      )).map((row) => row['name']).toSet();
      expect(
        triggers,
        containsAll(['audit_logs_no_update', 'audit_logs_no_delete']),
      );
    });

    test('deleting a user keeps the trail and its actor snapshot', () async {
      final username = 'audit_delete_${DateTime.now().microsecondsSinceEpoch}';
      final userId = await helper.insertUser({
        'username': username,
        'full_name': 'مستخدم اختبار الحذف',
        'password_hash': CryptoUtils.hashPassword('Test-password-1234'),
        'role': 'DataEntry',
      });
      final db = await helper.database;
      await db.insert('audit_logs', {
        'user_id': userId,
        'actor_name': 'مستخدم اختبار الحذف',
        'action': 'TEST_USER_DELETED_ACTOR',
        'details': jsonEncode({'user_id': userId}),
        'timestamp': DateTime.now().toIso8601String(),
      });

      expect(await helper.deleteUser(userId), 1);

      final rows = await helper.getAuditTrail(
        action: 'TEST_USER_DELETED_ACTOR',
      );
      expect(rows, hasLength(1));
      expect(rows.single['user_name'], 'مستخدم اختبار الحذف');
    });
  });

  group('financial operations are audited', () {
    test('posting a journal entry records one audit row', () async {
      final debitId = await seededAccount('1101');
      final creditId = await seededAccount('4101');

      final entryId = await helper.insertJournalEntryWithLines(
        {
          'entry_date': '2026-02-01',
          'description': 'قيد اختبار التدقيق',
          'is_posted': 1,
        },
        [
          {'account_id': debitId, 'debit': 150.25, 'credit': 0},
          {'account_id': creditId, 'debit': 0, 'credit': 150.25},
        ],
      );

      final rows = await helper.getAuditTrail(
        action: 'JOURNAL_ENTRY_POSTED',
        entityType: 'journal_entry',
        entityId: entryId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 15025);
      final details = jsonDecode(rows.single['details'] as String);
      expect(details['debit_minor'], 15025);
      expect(details['credit_minor'], 15025);
      expect(details['line_count'], 2);
    });

    test('posting a general voucher records the voucher and amount', () async {
      final cashId = await seededAccount('1101');
      final revenueId = await seededAccount('4101');

      final voucherId = await helper.insertGeneralVoucher(
        {
          'voucher_type': 'قبض عام',
          'voucher_date': '2026-02-02',
          'amount': 99.5,
          'description': 'سند قبض عام للاختبار',
        },
        cashId,
        revenueId,
        null,
        'قبض عام',
      );

      final rows = await helper.getAuditTrail(
        action: 'GENERAL_VOUCHER_POSTED',
        entityType: 'voucher',
        entityId: voucherId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 9950);
    });

    test('a failed posting leaves no audit row behind', () async {
      final cashId = await seededAccount('1101');
      final revenueId = await seededAccount('4101');
      final before = await helper.getAuditTrail(
        action: 'GENERAL_VOUCHER_POSTED',
      );

      await expectLater(
        helper.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-02-03',
            'amount': -5,
            'description': 'سند غير صالح',
          },
          cashId,
          revenueId,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );

      final after = await helper.getAuditTrail(
        action: 'GENERAL_VOUCHER_POSTED',
      );
      expect(after.length, before.length);
    });

    test('creating a contract records the contract and its rent', () async {
      final seeded = await seedActiveContract(suffix: 'C');

      final rows = await helper.getAuditTrail(
        action: 'CONTRACT_CREATED',
        entityType: 'contract',
        entityId: seeded.contractId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 20000);
      final details = jsonDecode(rows.single['details'] as String);
      expect(details['installment_count'], 2);
      expect(details['tenant_id'], seeded.tenantId);
    });

    test('cancelling a contract records the reason in the same row', () async {
      final seeded = await seedActiveContract(suffix: 'X');

      await helper.cancelContract(seeded.contractId, reason: 'إخلال بالدفع');

      final rows = await helper.getAuditTrail(
        action: 'contract_cancelled',
        entityType: 'contract',
        entityId: seeded.contractId,
      );
      expect(rows, hasLength(1));
      final details = jsonDecode(rows.single['details'] as String);
      expect(details['reason'], 'إخلال بالدفع');
    });

    test('a tenant receipt records the collected amount', () async {
      final seeded = await seedActiveContract(suffix: 'R');
      final cashId = await seededAccount('1101');

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

      final rows = await helper.getAuditTrail(
        action: 'TENANT_RECEIPT_POSTED',
        entityType: 'voucher',
        entityId: receiptId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 10000);
    });

    test('a tenant refund records the refunded amount', () async {
      final seeded = await seedActiveContract(suffix: 'F');
      final cashId = await seededAccount('1101');

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
        description: 'استرداد جزئي',
      );

      final rows = await helper.getAuditTrail(
        action: 'TENANT_REFUND_POSTED',
        entityType: 'voucher',
        entityId: refundId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 4000);
    });

    test('issuing a tax invoice records the gross amount', () async {
      await helper.updateCompanyInfo({'name_ar': 'منشأة تدقيق', 'tax_rate': 15.0});
      final seeded = await seedActiveContract(suffix: 'I');
      final revenueId = await seededAccount('4101');
      final taxId = await seededAccount('2103');

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

      final rows = await helper.getAuditTrail(
        action: 'TAX_INVOICE_ISSUED',
        entityType: 'tax_invoice',
        entityId: invoiceId,
      );
      expect(rows, hasLength(1));
      expect(rows.single['amount_minor'], 11500);
      final details = jsonDecode(rows.single['details'] as String);
      expect(details['net_amount_minor'], 10000);
      expect(details['tax_amount_minor'], 1500);
    });

    test('a rejected tax invoice leaves neither an invoice nor an audit row',
        () async {
      await helper.updateCompanyInfo({'name_ar': 'منشأة تدقيق', 'tax_rate': 15.0});
      final seeded = await seedActiveContract(suffix: 'J');
      final revenueId = await seededAccount('4101');
      final taxId = await seededAccount('2103');
      final db = await helper.database;
      final invoicesBefore = (await db.query('tax_invoices')).length;

      await expectLater(
        helper.insertTaxInvoice(
          contractId: seeded.contractId,
          tenantId: seeded.tenantId,
          installmentId: seeded.installments.first['id'] as int,
          invoiceDate: '2026-11-10',
          netAmount: -1,
          taxAmount: 15.0,
          revenueAccountId: revenueId,
          taxAccountId: taxId,
        ),
        throwsArgumentError,
      );

      expect((await db.query('tax_invoices')).length, invoicesBefore);
      final rows = await helper.getAuditTrail(action: 'TAX_INVOICE_ISSUED');
      expect(
        rows.where((row) => row['entity_id'] == seeded.contractId),
        isEmpty,
      );
    });
  });

  group('audit trail access control', () {
    test('view permission is required to read the trail', () async {
      PermissionRuntime.activate(
        userId: 1,
        role: 'DataEntry',
        permissionRows: const [],
      );
      await expectLater(
        helper.getAuditTrail(),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        helper.getAuditTrailActions(),
        throwsA(isA<StateError>()),
      );
    });

    test('explicit view grant allows an otherwise denied role', () async {
      PermissionRuntime.activate(
        userId: 1,
        role: 'DataEntry',
        permissionRows: [
          {
            'screen_name': 'audit_logs',
            'can_view': 1,
            'can_add': 0,
            'can_edit': 0,
            'can_delete': 0,
            'can_print': 0,
            'can_post': 0,
            'can_review_approve': 0,
          },
        ],
      );
      expect(await helper.getAuditTrail(), isA<List<Map<String, dynamic>>>());
    });

    test('audit_logs is an independent permission module', () {
      expect(AppPermissionCatalog.module('audit_logs'), isNotNull);
      expect(AppPermissionCatalog.codeForNavigationIndex(13), 'audit_logs');
      expect(AppPermissionCatalog.codeForNavigationIndex(9), 'system_services');
    });
  });

  group('audit trail query filters', () {
    test('date bounds are validated instead of silently ignored', () async {
      await expectLater(
        helper.getAuditTrail(fromDate: '2026-13-40'),
        throwsArgumentError,
      );
      await expectLater(
        helper.getAuditTrail(fromDate: '2026-03-01', toDate: '2026-02-01'),
        throwsArgumentError,
      );
      await expectLater(
        helper.getAuditTrail(fromDate: '01/02/2026'),
        throwsArgumentError,
      );
    });

    test('toDate includes the whole final day', () async {
      final db = await helper.database;
      await db.insert('audit_logs', {
        'user_id': 1,
        'actor_name': 'مدير النظام',
        'action': 'TEST_LAST_MINUTE_OF_DAY',
        'details': '{}',
        'timestamp': '2026-04-10T23:59:59',
      });
      final sameDay = await helper.getAuditTrail(
        fromDate: '2026-04-10',
        toDate: '2026-04-10',
      );
      expect(
        sameDay.any((row) => row['action'] == 'TEST_LAST_MINUTE_OF_DAY'),
        isTrue,
      );
      final nextDay = await helper.getAuditTrail(fromDate: '2026-04-11');
      expect(
        nextDay.any((row) => row['action'] == 'TEST_LAST_MINUTE_OF_DAY'),
        isFalse,
      );
    });

    test('audit rows never carry password material', () async {
      final db = await helper.database;
      final rows = await db.query('audit_logs');
      for (final row in rows) {
        final details = row['details']?.toString().toLowerCase() ?? '';
        expect(details, isNot(contains('password')));
        expect(details, isNot(contains('pbkdf2')));
        expect(details, isNot(contains('api_key')));
      }
    });
  });

  group('every writer records entity and actor', () {
    Future<Map<String, Object?>> latestFor(String action) async {
      final db = await helper.database;
      final rows = await db.query(
        'audit_logs',
        where: 'action = ?',
        whereArgs: [action],
        orderBy: 'id DESC',
        limit: 1,
      );
      return rows.single;
    }

    test('account creation and rename capture type, id and actor', () async {
      final rootId = await seededAccount('1');
      final accountId = await DatabaseHelper.instance.insertAccount({
        'name': 'حساب تدقيق',
        'parent_id': rootId,
      });
      final created = await latestFor('ACCOUNT_CREATE');
      expect(created['entity_type'], 'account');
      expect(created['entity_id'], accountId);
      expect(created['actor_name'], isNotNull);
      expect(created['user_id'], 1);

      await DatabaseHelper.instance.updateAccount(accountId, 'حساب معدل');
      final renamed = await latestFor('ACCOUNT_RENAME');
      expect(renamed['entity_type'], 'account');
      expect(renamed['entity_id'], accountId);
      final details = jsonDecode(renamed['details'] as String) as Map;
      expect(details['old_name'], 'حساب تدقيق');
      expect(details['new_name'], 'حساب معدل');
    });

    test('user creation captures the user entity and actor name', () async {
      final userId = await DatabaseHelper.instance.insertUser({
        'username': 'audit_user',
        'password_hash': CryptoUtils.hashPassword('A-strong-password-2026'),
        'full_name': 'مستخدم تدقيق',
        'role': 'DataEntry',
      });
      final created = await latestFor('USER_CREATE');
      expect(created['entity_type'], 'user');
      expect(created['entity_id'], userId);
      expect(created['actor_name'], isNotNull);
    });

    test('authentication events keep an entity id and no credentials', () async {
      await DatabaseHelper.instance.recordAuthenticationAudit(
        expectedUserId: 1,
        isLogin: true,
      );
      final login = await latestFor('LOGIN');
      expect(login['entity_type'], 'session');
      expect(login['entity_id'], 1);
      final details = (login['details'] as String).toLowerCase();
      expect(details, isNot(contains('password')));
    });
  });

  group('search matches the actor as well as the event', () {
    test('finds a row by the snapshotted actor name', () async {
      final db = await helper.database;
      await db.insert('audit_logs', {
        'user_id': null,
        'actor_name': 'سالم الحارثي',
        'action': 'ACTOR_SEARCH_PROBE',
        'details': '{}',
        'timestamp': DateTime.now().toIso8601String(),
      });

      final byName = await helper.getAuditTrail(search: 'سالم');
      expect(byName.map((row) => row['action']), contains('ACTOR_SEARCH_PROBE'));
    });
  });

  group('v22 to v24 upgrade', () {
    test('rebuilds audit_logs, keeps rows and backfills the actor', () async {
      final db = await helper.database;
      await db.execute('DROP TABLE audit_logs');
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
      await db.insert('audit_logs', {
        'user_id': 1,
        'action': 'PRE_MIGRATION_EVENT',
        'details': jsonEncode({'legacy': true}),
        'timestamp': '2026-01-01T00:00:00',
      });
      await db.execute('PRAGMA user_version = 22');
      await helper.close();

      final upgraded = await helper.database;
      final rows = await upgraded.query(
        'audit_logs',
        where: "action = 'PRE_MIGRATION_EVENT'",
      );
      expect(rows, hasLength(1));
      expect(rows.single['details'], jsonEncode({'legacy': true}));
      expect(rows.single['actor_name'], isNotNull);

      final definition =
          (await upgraded.rawQuery(
                "SELECT sql FROM sqlite_master WHERE name = 'audit_logs'",
              )).single['sql']
              as String;
      expect(definition, isNot(contains('REFERENCES users')));
      final triggers = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'audit_logs'",
      )).map((row) => row['name']).toSet();
      expect(
        triggers,
        containsAll(['audit_logs_no_update', 'audit_logs_no_delete']),
      );
    });
  });

  group('the viewer never shows a raw action code', () {
    test('every action literal written by the database has a label', () {
      final source = File(
        'lib/database/database_helper.dart',
      ).readAsStringSync();
      final codes = RegExp(
        r"""action:\s*'([A-Za-z_]+)'|'action':\s*'([A-Za-z_]+)'""",
      )
          .allMatches(source)
          .map((match) => match.group(1) ?? match.group(2)!)
          .where((code) => !code.contains(r'$'))
          .toSet();

      expect(codes, isNotEmpty);
      expect(AuditTrailScreen.actionLabel('CONTRACT_RENEWED'), 'تجديد عقد');
      expect(
        AuditTrailScreen.actionLabel('OWNER_SETTLEMENT_POSTED'),
        'ترحيل سند سداد مالك',
      );
      final unlabelled = codes.where((code) {
        final label = AuditTrailScreen.actionLabel(code);
        return label == code || !RegExp(r'[\u0600-\u06FF]').hasMatch(label);
      });
      expect(unlabelled, isEmpty);
    });
  });
}
