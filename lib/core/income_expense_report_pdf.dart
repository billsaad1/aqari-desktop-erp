import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/income_expense_report_model.dart';
import 'print_utils.dart';

class IncomeExpenseReportPdf {
  static Future<Uint8List> build({
    required IncomeExpenseReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final tableData = report.rows
        .map(
          (row) => [
            row.accountType == 'Revenue' ? 'إيراد' : 'مصروف',
            '${row.accountCode} - ${row.accountName}',
            PrintUtils.formatPdfAmount(row.debitMinor / 100),
            PrintUtils.formatPdfAmount(row.creditMinor / 100),
            PrintUtils.formatPdfAmount(row.netMinor / 100),
          ],
        )
        .toList(growable: false);
    final resultColor = report.netResultMinor >= 0
        ? PrintUtils.brandEmerald
        : PdfColors.red;

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(30, 26, 30, 30),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'حركة الإيرادات والمصروفات',
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
                    'من تاريخ',
                    report.startDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 60,
                  ),
                ),
                pw.SizedBox(width: 16),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'إلى تاريخ',
                    report.endDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 60,
                  ),
                ),
                pw.SizedBox(width: 16),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'العملة',
                    currency,
                    labelWidth: 55,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              children: [
                pw.Row(
                  children: [
                    _summaryCell('صافي الإيرادات', report.revenueNetMinor),
                    pw.SizedBox(width: 12),
                    _summaryCell('صافي المصروفات', report.expenseNetMinor),
                    pw.SizedBox(width: 12),
                    _summaryCell(
                      'صافي نتيجة الفترة',
                      report.netResultMinor,
                      valueColor: resultColor,
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  children: [
                    _summaryCell('مدين الإيرادات', report.revenueDebitMinor),
                    pw.SizedBox(width: 12),
                    _summaryCell('دائن الإيرادات', report.revenueCreditMinor),
                    pw.SizedBox(width: 12),
                    _summaryCell('مدين المصروفات', report.expenseDebitMinor),
                    pw.SizedBox(width: 12),
                    _summaryCell('دائن المصروفات', report.expenseCreditMinor),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'المصدر هو الحركات المرحلة على حسابات الإيرادات والمصروفات فقط؛ لا يمثل التقرير إجمالي الفواتير أو التحصيل غير المرحّل.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: const ['النوع', 'الحساب', 'مدين', 'دائن', 'الصافي'],
            data: tableData,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 8, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 6,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FixedColumnWidth(56),
              1: pw.FlexColumnWidth(2.4),
              2: pw.FixedColumnWidth(74),
              3: pw.FixedColumnWidth(74),
              4: pw.FixedColumnWidth(78),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.centerRight,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
              4: pw.Alignment.center,
            },
          ),
          if (report.rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد حركات مرحلة على حسابات الإيرادات أو المصروفات في الفترة المحددة.',
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

  static pw.Widget _summaryCell(
    String label,
    int minor, {
    PdfColor? valueColor,
  }) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          PrintUtils.formatPdfAmount(minor / 100),
          textDirection: pw.TextDirection.ltr,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: valueColor ?? PrintUtils.brandNavy,
          ),
        ),
      ],
    ),
  );
}
