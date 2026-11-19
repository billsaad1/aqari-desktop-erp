import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/tenant_notice_docx.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test(
    'builds a valid RTL Word package with company logo and notice snapshot',
    () {
      final logoImage = image.Image(width: 8, height: 4);
      final logoBytes = Uint8List.fromList(image.encodePng(logoImage));
      final bytes = TenantNoticeDocxBuilder.build(
        notice: {
          'id': 42,
          'notice_date': '2026-11-19',
          'recipient_name_snapshot': 'المستأجر أحمد',
          'recipient_phone_snapshot': '777000111',
          'subject': 'تنبيه \u0001<مهم> & عاجل',
          'body': 'النص الأول & الثاني.\nيرجى المراجعة.',
          'contract_snapshot_json': jsonEncode({
            'contract_id': 7,
            'property_name': 'عقار & مبنى',
            'unit_number': '12-A',
            'start_date': '2026-01-01',
            'end_date': '2026-12-31',
            'party_snapshot_source': 'contract_party_snapshot',
            'property_name_source': 'contract_party_snapshot',
            'unit_number_source': 'contract_party_snapshot',
          }),
        },
        companyInfo: {
          'name_ar': 'شركة اختبار & تشغيل',
          'activity_name_ar': 'إدارة العقارات',
          'address_ar': 'صنعاء',
          'telephone': '777123456',
        },
        logoBytes: logoBytes,
      );

      final package = ZipDecoder().decodeBytes(bytes, verify: true);
      final files = package.files.map((file) => file.name).toSet();
      expect(
        files,
        containsAll([
          '[Content_Types].xml',
          '_rels/.rels',
          'word/document.xml',
          'word/styles.xml',
          'word/_rels/document.xml.rels',
          'word/media/company-logo.png',
        ]),
      );
      final document = utf8.decode(
        package.files
            .firstWhere((file) => file.name == 'word/document.xml')
            .content,
      );
      final relationships = utf8.decode(
        package.files
            .firstWhere((file) => file.name == 'word/_rels/document.xml.rels')
            .content,
      );
      expect(document, contains('w:bidi'));
      expect(document, contains('w:rtl'));
      expect(document, contains('w:jc w:val="right"'));
      expect(document, contains('w:rFonts w:ascii="Cairo"'));
      expect(document, contains('إشعار'));
      expect(document, contains('المستأجر أحمد'));
      expect(document, contains('لقطة العقد عند إنشائه'));
      expect(document, contains('رقم الوحدة: لقطة العقد عند إنشائه'));
      expect(document, contains('تنبيه &lt;مهم&gt; &amp; عاجل'));
      expect(document, contains('\u206612-A\u2069'));
      expect(document, isNot(contains('\u0001')));
      expect(document, contains('عقار &amp; مبنى'));
      expect(document, isNot(contains('&amp;amp;')));
      expect(document, contains('rIdLogo'));
      expect(relationships, contains('Target="media/company-logo.png"'));
    },
  );

  test('malformed optional contract snapshot does not break Word export', () {
    final bytes = TenantNoticeDocxBuilder.build(
      notice: {
        'id': 9,
        'notice_date': '2026-11-19',
        'recipient_name_snapshot': 'مستأجر',
        'subject': 'موضوع',
        'body': 'نص الإشعار',
        'contract_snapshot_json': '{bad json',
      },
      companyInfo: {'name_ar': 'مؤسسة الاختبار'},
      logoBytes: Uint8List.fromList([0, 1, 2]),
    );
    final package = ZipDecoder().decodeBytes(bytes);
    final document = utf8.decode(
      package.files
          .firstWhere((file) => file.name == 'word/document.xml')
          .content,
    );
    final relationships = utf8.decode(
      package.files
          .firstWhere((file) => file.name == 'word/_rels/document.xml.rels')
          .content,
    );
    expect(document, contains('مؤسسة الاختبار'));
    expect(document, isNot(contains('rIdLogo')));
    expect(relationships, isNot(contains('company-logo.png')));
    expect(
      package.files.any((file) => file.name == 'word/media/company-logo.png'),
      isFalse,
    );
  });

  test('Word export discloses a partial historical contract snapshot', () {
    final bytes = TenantNoticeDocxBuilder.build(
      notice: {
        'id': 10,
        'notice_date': '2026-11-19',
        'recipient_name_snapshot': 'مستأجر',
        'subject': 'موضوع',
        'body': 'نص الإشعار',
        'contract_snapshot_json': jsonEncode({
          'contract_id': 12,
          'property_name': 'عقار محفوظ',
          'unit_number': '12-B',
          'party_snapshot_source': 'partial_contract_party_snapshot',
          'property_name_source': 'contract_party_snapshot',
          'unit_number_source': 'current_master_data_at_notice_creation',
        }),
      },
      companyInfo: {'name_ar': 'مؤسسة الاختبار'},
    );
    final package = ZipDecoder().decodeBytes(bytes);
    final document = utf8.decode(
      package.files
          .firstWhere((file) => file.name == 'word/document.xml')
          .content,
    );
    expect(document, contains('لقطة العقد جزئية'));
    expect(document, contains('رقم الوحدة: السجل الحالي وقت إعداد الإشعار'));
  });
}
