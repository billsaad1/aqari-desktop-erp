import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/internal_subledger_reconciliation_report_model.dart';
import 'print_utils.dart';

class InternalSubledgerReconciliationPdf {
  static Future<Uint8List> build({
    required InternalSubledgerReconciliationReport report,
    required List<InternalSubledgerReconciliationRow> rows,
    required String filterLabel,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final matched = rows.where((row) => row.isLedgerMatched).length;
    final unallocated = rows.fold<int>(
      0,
      (sum, row) => sum + row.unallocatedMinor,
    );
    final data = rows
        .map(
          (row) => [
            row.source.label,
            '${row.sourceId}',
            row.sourceDate,
            row.partyName,
            PrintUtils.formatPdfAmount(row.amountMinor / 100),
            row.journalEntryId == null
                ? '—'
                : '#${row.journalEntryId}${row.journalDate == null ? '' : '\n${row.journalDate}'}',
            row.state.label,
            row.allocationStatus ?? '—',
            row.issueSummary.isEmpty ? '—' : row.issueSummary,
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(24, 20, 24, 26),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'مطابقة السجلات الفرعية مع دفتر الأستاذ',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
                color: PrintUtils.brandNavy,
              ),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(9),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'من تاريخ المستند',
                    report.startDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 80,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'إلى تاريخ المستند',
                    report.endDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 80,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'حالة العرض',
                    filterLabel,
                    labelWidth: 60,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'العملة',
                    currency,
                    labelWidth: 40,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 9),
          pw.Container(
            padding: const pw.EdgeInsets.all(9),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                _metric('السجلات المعروضة', '${rows.length}'),
                pw.SizedBox(width: 16),
                _metric('مطابق مع الأستاذ', '$matched'),
                pw.SizedBox(width: 16),
                _metric('بحاجة لمراجعة', '${rows.length - matched}'),
                pw.SizedBox(width: 16),
                _metric(
                  'قيمة غير مخصصة / بلا مصدر',
                  '${PrintUtils.formatPdfAmount(unallocated / 100)} $currency',
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'هذا تقرير مطابقة دفترية داخلية وقراءة فقط؛ لا يمثل مطابقة بنكية أو خارجية ولا يثبت حركة النقد لدى البنك. تُستخدم الروابط الرقمية المباشرة فقط، وتعرض القيود اليدوية والسجلات التاريخية غير المفصلة للمراجعة. لا ينشئ التقرير أرصدة افتتاحية أو قيود تسوية، ولا يصلح فروقًا تلقائيًا.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: const [
              'نوع المصدر',
              'رقم السجل',
              'التاريخ',
              'الطرف / البيان',
              'المبلغ',
              'القيد / تاريخه',
              'حالة الأستاذ',
              'التخصيص',
              'تفاصيل المراجعة',
            ],
            data: data,
            headerStyle: pw.TextStyle(
              fontSize: 7,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 6.5, lineSpacing: 1.5),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 3,
              vertical: 4,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FixedColumnWidth(72),
              1: pw.FixedColumnWidth(42),
              2: pw.FixedColumnWidth(56),
              3: pw.FlexColumnWidth(1.5),
              4: pw.FixedColumnWidth(58),
              5: pw.FixedColumnWidth(67),
              6: pw.FixedColumnWidth(78),
              7: pw.FixedColumnWidth(82),
              8: pw.FlexColumnWidth(2.2),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.45,
            ),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.center,
              2: pw.Alignment.center,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.center,
              5: pw.Alignment.center,
              6: pw.Alignment.center,
              7: pw.Alignment.center,
              8: pw.Alignment.centerRight,
            },
          ),
          if (rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد سجلات ضمن الفترة وحالة العرض المحددتين.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget _metric(String label, String value) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        label,
        textDirection: pw.TextDirection.rtl,
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        value,
        textDirection: pw.TextDirection.rtl,
        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    ],
  );
}
