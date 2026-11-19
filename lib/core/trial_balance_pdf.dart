import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/trial_balance_report_model.dart';
import 'print_utils.dart';

class TrialBalancePdf {
  static Future<Uint8List> build({
    required TrialBalanceReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final rows = report.rows
        .map(
          (row) => [
            '${row.accountCode} - ${row.accountName}',
            PrintUtils.formatPdfAmount(row.openingDebitMinor / 100),
            PrintUtils.formatPdfAmount(row.openingCreditMinor / 100),
            PrintUtils.formatPdfAmount(row.periodDebitMinor / 100),
            PrintUtils.formatPdfAmount(row.periodCreditMinor / 100),
            PrintUtils.formatPdfAmount(row.closingDebitMinor / 100),
            PrintUtils.formatPdfAmount(row.closingCreditMinor / 100),
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
              'ميزان المراجعة',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 18,
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
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(9),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                _summaryCell('افتتاحي مدين', report.openingDebitMinor),
                _summaryCell('افتتاحي دائن', report.openingCreditMinor),
                _summaryCell('حركة مدين', report.periodDebitMinor),
                _summaryCell('حركة دائن', report.periodCreditMinor),
                _summaryCell('ختامي مدين', report.closingDebitMinor),
                _summaryCell('ختامي دائن', report.closingCreditMinor),
              ],
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'فحص التوازن: الافتتاح ${_balanceText(report.openingIsBalanced)}، '
            'الحركة ${_balanceText(report.periodIsBalanced)}، '
            'الإقفال ${_balanceText(report.closingIsBalanced)}',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              fontSize: 9,
              color:
                  report.openingIsBalanced &&
                      report.periodIsBalanced &&
                      report.closingIsBalanced
                  ? PrintUtils.brandEmerald
                  : PdfColors.red,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: const [
              'الحساب',
              'افتتاحي مدين',
              'افتتاحي دائن',
              'حركة مدين',
              'حركة دائن',
              'ختامي مدين',
              'ختامي دائن',
            ],
            data: rows,
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 7.5, lineSpacing: 1.5),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 3,
              vertical: 4,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(2.4),
              1: pw.FlexColumnWidth(1),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(1),
              4: pw.FlexColumnWidth(1),
              5: pw.FlexColumnWidth(1),
              6: pw.FlexColumnWidth(1),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.center,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
              4: pw.Alignment.center,
              5: pw.Alignment.center,
              6: pw.Alignment.center,
            },
          ),
          if (report.rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد حسابات تفصيلية لإظهارها.',
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

  static String _balanceText(bool balanced) => balanced ? 'متزن' : 'غير متزن';

  static pw.Widget _summaryCell(String label, int minor) => pw.Expanded(
    child: PrintUtils.buildLabelValue(
      label,
      PrintUtils.formatPdfAmount(minor / 100),
      valueDirection: pw.TextDirection.ltr,
      labelWidth: 78,
    ),
  );
}
