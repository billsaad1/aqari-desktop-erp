import 'dart:convert';
import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_notice_flutter_test';
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
    final staleDirectory = Directory(testDocuments);
    if (await staleDirectory.exists()) {
      await staleDirectory.delete(recursive: true);
    }
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

  test(
    'notice roles are independently authorized and never grant delete by default',
    () {
      expect(
        AppPermissionCatalog.roleAllows(
          'Accountant',
          'notices',
          AppPermissionAction.view,
        ),
        isTrue,
      );
      for (final action in [
        AppPermissionAction.add,
        AppPermissionAction.edit,
        AppPermissionAction.print,
        AppPermissionAction.post,
      ]) {
        expect(
          AppPermissionCatalog.roleAllows('Accountant', 'notices', action),
          isTrue,
        );
      }
      expect(
        AppPermissionCatalog.roleAllows(
          'Accountant',
          'notices',
          AppPermissionAction.delete,
        ),
        isFalse,
      );
      expect(
        AppPermissionCatalog.roleAllows(
          'DataEntry',
          'notices',
          AppPermissionAction.view,
        ),
        isFalse,
      );
      expect(AppPermissionCatalog.codeForNavigationIndex(11), 'notices');
    },
  );

  test('database APIs enforce notice permissions for direct callers', () async {
    PermissionRuntime.activate(
      userId: 45,
      role: 'DataEntry',
      permissionRows: [
        {
          'screen_name': 'notices',
          'can_view': 0,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 0,
          'can_post': 0,
        },
      ],
    );
    await expectLater(helper.getTenantNotices(), throwsA(isA<StateError>()));
    await expectLater(
      helper.getTenantNoticeRecipients(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      helper.createTenantNoticeDraft(
        tenantId: 1,
        subject: 'غير مصرح',
        body: 'محاولة مباشرة من طبقة البيانات',
        noticeDate: '2026-11-19',
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      helper.updateTenantNoticeDraft(
        noticeId: 1,
        tenantId: 1,
        subject: 'غير مصرح',
        body: 'محاولة تعديل مباشرة',
        noticeDate: '2026-11-19',
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(helper.issueTenantNotice(1), throwsA(isA<StateError>()));
    await expectLater(
      helper.recordTenantNoticeWordExport(noticeId: 1, fileName: 'notice.docx'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'draft snapshots, issue lock, immutable history and export audit do not affect finance',
    () async {
      final db = await helper.database;
      final tenantId = await db.insert('tenants', {
        'name': 'المستأجر قبل التعديل',
        'mobile': '777000111',
      });
      final journalCountBefore = _firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM journal_entries'),
      );
      final installmentCountBefore = _firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM contract_installments'),
      );
      final voucherCountBefore = _firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM vouchers'),
      );
      final smsCountBefore = _firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM sms_logs'),
      );

      await expectLater(
        helper.createTenantNoticeDraft(
          tenantId: tenantId,
          subject: 'تاريخ غير صالح',
          body: 'لا ينبغي حفظ هذا الإشعار.',
          noticeDate: '2026-02-30',
        ),
        throwsA(isA<ArgumentError>()),
      );

      final noticeId = await helper.createTenantNoticeDraft(
        tenantId: tenantId,
        subject: 'إشعار تجريبي',
        body: 'يرجى التواصل مع الإدارة.',
        noticeDate: '2026-11-19',
      );
      final original = (await helper.getTenantNotice(noticeId))!;
      expect(original['status'], 'Draft');
      expect(original['recipient_name_snapshot'], 'المستأجر قبل التعديل');
      expect(original['recipient_phone_snapshot'], '777000111');

      await db.update(
        'tenants',
        {'name': 'المستأجر بعد التعديل', 'mobile': '777999000'},
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      expect(
        (await helper.getTenantNotice(noticeId))!['recipient_name_snapshot'],
        'المستأجر قبل التعديل',
      );

      await helper.updateTenantNoticeDraft(
        noticeId: noticeId,
        tenantId: tenantId,
        subject: 'إشعار بعد مراجعة المسودة',
        body: 'النص المعتمد بعد التعديل.',
        noticeDate: '2026-11-20',
      );
      final updatedDraft = (await helper.getTenantNotice(noticeId))!;
      expect(updatedDraft['recipient_name_snapshot'], 'المستأجر بعد التعديل');
      expect(updatedDraft['subject'], 'إشعار بعد مراجعة المسودة');
      expect(updatedDraft['notice_date'], '2026-11-20');

      await helper.issueTenantNotice(noticeId);
      final issued = (await helper.getTenantNotice(noticeId))!;
      expect(issued['status'], 'Issued');
      expect(issued['issued_at'], isNotNull);
      await expectLater(
        helper.issueTenantNotice(noticeId),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        helper.updateTenantNoticeDraft(
          noticeId: noticeId,
          tenantId: tenantId,
          subject: 'محاولة تعديل بعد الإصدار',
          body: 'غير مسموح',
          noticeDate: '2026-11-21',
        ),
        throwsA(isA<StateError>()),
      );

      await helper.recordTenantNoticeWordExport(
        noticeId: noticeId,
        fileName: 'notice_1.docx',
      );
      final events = await helper.getTenantNoticeEvents(noticeId);
      expect(events.map((event) => event['event_type']), [
        'draft_created',
        'draft_updated',
        'issued',
        'word_exported',
      ]);
      expect(
        jsonDecode(events.last['details'] as String)['file_name'],
        'notice_1.docx',
      );

      await expectLater(
        db.update(
          'tenant_notices',
          {'subject': 'تعديل مباشر غير مسموح'},
          where: 'id = ?',
          whereArgs: [noticeId],
        ),
        throwsA(anything),
      );
      await expectLater(
        db.delete('tenant_notices', where: 'id = ?', whereArgs: [noticeId]),
        throwsA(anything),
      );
      await expectLater(
        db.update(
          'tenant_notice_events',
          {'event_type': 'rewritten'},
          where: 'id = ?',
          whereArgs: [events.first['id']],
        ),
        throwsA(anything),
      );
      await expectLater(
        db.delete(
          'tenant_notice_events',
          where: 'id = ?',
          whereArgs: [events.first['id']],
        ),
        throwsA(anything),
      );

      expect(
        _firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM journal_entries'),
        ),
        journalCountBefore,
      );
      expect(
        _firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM contract_installments'),
        ),
        installmentCountBefore,
      );
      expect(
        _firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM vouchers')),
        voucherCountBefore,
      );
      expect(
        _firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM sms_logs')),
        smsCountBefore,
      );
    },
  );

  test(
    'contract links are tenant-scoped and use historical contract snapshots',
    () async {
      final db = await helper.database;
      final tenantA = await db.insert('tenants', {'name': 'مستأجر أ'});
      final tenantB = await db.insert('tenants', {'name': 'مستأجر ب'});
      final ownerId = await db.insert('owners', {'name': 'مالك للاختبار'});
      final propertyId = await db.insert('properties', {
        'name': 'العقار التجريبي',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': '12-A',
      });
      final contractId = await db.insert('contracts', {
        'tenant_id': tenantA,
        'unit_id': unitId,
        'start_date': '2026-01-01',
        'end_date': '2026-12-31',
        'rent_amount': 1200.0,
        'status': 'Active',
        'party_snapshot': jsonEncode({
          'tenant': {'name': 'مستأجر أ وقت العقد'},
          'owner': {'name': 'مالك وقت العقد'},
          'property': {'name': 'العقار وقت العقد'},
          'unit': {'unit_number': '12-A'},
        }),
      });

      await expectLater(
        helper.createTenantNoticeDraft(
          tenantId: tenantB,
          contractId: contractId,
          subject: 'طلب غير صحيح',
          body: 'العقد يخص مستأجرًا آخر.',
          noticeDate: '2026-11-19',
        ),
        throwsA(isA<ArgumentError>()),
      );
      await db.update(
        'properties',
        {'name': 'العقار بعد العقد'},
        where: 'id = ?',
        whereArgs: [propertyId],
      );
      await db.update(
        'units',
        {'unit_number': '12-B'},
        where: 'id = ?',
        whereArgs: [unitId],
      );
      final linkedId = await helper.createTenantNoticeDraft(
        tenantId: tenantA,
        contractId: contractId,
        subject: 'تنبيه مرتبط بالعقد',
        body: 'مراجعة بيانات الوحدة.',
        noticeDate: '2026-11-19',
      );
      final linked = (await helper.getTenantNotice(linkedId))!;
      final contractSnapshot =
          jsonDecode(linked['contract_snapshot_json'] as String)
              as Map<String, dynamic>;
      expect(contractSnapshot['contract_id'], contractId);
      expect(contractSnapshot['property_name'], 'العقار وقت العقد');
      expect(contractSnapshot['unit_number'], '12-A');
      expect(contractSnapshot['contract_tenant_name'], 'مستأجر أ وقت العقد');
      expect(
        contractSnapshot['party_snapshot_source'],
        'contract_party_snapshot',
      );
      expect(
        contractSnapshot['property_name_source'],
        'contract_party_snapshot',
      );
      expect(contractSnapshot['unit_number_source'], 'contract_party_snapshot');

      final legacyContractId = await db.insert('contracts', {
        'tenant_id': tenantA,
        'unit_id': unitId,
        'start_date': '2025-01-01',
        'end_date': '2025-12-31',
        'rent_amount': 1000.0,
        'status': 'Cancelled',
      });
      final legacyNoticeId = await helper.createTenantNoticeDraft(
        tenantId: tenantA,
        contractId: legacyContractId,
        subject: 'عقد قديم',
        body: 'لا توجد لقطة تاريخية لهذا العقد.',
        noticeDate: '2026-11-19',
      );
      final legacyNotice = (await helper.getTenantNotice(legacyNoticeId))!;
      final legacySnapshot =
          jsonDecode(legacyNotice['contract_snapshot_json'] as String)
              as Map<String, dynamic>;
      expect(legacySnapshot['property_name'], 'العقار بعد العقد');
      expect(legacySnapshot['unit_number'], '12-B');
      expect(
        legacySnapshot['party_snapshot_source'],
        'current_master_data_at_notice_creation',
      );
      expect(
        legacySnapshot['property_name_source'],
        'current_master_data_at_notice_creation',
      );
      expect(
        legacySnapshot['unit_number_source'],
        'current_master_data_at_notice_creation',
      );

      final partialContractId = await db.insert('contracts', {
        'tenant_id': tenantA,
        'unit_id': unitId,
        'start_date': '2024-01-01',
        'end_date': '2024-12-31',
        'rent_amount': 900.0,
        'status': 'Cancelled',
        'party_snapshot': jsonEncode({
          'property': {'name': 'العقار المحفوظ جزئيًا'},
        }),
      });
      final partialNoticeId = await helper.createTenantNoticeDraft(
        tenantId: tenantA,
        contractId: partialContractId,
        subject: 'لقطة جزئية',
        body: 'تمييز مصدر البيانات.',
        noticeDate: '2026-11-19',
      );
      final partialNotice = (await helper.getTenantNotice(partialNoticeId))!;
      final partialSnapshot =
          jsonDecode(partialNotice['contract_snapshot_json'] as String)
              as Map<String, dynamic>;
      expect(
        partialSnapshot['party_snapshot_source'],
        'partial_contract_party_snapshot',
      );
      expect(partialSnapshot['property_name'], 'العقار المحفوظ جزئيًا');
      expect(partialSnapshot['unit_number'], '12-B');
      expect(
        partialSnapshot['property_name_source'],
        'contract_party_snapshot',
      );
      expect(
        partialSnapshot['unit_number_source'],
        'current_master_data_at_notice_creation',
      );
    },
  );

  test(
    'v19 database upgrades with notice tables and immutable triggers',
    () async {
      final db = await helper.database;
      final tenantId = await db.insert('tenants', {
        'name': 'مستأجر موجود قبل الترحيل',
      });
      await db.execute('DROP TABLE tenant_notice_events');
      await db.execute('DROP TABLE tenant_notices');
      await db.execute('PRAGMA user_version = 19');
      await helper.close();

      final upgraded = await helper.database;
      expect(
        _firstIntValue(await upgraded.rawQuery('PRAGMA user_version')),
        21,
      );
      expect(
        (await upgraded.query(
          'tenants',
          where: 'id = ?',
          whereArgs: [tenantId],
        )).single['name'],
        'مستأجر موجود قبل الترحيل',
      );
      final tables = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(tables, containsAll(['tenant_notices', 'tenant_notice_events']));
      final triggers = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger'",
      )).map((row) => row['name']).toSet();
      expect(
        triggers,
        containsAll([
          'tenant_notices_issued_immutable',
          'tenant_notices_no_delete',
          'tenant_notice_events_no_update',
          'tenant_notice_events_no_delete',
        ]),
      );
    },
  );
}

int _firstIntValue(List<Map<String, Object?>> rows) =>
    (rows.single.values.single as num).toInt();
