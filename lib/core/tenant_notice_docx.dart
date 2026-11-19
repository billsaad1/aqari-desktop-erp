import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

/// Builds a minimal Office Open XML Word document for a saved tenant notice.
/// The output is a real DOCX package (ZIP with WordprocessingML parts).
class TenantNoticeDocxBuilder {
  TenantNoticeDocxBuilder._();

  static const String _wordNamespace =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const String _relationshipsNamespace =
      'http://schemas.openxmlformats.org/package/2006/relationships';

  static Uint8List build({
    required Map<String, dynamic> notice,
    required Map<String, dynamic> companyInfo,
    Uint8List? logoBytes,
  }) {
    final logo = _normalizeLogo(logoBytes);
    final archive = Archive();

    void addText(String name, String content) {
      archive.addFile(ArchiveFile.string(name, content));
    }

    addText('[Content_Types].xml', _contentTypesXml);
    addText('_rels/.rels', _packageRelationshipsXml);
    addText('docProps/core.xml', _corePropertiesXml(notice, companyInfo));
    addText('word/styles.xml', _stylesXml);
    addText(
      'word/_rels/document.xml.rels',
      _documentRelationshipsXml(hasLogo: logo != null),
    );
    addText('word/document.xml', _documentXml(notice, companyInfo, logo: logo));
    if (logo != null) {
      archive.addFile(
        ArchiveFile('word/media/company-logo.png', logo.length, logo),
      );
    }

    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  static Uint8List? _normalizeLogo(Uint8List? bytes) {
    if (bytes == null) return null;
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
    try {
      final decoded = image.decodeImage(bytes);
      if (decoded == null || decoded.width * decoded.height > 24000000) {
        return null;
      }
      return Uint8List.fromList(image.encodePng(decoded));
    } catch (_) {
      return null;
    }
  }

  static String _documentXml(
    Map<String, dynamic> notice,
    Map<String, dynamic> companyInfo, {
    required Uint8List? logo,
  }) {
    final companyName = _value(companyInfo, const ['name_ar']);
    final companyActivity = _value(companyInfo, const [
      'activity_name_ar',
      'activity',
    ]);
    final address = _value(companyInfo, const ['address_ar', 'address']);
    final telephone = _value(companyInfo, const ['telephone', 'mobile']);
    final noticeId = notice['id']?.toString() ?? '—';
    final noticeDate = notice['notice_date']?.toString() ?? '';
    final recipientName = notice['recipient_name_snapshot']?.toString() ?? '';
    final recipientPhone = notice['recipient_phone_snapshot']?.toString() ?? '';
    final subject = notice['subject']?.toString() ?? '';
    final body = notice['body']?.toString() ?? '';
    final contract = _readContractSnapshot(notice['contract_snapshot_json']);

    final paragraphs = <String>[
      if (logo != null) _logoParagraph(logo),
      if (companyName.isNotEmpty)
        _paragraph(companyName, bold: true, size: 30, alignment: 'center'),
      if (companyActivity.isNotEmpty && companyActivity != companyName)
        _paragraph(companyActivity, size: 22, alignment: 'center'),
      if (address.isNotEmpty || telephone.isNotEmpty)
        _paragraph(
          [
            address,
            if (telephone.isNotEmpty) 'هاتف: $telephone',
          ].where((value) => value.isNotEmpty).join('  |  '),
          size: 20,
          alignment: 'center',
        ),
      _ruleParagraph,
      _paragraph(
        'إشعار',
        bold: true,
        size: 32,
        alignment: 'center',
        after: 300,
      ),
      _paragraph('رقم الإشعار: $noticeId     التاريخ: $noticeDate', size: 23),
      _paragraph('إلى: $recipientName', bold: true, size: 25),
      if (recipientPhone.isNotEmpty)
        _paragraph('رقم التواصل: $recipientPhone', size: 22),
      if (contract != null) ...[
        _paragraph(_contractSourceDisclosure(contract), size: 20, after: 80),
        if ((contract['property_name']?.toString() ?? '').isNotEmpty ||
            (contract['unit_number']?.toString() ?? '').isNotEmpty)
          _paragraph(
            'العقار/الوحدة: ${contract['property_name']?.toString() ?? ''}'
            '${(contract['unit_number']?.toString() ?? '').isEmpty ? '' : ' — الوحدة ${_ltr(contract['unit_number'])}'}',
            size: 22,
          ),
        if ((contract['contract_id']?.toString() ?? '').isNotEmpty ||
            (contract['start_date']?.toString() ?? '').isNotEmpty ||
            (contract['end_date']?.toString() ?? '').isNotEmpty)
          _paragraph(
            'العقد: ${_ltr(contract['contract_id'])}'
            '${(contract['start_date']?.toString() ?? '').isEmpty ? '' : ' — من ${contract['start_date']}'}'
            '${(contract['end_date']?.toString() ?? '').isEmpty ? '' : ' إلى ${contract['end_date']}'}',
            size: 22,
          ),
      ],
      _paragraph(
        'الموضوع: $subject',
        bold: true,
        size: 25,
        before: 180,
        after: 180,
      ),
      ..._bodyParagraphs(body),
      _paragraph('وتفضلوا بقبول فائق الاحترام،', size: 23, before: 320),
      if (companyName.isNotEmpty)
        _paragraph(
          companyName,
          bold: true,
          size: 24,
          alignment: 'right',
          before: 220,
        ),
      _paragraph('التوقيع: ____________________', size: 22, before: 160),
    ];

    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="$_wordNamespace" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>${paragraphs.join()}
    <w:sectPr>
      <w:bidi/>
      <w:pgSz w:w="11906" w:h="16838"/>
      <w:pgMar w:top="1020" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>''';
  }

  static List<String> _bodyParagraphs(String body) {
    final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return normalized
        .split('\n')
        .map((line) => _paragraph(line, size: 24, after: 150))
        .toList();
  }

  static String _paragraph(
    String text, {
    bool bold = false,
    int size = 24,
    String alignment = 'right',
    int before = 0,
    int after = 120,
  }) {
    final boldXml = bold ? '<w:b/><w:bCs/>' : '';
    return '''
    <w:p>
      <w:pPr><w:bidi/><w:jc w:val="$alignment"/><w:spacing w:before="$before" w:after="$after"/></w:pPr>
      <w:r><w:rPr><w:rFonts w:ascii="Cairo" w:hAnsi="Cairo" w:eastAsia="Cairo" w:cs="Cairo"/><w:rtl/><w:lang w:val="ar-SA" w:bidi="ar-SA"/><w:sz w:val="$size"/><w:szCs w:val="$size"/>$boldXml</w:rPr><w:t xml:space="preserve">${_escape(text)}</w:t></w:r>
    </w:p>''';
  }

  static String _logoParagraph(Uint8List bytes) {
    final decoded = image.decodePng(bytes);
    if (decoded == null) return '';
    const maxExtent = 660000;
    final ratio = decoded.width / decoded.height;
    final cx = ratio >= 1 ? maxExtent : (maxExtent * ratio).round();
    final cy = ratio >= 1 ? (maxExtent / ratio).round() : maxExtent;
    return '''
    <w:p>
      <w:pPr><w:jc w:val="center"/><w:spacing w:after="80"/></w:pPr>
      <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
        <wp:extent cx="$cx" cy="$cy"/><wp:docPr id="1" name="company-logo"/>
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="company-logo.png"/><pic:cNvPicPr/></pic:nvPicPr>
            <pic:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
          </pic:pic>
        </a:graphicData></a:graphic>
      </wp:inline></w:drawing></w:r>
    </w:p>''';
  }

  static Map<String, dynamic>? _readContractSnapshot(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _value(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _ltr(Object? value) => '\u2066${value?.toString() ?? ''}\u2069';

  static String _contractSourceDisclosure(Map<String, dynamic> contract) {
    String sourceLabel(Object? source) => source == 'contract_party_snapshot'
        ? 'لقطة العقد عند إنشائه'
        : 'السجل الحالي وقت إعداد الإشعار';

    final isPartial =
        contract['party_snapshot_source'] == 'partial_contract_party_snapshot';
    return '${isPartial ? 'لقطة العقد جزئية. ' : ''}'
        'مصدر اسم العقار: ${sourceLabel(contract['property_name_source'])}؛ '
        'رقم الوحدة: ${sourceLabel(contract['unit_number_source'])}؛ '
        'المستأجر: سجله وقت إعداد الإشعار؛ تواريخ/حالة العقد: سجله الحالي.';
  }

  static String _escape(String text) {
    final xmlSafe = String.fromCharCodes(
      text.runes.where(
        (rune) =>
            rune == 0x9 ||
            rune == 0xA ||
            rune == 0xD ||
            (rune >= 0x20 && rune <= 0xD7FF) ||
            (rune >= 0xE000 && rune <= 0xFFFD) ||
            (rune >= 0x10000 && rune <= 0x10FFFF),
      ),
    );
    return xmlSafe
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static const String _ruleParagraph = '''
    <w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="100" w:after="180"/><w:pBdr><w:bottom w:val="single" w:sz="10" w:space="1" w:color="1B2A41"/></w:pBdr></w:pPr><w:r><w:t xml:space="preserve"> </w:t></w:r></w:p>''';

  static const String _contentTypesXml =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>''';

  static const String _packageRelationshipsXml =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="$_relationshipsNamespace">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>''';

  static const String _stylesXml =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="$_wordNamespace">
  <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Cairo" w:hAnsi="Cairo" w:eastAsia="Cairo" w:cs="Cairo"/><w:lang w:val="ar-SA" w:bidi="ar-SA"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:bidi/></w:pPr></w:pPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:pPr><w:bidi/><w:spacing w:after="120"/></w:pPr><w:rPr><w:rFonts w:ascii="Cairo" w:hAnsi="Cairo" w:eastAsia="Cairo" w:cs="Cairo"/><w:sz w:val="24"/><w:szCs w:val="24"/><w:rtl/><w:lang w:val="ar-SA" w:bidi="ar-SA"/></w:rPr></w:style>
</w:styles>''';

  static String _documentRelationshipsXml({required bool hasLogo}) =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="$_relationshipsNamespace">
  <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  ${hasLogo ? '<Relationship Id="rIdLogo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/company-logo.png"/>' : ''}
</Relationships>''';

  static String _corePropertiesXml(
    Map<String, dynamic> notice,
    Map<String, dynamic> companyInfo,
  ) =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>${_escape(notice['subject']?.toString() ?? 'إشعار مستأجر')}</dc:title>
  <dc:creator>${_escape(companyInfo['name_ar']?.toString() ?? 'Aqari')}</dc:creator>
</cp:coreProperties>''';
}
