import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/financial_close_readiness_report_model.dart';
import 'print_utils.dart';

class FinancialCloseReadinessPdf {
  static Future<Uint8List> build({
    required FinancialCloseReadinessReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final issues = [
      ...report.unpostedEntries,
      ...report.unbalancedPostedEntries,
    ];
    final rows = issues
        .map(
          (issue) => [
            issue.statusLabel,
            issue.journalEntryId.toString(),
            issue.entryDate,
            issue.description,
            PrintUtils.formatPdfAmount(issue.debitMinor / 100),
            PrintUtils.formatPdfAmount(issue.creditMinor / 100),
            PrintUtils.formatPdfAmount(issue.differenceMinor / 100),
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(24, 26, 24, 30),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'مراجعة جاهزية الإقفال المالي',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
                color: PrintUtils.brandNavy,
              ),
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.Text(
              'من ${report.startDate} إلى ${report.endDate}',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 10),
            ),
          ),
          pw.SizedBox(height: 9),
          pw.Container(
            padding: const pw.EdgeInsets.all(9),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              children: [
                pw.Row(
                  children: [
                    _metric(
                      'قيود غير مرحلة',
                      report.unpostedEntries.length.toString(),
                    ),
                    _metric(
                      'قيود مرحلة غير متوازنة',
                      report.unbalancedPostedEntries.length.toString(),
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  children: [
                    _metric(
                      'إجمالي مدين المسودات',
                      PrintUtils.formatPdfAmount(
                        report.unpostedDebitMinor / 100,
                      ),
                    ),
                    _metric(
                      'إجمالي دائن المسودات',
                      PrintUtils.formatPdfAmount(
                        report.unpostedCreditMinor / 100,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 7),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: pw.BoxDecoration(
              color: report.isReadyForManualReview
                  ? PdfColors.green50
                  : PdfColors.orange50,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Text(
              report.isReadyForManualReview
                  ? 'اجتازت الفترة فحوص توازن القيود الأساسية؛ هذا التقرير لا ينفذ الإقفال، ويظل الاعتماد اليدوي والمراجعة المحاسبية مطلوبين.'
                  : 'تحتاج الفترة إلى مراجعة القيود المعروضة قبل أي إجراء إقفال يدوي.',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: report.isReadyForManualReview
                    ? PrintUtils.brandEmerald
                    : PdfColors.deepOrange,
              ),
            ),
          ),
          pw.SizedBox(height: 9),
          pw.TableHelper.fromTextArray(
            headers: const [
              'حالة المراجعة',
              'رقم القيد',
              'التاريخ',
              'البيان',
              'مدين',
              'دائن',
              'الفرق',
            ],
            data: rows,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 8, lineSpacing: 1.3),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 4,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(1.2),
              1: pw.FlexColumnWidth(0.7),
              2: pw.FlexColumnWidth(1.1),
              3: pw.FlexColumnWidth(2.8),
              4: pw.FlexColumnWidth(0.9),
              5: pw.FlexColumnWidth(0.9),
              6: pw.FlexColumnWidth(0.9),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.center,
              2: pw.Alignment.center,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.center,
              5: pw.Alignment.center,
              6: pw.Alignment.center,
            },
          ),
          if (issues.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد قيود غير مرحلة أو قيود مرحلة بلا توازن ضمن هذه الفترة.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'العملة: $currency. هذا فحص قراءة فقط لقيود الفترة: يكشف المسودات والقيود المرحّلة غير المتوازنة أو بلا سطور، ولا ينشئ قيود إقفال أو يقفل الفترة أو يغير الأرصدة.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget _metric(String label, String value) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          textDirection: pw.TextDirection.ltr,
          textAlign: pw.TextAlign.right,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PrintUtils.brandNavy,
          ),
        ),
      ],
    ),
  );
}
