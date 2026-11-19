import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'print_utils.dart';

class PropertyUnitInquiryPdf {
  PropertyUnitInquiryPdf._();

  static Future<Uint8List> build({
    required Map<String, dynamic>? companyInfo,
    required Map<String, dynamic> property,
    required List<Map<String, dynamic>> units,
    required DateTime generatedAt,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final generatedAtText = DateFormat(
      'yyyy-MM-dd HH:mm',
      'en_US',
    ).format(generatedAt);
    final unitRows = units
        .map(
          (unit) => [
            unit['unit_number']?.toString() ?? '',
            unit['status']?.toString().trim().isNotEmpty == true
                ? unit['status'].toString()
                : 'غير محددة',
            ((unit['active_contract_count'] as num?)?.toInt() ?? 0).toString(),
          ],
        )
        .toList();

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, false),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'استعلام العقار والوحدات',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
                color: PrintUtils.brandNavy,
              ),
            ),
          ),
          pw.SizedBox(height: 10),
          PrintUtils.buildLabelValue(
            'اسم العقار',
            property['name']?.toString() ?? '',
            labelWidth: 86,
            fontSize: 10,
          ),
          PrintUtils.buildLabelValue(
            'وقت الاستعلام',
            generatedAtText,
            valueDirection: pw.TextDirection.ltr,
            labelWidth: 86,
            fontSize: 9,
          ),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: const ['رقم الوحدة', 'الحالة الحالية', 'العقود النشطة'],
            data: unitRows,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            headerPadding: const pw.EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 8,
            ),
            headerDirection: pw.TextDirection.rtl,
            cellStyle: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 7,
            ),
            tableDirection: pw.TextDirection.rtl,
            cellBuilder: (index, value, _) => pw.Text(
              value?.toString() ?? '',
              textDirection: index == 0
                  ? pw.TextDirection.ltr
                  : PrintUtils.resolveTextDirection(value?.toString() ?? ''),
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 9),
            ),
            columnWidths: const {
              0: pw.FlexColumnWidth(1.5),
              1: pw.FlexColumnWidth(2),
              2: pw.FlexColumnWidth(1.4),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            oddRowDecoration: pw.BoxDecoration(color: PrintUtils.softSurface),
            cellAlignments: const {
              0: pw.Alignment.center,
              1: pw.Alignment.center,
              2: pw.Alignment.center,
            },
          ),
          if (units.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(14),
              child: pw.Text(
                'لا توجد وحدات مسجلة لهذا العقار وقت إعداد الاستعلام.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
          pw.SizedBox(height: 12),
          pw.Text(
            'يعرض هذا المستند الحالة الراهنة وقت الاستعلام فقط، ولا يمثل سجلًا تاريخيًا أو إثباتًا لإتمام بيع.',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return pdf.save();
  }
}
