import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/financial_position_report_model.dart';
import 'print_utils.dart';

class FinancialPositionPdf {
  static Future<Uint8List> build({
    required FinancialPositionReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final rows = report.rows
        .map(
          (row) => [
            row.typeLabel,
            row.accountCode,
            row.accountName,
            PrintUtils.formatPdfAmount(row.normalBalanceMinor / 100),
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(26, 28, 26, 32),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'قائمة المركز المالي الداخلية',
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
              'حتى تاريخ ${report.asOfDate}',
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
                    _summaryCell('إجمالي الأصول', report.assetsMinor),
                    _summaryCell('إجمالي الخصوم', report.liabilitiesMinor),
                    _summaryCell(
                      'حقوق الملكية المسجلة',
                      report.equityAccountsMinor,
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  children: [
                    _summaryCell(
                      'نتيجة غير مقفلة',
                      report.unclosedEarningsMinor,
                    ),
                    _summaryCell(
                      'الخصوم وحقوق الملكية',
                      report.liabilitiesAndEquityMinor,
                    ),
                    _summaryCell(
                      'فرق المعادلة',
                      report.equationDifferenceMinor,
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
              color: report.isReadyForReview
                  ? PdfColors.green50
                  : PdfColors.orange50,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Text(
              _statusText(report),
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: report.isReadyForReview
                    ? PrintUtils.brandEmerald
                    : PdfColors.deepOrange,
              ),
            ),
          ),
          pw.SizedBox(height: 9),
          pw.TableHelper.fromTextArray(
            headers: const [
              'طبيعة الحساب',
              'الرمز',
              'الحساب',
              'الرصيد الطبيعي',
            ],
            data: rows,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 8, lineSpacing: 1.4),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 4,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(1),
              1: pw.FlexColumnWidth(0.8),
              2: pw.FlexColumnWidth(3),
              3: pw.FlexColumnWidth(1.2),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.center,
            },
          ),
          if (report.rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد أرصدة مرحلة حتى هذا التاريخ.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'العملة: $currency. يعتمد التقرير على أرصدة دفتر الأستاذ للقيود المرحلة حتى التاريخ المحدد. '
            'وتعرض نتيجة الإيرادات والمصروفات غير المقفلة منفصلة عن حسابات حقوق الملكية؛ '
            'لا يُنشئ التقرير قيدًا ولا يضيف رصيدًا افتراضيًا لإجبار التوازن.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget _summaryCell(String label, int minor) => pw.Expanded(
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
          PrintUtils.formatPdfAmount(minor / 100),
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

  static String _statusText(FinancialPositionReport report) {
    final diff = PrintUtils.formatPdfAmount(
      report.equationDifferenceMinor / 100,
    );
    if (report.hasUnclassifiedAccounts) {
      return 'تحتاج مراجعة: عدد الحسابات غير المصنفة ${report.unclassifiedRows.length}. '
          'فرق المعادلة (دون رصيد موازن افتراضي): $diff';
    }
    if (!report.isAccountingEquationBalanced) {
      return 'فرق في المعادلة المحاسبية؛ راجع القيود والأرصدة. الفرق: $diff';
    }
    return 'المعادلة متوازنة حسب تصنيف الحسابات المسجل في الدليل.';
  }
}
