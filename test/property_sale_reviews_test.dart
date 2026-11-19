import 'dart:convert';
import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_property_sale_flutter_test';
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

  test('sale review permission is distinct from posting and role defaults', () {
    expect(AppPermissionCatalog.codeForNavigationIndex(12), 'property_sales');
    expect(
      AppPermissionCatalog.roleAllows(
        'DataEntry',
        'property_sales',
        AppPermissionAction.add,
      ),
      isTrue,
    );
    expect(
      AppPermissionCatalog.roleAllows(
        'DataEntry',
        'property_sales',
        AppPermissionAction.reviewApprove,
      ),
      isFalse,
    );
    expect(
      AppPermissionCatalog.roleAllows(
        'Accountant',
        'property_sales',
        AppPermissionAction.reviewApprove,
      ),
      isTrue,
    );
    expect(
      AppPermissionCatalog.roleAllows(
        'Admin',
        'property_sales',
        AppPermissionAction.reviewApprove,
      ),
      isFalse,
    );

    PermissionRuntime.activate(
      userId: 42,
      role: 'Admin',
      permissionRows: [
        {
          'screen_name': 'property_sales',
          'can_view': 1,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 0,
          'can_post': 0,
          'can_review_approve': 1,
        },
      ],
    );
    expect(
      PermissionRuntime.allows(
        'property_sales',
        AppPermissionAction.reviewApprove,
      ),
      isTrue,
    );
    expect(
      PermissionRuntime.allows('property_sales', AppPermissionAction.post),
      isFalse,
    );
  });

  test(
    'request snapshots target and active-lease count without financial or lease effects',
    () async {
      final db = await helper.database;
      final ids = await _seedPropertyWithUnits(db, activeOnUnit1: true);
      final journalEntriesBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
      );
      final journalLinesBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_lines'),
      );
      final accountBalancesBefore = await db.rawQuery(
        'SELECT id, balance FROM accounts ORDER BY id',
      );
      final ownerIdBefore = (await db.query(
        'properties',
        columns: ['owner_id'],
        where: 'id = ?',
        whereArgs: [ids['property_id']],
      )).single['owner_id'];

      final reviewId = await helper.createPropertySaleReview(
        targetType: 'unit',
        propertyId: ids['property_id']!,
        unitId: ids['unit1_id'],
        reason: 'طلب مراجعة بيع مدخل يدويًا',
        proposedAmountMinor: 123456789,
        proposedSaleDate: '2026-12-31',
      );

      final review = (await helper.getPropertySaleReviews()).single;
      final snapshot =
          jsonDecode(review['target_snapshot_json']! as String)
              as Map<String, dynamic>;
      expect(review['id'], reviewId);
      expect(review['status'], 'pending');
      expect(review['target_type'], 'unit');
      expect(review['proposed_amount_minor'], 123456789);
      expect(review['active_contract_count_at_request'], 1);
      expect(review['active_contract_count_current'], 1);
      expect(snapshot['unit_number'], '101');
      expect(snapshot['unit_status_at_request'], 'مؤجرة');
      expect(snapshot['source'], 'current_master_data_at_request');
      expect(
        (await helper.getPropertySaleProperties())
            .single['active_contract_count'],
        1,
      );
      expect(
        (await helper.getPropertySaleUnits(
          ids['property_id']!,
        )).first['active_contract_count'],
        1,
      );

      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [ids['unit1_id']],
        )).single['status'],
        'مؤجرة',
      );
      expect(
        (await db.query(
          'contracts',
          where: 'id = ?',
          whereArgs: [ids['contract_id']],
        )).single['status'],
        'Active',
      );
      expect(
        (await db.query(
          'properties',
          where: 'id = ?',
          whereArgs: [ids['property_id']],
        )).single['owner_id'],
        ownerIdBefore,
      );
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
        ),
        journalEntriesBefore,
      );
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_lines'),
        ),
        journalLinesBefore,
      );
      expect(
        await db.rawQuery('SELECT id, balance FROM accounts ORDER BY id'),
        accountBalancesBefore,
      );
      expect(await helper.getPropertySaleReviewEvents(reviewId), hasLength(1));
      expect(
        (await db.query(
          'audit_logs',
          where: "action = 'property_sale_review_requested'",
        )),
        hasLength(1),
      );
    },
  );

  test(
    'database prevents overlapping open property and unit requests',
    () async {
      final db = await helper.database;
      final ids = await _seedPropertyWithUnits(db, activeOnUnit1: false);
      await helper.createPropertySaleReview(
        targetType: 'unit',
        propertyId: ids['property_id']!,
        unitId: ids['unit1_id'],
        reason: 'طلب الوحدة الأولى',
      );
      await helper.createPropertySaleReview(
        targetType: 'unit',
        propertyId: ids['property_id']!,
        unitId: ids['unit2_id'],
        reason: 'طلب الوحدة الثانية',
      );
      await expectLater(
        helper.createPropertySaleReview(
          targetType: 'property',
          propertyId: ids['property_id']!,
          reason: 'طلب العقار كاملًا أثناء وجود طلبات وحدات',
        ),
        throwsA(anything),
      );
      expect(await helper.getPropertySaleReviews(), hasLength(2));
    },
  );

  test(
    'approval requires review permission and accepted review remains non-financial',
    () async {
      final db = await helper.database;
      final ids = await _seedPropertyWithUnits(db, activeOnUnit1: false);
      final accountantId = await db.insert('users', {
        'username': 'sale_reviewer',
        'password_hash': 'test-hash',
        'full_name': 'مراجع البيع',
        'role': 'Accountant',
      });
      final reviewId = await helper.createPropertySaleReview(
        targetType: 'property',
        propertyId: ids['property_id']!,
        reason: 'طلب مراجعة العقار كاملًا',
      );
      final journalEntriesBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
      );
      final journalLinesBefore = _count(
        await db.rawQuery('SELECT COUNT(*) AS count FROM journal_lines'),
      );

      PermissionRuntime.activate(
        userId: 1,
        role: 'DataEntry',
        permissionRows: const [],
      );
      await expectLater(
        helper.reviewPropertySaleRequest(
          saleReviewId: reviewId,
          accept: true,
          reason: 'غير مخول',
        ),
        throwsA(isA<StateError>()),
      );

      PermissionRuntime.activate(
        userId: accountantId,
        role: 'Accountant',
        permissionRows: const [],
      );
      await helper.reviewPropertySaleRequest(
        saleReviewId: reviewId,
        accept: true,
        reason: 'تمت مراجعة المعلومات المقدمة يدويًا؛ لا يعني ذلك إتمام البيع.',
      );
      final accepted = (await helper.getPropertySaleReviews()).single;
      expect(accepted['status'], 'accepted');
      expect(accepted['reviewer_name'], 'مراجع البيع');
      expect(await helper.getPropertySaleReviewEvents(reviewId), hasLength(2));
      final forgedCancellationTime = DateTime.now().toIso8601String();
      await expectLater(
        db.update(
          'property_sale_reviews',
          {
            'status': 'cancelled',
            'reviewed_by': 1,
            'reviewed_at': forgedCancellationTime,
            'review_reason': 'تغيير غير مسموح لمبرر الاعتماد',
            'cancelled_by': 1,
            'cancelled_at': forgedCancellationTime,
            'cancel_reason': 'إلغاء مباشر لاختبار الحماية',
          },
          where: 'id = ?',
          whereArgs: [reviewId],
        ),
        throwsA(isA<DatabaseException>()),
      );
      final stillAccepted = (await helper.getPropertySaleReviews()).single;
      expect(stillAccepted['status'], 'accepted');
      expect(stillAccepted['reviewer_name'], 'مراجع البيع');
      expect(stillAccepted['review_reason'], accepted['review_reason']);
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_entries'),
        ),
        journalEntriesBefore,
      );
      expect(
        _count(
          await db.rawQuery('SELECT COUNT(*) AS count FROM journal_lines'),
        ),
        journalLinesBefore,
      );
      await expectLater(
        helper.createPropertySaleReview(
          targetType: 'property',
          propertyId: ids['property_id']!,
          reason: 'طلب متداخل بعد الاعتماد',
        ),
        throwsA(anything),
      );

      PermissionRuntime.activate(
        userId: 1,
        role: 'SuperAdmin',
        permissionRows: const [],
      );
      await helper.cancelPropertySaleReview(
        saleReviewId: reviewId,
        reason: 'أُغلق الطلب يدويًا بسبب تغيير توجيه المالك.',
      );
      expect(
        (await helper.getPropertySaleReviews()).single['status'],
        'cancelled',
      );
      expect(await helper.getPropertySaleReviewEvents(reviewId), hasLength(3));
      await helper.createPropertySaleReview(
        targetType: 'property',
        propertyId: ids['property_id']!,
        reason: 'طلب جديد بعد إلغاء موثق للطلب السابق',
      );
    },
  );

  test('request and event records cannot be deleted or rewritten', () async {
    final db = await helper.database;
    final ids = await _seedPropertyWithUnits(db, activeOnUnit1: false);
    final reviewId = await helper.createPropertySaleReview(
      targetType: 'unit',
      propertyId: ids['property_id']!,
      unitId: ids['unit1_id'],
      reason: 'طلب لاختبار ثبات السجل',
    );
    final eventId = (await db.query(
      'property_sale_review_events',
      columns: ['id'],
      where: 'sale_review_id = ?',
      whereArgs: [reviewId],
      limit: 1,
    )).single['id'];

    await expectLater(
      db.delete(
        'property_sale_reviews',
        where: 'id = ?',
        whereArgs: [reviewId],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.update(
        'property_sale_reviews',
        {'reason': 'تغيير غير مسموح'},
        where: 'id = ?',
        whereArgs: [reviewId],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.update(
        'property_sale_review_events',
        {'reason': 'تغيير غير مسموح'},
        where: 'id = ?',
        whereArgs: [eventId],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.delete(
        'property_sale_review_events',
        where: 'id = ?',
        whereArgs: [eventId],
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test(
    'v20 upgrades to v22, preserving permissions and default-denying review',
    () async {
      final db = await helper.database;
      await db.insert('user_permissions', {
        'user_id': 1,
        'screen_name': 'properties',
        'can_view': 1,
        'can_add': 1,
        'can_edit': 0,
        'can_delete': 0,
        'can_print': 0,
        'can_post': 0,
        'can_review_approve': 0,
      });
      await db.execute('DROP TABLE property_sale_review_events');
      await db.execute('DROP TABLE property_sale_reviews');
      await db.execute(
        'ALTER TABLE user_permissions DROP COLUMN can_review_approve',
      );
      await db.execute('PRAGMA user_version = 20');
      await helper.close();

      final upgraded = await helper.database;
      expect(_count(await upgraded.rawQuery('PRAGMA user_version')), 22);
      final permission = (await upgraded.query(
        'user_permissions',
        where: "user_id = 1 AND screen_name = 'properties'",
      )).single;
      expect(permission['can_view'], 1);
      expect(permission['can_add'], 1);
      expect(permission['can_review_approve'], 0);
      final tables = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(
        tables,
        containsAll(['property_sale_reviews', 'property_sale_review_events']),
      );
      expect(
        _count(
          await upgraded.rawQuery(
            'SELECT COUNT(*) AS count FROM property_sale_reviews',
          ),
        ),
        0,
        reason: 'ترحيل v20 لا يخمّن مبيعات تاريخية ولا ينشئ مراجعات آلية',
      );
    },
  );
}

int _count(List<Map<String, Object?>> rows) =>
    (rows.single.values.single as num).toInt();

Future<Map<String, int>> _seedPropertyWithUnits(
  Database db, {
  required bool activeOnUnit1,
}) async {
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final ownerId = await db.insert('owners', {'name': 'مالك اختبار $suffix'});
  final propertyId = await db.insert('properties', {
    'name': 'عقار اختبار $suffix',
    'owner_id': ownerId,
    'deed_number': 'DEED-$suffix',
  });
  final unit1Id = await db.insert('units', {
    'property_id': propertyId,
    'unit_number': '101',
    'status': activeOnUnit1 ? 'مؤجرة' : 'شاغرة',
  });
  final unit2Id = await db.insert('units', {
    'property_id': propertyId,
    'unit_number': '102',
    'status': 'شاغرة',
  });
  var contractId = 0;
  if (activeOnUnit1) {
    final tenantId = await db.insert('tenants', {
      'name': 'مستأجر اختبار $suffix',
    });
    contractId = await db.insert('contracts', {
      'tenant_id': tenantId,
      'unit_id': unit1Id,
      'start_date': '2026-01-01',
      'end_date': '2026-12-31',
      'rent_amount': 1200.00,
      'status': 'Active',
    });
  }
  return {
    'owner_id': ownerId,
    'property_id': propertyId,
    'unit1_id': unit1Id,
    'unit2_id': unit2Id,
    'contract_id': contractId,
  };
}
