import 'dart:convert';
import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/core/tenant_notice_pdf.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/providers/tenant_notices_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_notice_pdf_flutter_test';
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

  test('builds Arabic RTL PDF with company layout and multiple pages', () async {
    final bytes = await TenantNoticePdfBuilder.build(
      notice: {
        'id': 42,
        'status': 'Issued',
        'notice_date': '2026-11-19',
        'recipient_name_snapshot': 'المستأجر أحمد',
        'recipient_phone_snapshot': '777000111',
        'subject': 'تنبيه بخصوص الوحدة',
        'body': List.filled(
          220,
          'يرجى مراجعة بيانات العقد والتواصل مع الإدارة لإتمام الإجراء المطلوب.',
        ).join('\n'),
        'contract_snapshot_json': jsonEncode({
          'contract_id': 7,
          'property_name': 'العقار المحفوظ',
          'unit_number': '12-A',
          'start_date': '2026-01-01',
          'end_date': '2026-12-31',
          'party_snapshot_source': 'contract_party_snapshot',
          'property_name_source': 'contract_party_snapshot',
          'unit_number_source': 'contract_party_snapshot',
        }),
      },
      companyInfo: {
        'name_ar': 'شركة الاختبار العقارية',
        'name_en': 'Test Property Co.',
        'activity_name_ar': 'إدارة العقارات',
        'address_ar': 'صنعاء',
        'telephone': '777123456',
      },
    );

    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    final source = latin1.decode(bytes, allowInvalid: true);
    final pageCount = RegExp(r'/Type\s*/Page\b').allMatches(source).length;
    expect(pageCount, greaterThan(1));
    expect(bytes.length, greaterThan(10000));
  });

  test('PDF builder rejects drafts', () async {
    await expectLater(
      TenantNoticePdfBuilder.build(
        notice: {'id': 4, 'status': 'Draft'},
        companyInfo: null,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'provider allows issued PDF only with print permission and does not rewrite notice',
    () async {
      final tenantId = await (await helper.database).insert('tenants', {
        'name': 'مستأجر PDF',
      });
      final provider = TenantNoticesProvider();
      final id = await provider.createDraft(
        tenantId: tenantId,
        subject: 'إشعار PDF',
        body: 'يرجى مراجعة الإدارة.',
        noticeDate: '2026-11-19',
      );

      await expectLater(provider.buildPdf(id), throwsA(isA<StateError>()));
      await helper.issueTenantNotice(id);
      final issuedBefore = (await helper.getTenantNotice(id))!;
      final eventsBefore = await helper.getTenantNoticeEvents(id);
      final bytes = await provider.buildPdf(id);

      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final issuedAfter = (await helper.getTenantNotice(id))!;
      expect(issuedAfter['notice_date'], issuedBefore['notice_date']);
      expect(issuedAfter['status'], 'Issued');
      expect(
        (await helper.getTenantNoticeEvents(
          id,
        )).map((event) => event['event_type']),
        eventsBefore.map((event) => event['event_type']),
      );

      PermissionRuntime.activate(
        userId: 9,
        role: 'Accountant',
        permissionRows: [
          {
            'screen_name': 'notices',
            'can_view': 1,
            'can_add': 1,
            'can_edit': 1,
            'can_delete': 0,
            'can_print': 0,
            'can_post': 1,
          },
        ],
      );
      await expectLater(provider.buildPdf(id), throwsA(isA<StateError>()));
      provider.dispose();
    },
  );
}
