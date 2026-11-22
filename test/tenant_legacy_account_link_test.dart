import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_tenant_legacy_account_link_test';
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
    await helper.close();
  });

  tearDownAll(() async {
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<int> parentAccountId(db) async {
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: ['1201'],
      limit: 1,
    );
    return (rows.single['id'] as num).toInt();
  }

  Future<int> insertLegacyTenant(db, int parentId) async {
    return db.insert('tenants', {
      'name': 'مستأجر مرتبط بالحساب الرئيسي',
      'mobile': '7777001001',
      'account_id': parentId,
    });
  }

  test(
    'repairs an unused legacy tenant link atomically and records an audit row',
    () async {
      final db = await helper.database;
      final parentId = await parentAccountId(db);
      final legacyTenantId = await insertLegacyTenant(db, parentId);

      await helper.insertTenantWithAccount({
        'name': 'مستأجر جديد بعد الإصلاح',
        'mobile': '7777001002',
      });

      final legacyTenant = (await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [legacyTenantId],
        limit: 1,
      )).single;
      final newTenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر جديد بعد الإصلاح'],
        limit: 1,
      )).single;
      final legacyAccountId = (legacyTenant['account_id'] as num).toInt();
      final newAccountId = (newTenant['account_id'] as num).toInt();

      expect(legacyAccountId, isNot(parentId));
      expect(newAccountId, isNot(parentId));
      expect(legacyAccountId, isNot(newAccountId));
      for (final accountId in [legacyAccountId, newAccountId]) {
        final account = (await db.query(
          'accounts',
          where: 'id = ?',
          whereArgs: [accountId],
          limit: 1,
        )).single;
        expect((account['parent_id'] as num).toInt(), parentId);
      }

      expect(
        await db.query(
          'journal_lines',
          where: 'account_id = ?',
          whereArgs: [parentId],
        ),
        isEmpty,
      );
      final auditRows = await db.query(
        'audit_logs',
        where: 'action = ? AND entity_id = ?',
        whereArgs: ['LEGACY_TENANT_ACCOUNT_LINK_REPAIRED', legacyTenantId],
      );
      expect(auditRows, hasLength(1));
    },
  );

  test(
    'refuses to relink a legacy tenant when the parent has journal activity and rolls back',
    () async {
      final db = await helper.database;
      final parentId = await parentAccountId(db);
      final legacyTenantId = await insertLegacyTenant(db, parentId);
      final cashId =
          (await db.query(
                'accounts',
                columns: ['id'],
                where: 'code = ?',
                whereArgs: ['1101'],
                limit: 1,
              )).single['id']
              as int;
      final entryId = await db.insert('journal_entries', {
        'entry_date': '2026-11-21',
        'description': 'حركة تاريخية لاختبار حماية الربط',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': parentId,
        'debit': 25.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': cashId,
        'debit': 0.0,
        'credit': 25.0,
      });
      final accountCountBefore = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM accounts',
      )).single['count'];

      await expectLater(
        helper.insertTenantWithAccount({
          'name': 'يجب ألا يحفظ هذا المستأجر',
          'mobile': '7777001003',
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('قيود أو رصيد'),
          ),
        ),
      );

      final legacyTenant = (await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [legacyTenantId],
        limit: 1,
      )).single;
      expect((legacyTenant['account_id'] as num).toInt(), parentId);
      expect(
        await db.query(
          'tenants',
          where: 'name = ?',
          whereArgs: ['يجب ألا يحفظ هذا المستأجر'],
        ),
        isEmpty,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM accounts',
        )).single['count'],
        accountCountBefore,
      );
      expect(
        await db.query(
          'journal_lines',
          where: 'journal_entry_id = ?',
          whereArgs: [entryId],
        ),
        hasLength(2),
      );
      expect(
        await db.query(
          'audit_logs',
          where: 'action = ? AND entity_id = ?',
          whereArgs: ['LEGACY_TENANT_ACCOUNT_LINK_REPAIRED', legacyTenantId],
        ),
        isEmpty,
      );
    },
  );

  test(
    'refuses to relink when the legacy parent has a balance even without journal rows',
    () async {
      final db = await helper.database;
      final parentId = await parentAccountId(db);
      final legacyTenantId = await insertLegacyTenant(db, parentId);
      await db.update(
        'accounts',
        {'balance': 125.0},
        where: 'id = ?',
        whereArgs: [parentId],
      );

      await expectLater(
        helper.insertTenantWithAccount({
          'name': 'مستأجر لا يحفظ عند وجود رصيد',
          'mobile': '7777001004',
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('قيود أو رصيد'),
          ),
        ),
      );

      final legacyTenant = (await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [legacyTenantId],
        limit: 1,
      )).single;
      expect((legacyTenant['account_id'] as num).toInt(), parentId);
      expect(
        await db.query(
          'tenants',
          where: 'name = ?',
          whereArgs: ['مستأجر لا يحفظ عند وجود رصيد'],
        ),
        isEmpty,
      );
      expect(
        (await db.query(
          'accounts',
          columns: ['balance'],
          where: 'id = ?',
          whereArgs: [parentId],
        )).single['balance'],
        125.0,
      );
    },
  );

  test(
    'bank lookup must use a cash account and cannot occupy tenant control account',
    () async {
      final db = await helper.database;
      final tenantParentId = await parentAccountId(db);

      await expectLater(
        helper.insertLookupData('banks', {
          'name': 'بنك مربوط خطأ بذمم المستأجرين',
          'account_id': tenantParentId,
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        await db.query(
          'banks',
          where: 'name = ?',
          whereArgs: ['بنك مربوط خطأ بذمم المستأجرين'],
        ),
        isEmpty,
      );

      final cashRows = await db.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: ['1102'],
        limit: 1,
      );
      final bankAccountId = (cashRows.single['id'] as num).toInt();
      await helper.insertLookupData('banks', {
        'name': 'بنك مربوط بحساب النقدية الصحيح',
        'account_id': bankAccountId,
      });

      await helper.insertTenantWithAccount({
        'name': 'مستأجر بعد إعداد البنك بشكل صحيح',
        'mobile': '7777001010',
      });
      expect(
        await db.query(
          'tenants',
          where: 'name = ?',
          whereArgs: ['مستأجر بعد إعداد البنك بشكل صحيح'],
        ),
        hasLength(1),
      );
    },
  );
}
