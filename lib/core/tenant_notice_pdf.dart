import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'print_utils.dart';

/// Builds the printable Arabic PDF for an issued tenant notice.
class TenantNoticePdfBuilder {
  TenantNoticePdfBuilder._();

  static Future<Uint8List> build({
    required Map<String, dynamic> notice,
    required Map<String, dynamic>? companyInfo,
  }) async {
    if (notice['status'] != 'Issued') {
      throw StateError('يجب إصدار الإشعار قبل إنشاء ملف PDF');
    }

    final theme = await PrintUtils.loadArabicTheme();
    final pdf = pw.Document();
    final id = notice['id']?.toString() ?? '—';
    final noticeDate = notice['notice_date']?.toString() ?? '';
    final recipientName = notice['recipient_name_snapshot']?.toString() ?? '';
    final recipientPhone = notice['recipient_phone_snapshot']?.toString() ?? '';
    final subject = notice['subject']?.toString() ?? '';
    final body = notice['body']?.toString() ?? '';
    final companyName =
        _firstNonEmpty(companyInfo?['name_ar']) ?? 'إدارة العقارات';
    final contract = _readContractSnapshot(notice['contract_snapshot_json']);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(34, 28, 34, 34),
        ),
        maxPages: 100,
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            PrintUtils.buildHeader(companyInfo, false),
            if (context.pageNumber > 1) _documentTitle('إشعار مستأجر — تابع'),
          ],
        ),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          _documentTitle('إشعار مستأجر'),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: _metadataItem('رقم الإشعار', id, pw.TextDirection.ltr),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: _metadataItem(
                    'تاريخ الإشعار',
                    noticeDate,
                    pw.TextDirection.ltr,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          _sectionTitle('بيانات المستأجر'),
          pw.SizedBox(height: 5),
          _informationCard([
            _labelValue('إلى', recipientName, bold: true),
            if (recipientPhone.trim().isNotEmpty)
              _labelValue(
                'رقم التواصل',
                recipientPhone,
                valueDirection: PrintUtils.resolveTextDirection(recipientPhone),
              ),
          ]),
          if (contract != null) ...[
            pw.SizedBox(height: 9),
            _sectionTitle('العقد المرتبط'),
            pw.SizedBox(height: 5),
            _informationCard(_contractFields(contract)),
          ],
          pw.SizedBox(height: 12),
          _sectionTitle('موضوع الإشعار'),
          pw.SizedBox(height: 5),
          _informationCard([_labelValue('الموضوع', subject, bold: true)]),
          pw.SizedBox(height: 12),
          _sectionTitle('نص الإشعار'),
          pw.SizedBox(height: 6),
          ..._bodyParagraphs(body),
          pw.SizedBox(height: 18),
          pw.Text(
            'وتفضلوا بقبول فائق الاحترام،',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.start,
            style: const pw.TextStyle(fontSize: 11, lineSpacing: 2),
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            companyName,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.start,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 20),
          pw.Text(
            'التوقيع: ____________________',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.start,
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );

    return pdf.save();
  }

  static pw.Widget _documentTitle(String title) => pw.Center(
    child: pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 6),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(
            title,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 17,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Container(width: 70, height: 2, color: PrintUtils.brandEmerald),
        ],
      ),
    ),
  );

  static pw.Widget _metadataItem(
    String label,
    String value,
    pw.TextDirection direction,
  ) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Text(
        label,
        textDirection: pw.TextDirection.rtl,
        textAlign: pw.TextAlign.center,
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        value,
        textDirection: direction,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PrintUtils.brandNavy,
        ),
      ),
    ],
  );

  static pw.Widget _sectionTitle(String title) => pw.Container(
    padding: const pw.EdgeInsets.only(left: 3, right: 4, bottom: 4),
    decoration: const pw.BoxDecoration(
      border: pw.Border(
        bottom: pw.BorderSide(color: PrintUtils.brandEmerald, width: 1),
      ),
    ),
    child: pw.Text(
      title,
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.start,
      style: pw.TextStyle(
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
        color: PrintUtils.brandNavy,
      ),
    ),
  );

  static pw.Widget _informationCard(List<pw.Widget> fields) => pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: pw.BoxDecoration(
      color: PrintUtils.softSurface,
      border: pw.Border.all(color: PrintUtils.softBorder),
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: fields,
    ),
  );

  static pw.Widget _labelValue(
    String label,
    String value, {
    pw.TextDirection valueDirection = pw.TextDirection.rtl,
    bool bold = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 105,
          child: pw.Text(
            '$label:',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.start,
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ),
        pw.SizedBox(width: 7),
        pw.Expanded(
          child: pw.Text(
            value,
            textDirection: valueDirection,
            textAlign: valueDirection == pw.TextDirection.rtl
                ? pw.TextAlign.start
                : pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      ],
    ),
  );

  static List<pw.Widget> _contractFields(Map<String, dynamic> contract) {
    String value(String key) => contract[key]?.toString() ?? '';
    final sourceDisclosure = _contractSourceDisclosure(contract);
    return [
      if (sourceDisclosure.isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(
            sourceDisclosure,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.start,
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
      if (value('property_name').isNotEmpty)
        _labelValue('العقار', value('property_name')),
      if (value('unit_number').isNotEmpty)
        _labelValue(
          'الوحدة',
          value('unit_number'),
          valueDirection: pw.TextDirection.ltr,
        ),
      if (value('contract_id').isNotEmpty)
        _labelValue(
          'رقم العقد',
          value('contract_id'),
          valueDirection: pw.TextDirection.ltr,
        ),
      if (value('start_date').isNotEmpty || value('end_date').isNotEmpty)
        _labelValue(
          'مدة العقد',
          '${value('start_date')}${value('end_date').isEmpty ? '' : ' — ${value('end_date')}'}',
          valueDirection: pw.TextDirection.ltr,
        ),
    ];
  }

  static List<pw.Widget> _bodyParagraphs(String body) {
    final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return normalized
        .split('\n')
        .map((line) {
          if (line.isEmpty) return pw.SizedBox(height: 6);
          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Text(
              line,
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.start,
              style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3),
            ),
          );
        })
        .toList(growable: false);
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

  static String _contractSourceDisclosure(Map<String, dynamic> contract) {
    String sourceLabel(Object? source) => source == 'contract_party_snapshot'
        ? 'لقطة العقد عند إنشائه'
        : 'السجل الحالي وقت إعداد الإشعار';

    final hasSourceFields =
        contract.containsKey('property_name_source') ||
        contract.containsKey('unit_number_source') ||
        contract.containsKey('party_snapshot_source');
    if (!hasSourceFields) return '';
    final isPartial =
        contract['party_snapshot_source'] == 'partial_contract_party_snapshot';
    return '${isPartial ? 'لقطة العقد جزئية. ' : ''}'
        'مصدر اسم العقار: ${sourceLabel(contract['property_name_source'])}؛ '
        'رقم الوحدة: ${sourceLabel(contract['unit_number_source'])}؛ '
        'المستأجر: سجله وقت إعداد الإشعار؛ تواريخ/حالة العقد: سجله الحالي.';
  }

  static String? _firstNonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
