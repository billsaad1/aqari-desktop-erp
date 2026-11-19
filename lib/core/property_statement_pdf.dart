import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/property_statement_report_model.dart';
import 'print_utils.dart';

class PropertyStatementPdf {
  static Future<Uint8List> build({
    required PropertyStatementReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final tableData = report.lines
        .map(
          (line) => [
            line.date,
            line.journalEntryId.toString(),
            '${line.accountCode} - ${line.accountName}',
            line.description,
            PrintUtils.formatPdfAmount(line.debitMinor / 100.0),
            PrintUtils.formatPdfAmount(line.creditMinor / 100.0),
            PrintUtils.formatPdfAmount(line.runningBalanceMinor / 100.0),
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'كشف حساب العقار',
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
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                PrintUtils.buildLabelValue(
                  'العقار',
                  report.propertyName,
                  labelWidth: 76,
                ),
                if (report.ownerName.isNotEmpty)
                  PrintUtils.buildLabelValue(
                    'المالك',
                    report.ownerName,
                    labelWidth: 76,
                  ),
                PrintUtils.buildLabelValue(
                  'مركز التكلفة',
                  report.hasCostCenter
                      ? '${report.costCenterCode} - ${report.costCenterName}'
                      : 'غير مرتبط بمركز تكلفة',
                  labelWidth: 76,
                ),
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: PrintUtils.buildLabelValue(
                        'من تاريخ',
                        report.startDate,
                        valueDirection: pw.TextDirection.ltr,
                        labelWidth: 76,
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: PrintUtils.buildLabelValue(
                        'إلى تاريخ',
                        report.endDate,
                        valueDirection: pw.TextDirection.ltr,
                        labelWidth: 76,
                      ),
                    ),
                  ],
                ),
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: PrintUtils.buildLabelValue(
                        'العملة',
                        currency,
                        labelWidth: 76,
                      ),
                    ),
                  ],
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
            child: pw.Column(
              children: [
                pw.Row(
                  children: [
                    _summaryCell(
                      'الرصيد الافتتاحي',
                      report.openingBalanceMinor,
                    ),
                    _summaryCell('إجمالي المدين', report.totalDebitMinor),
                  ],
                ),
                pw.SizedBox(height: 6),
                pw.Row(
                  children: [
                    _summaryCell('إجمالي الدائن', report.totalCreditMinor),
                    _summaryCell(
                      'الرصيد الختامي',
                      report.closingBalanceMinor,
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: [
              'التاريخ',
              'القيد',
              'الحساب',
              'البيان',
              'مدين',
              'دائن',
              'الرصيد',
            ],
            data: tableData,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 8.5, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 6,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FixedColumnWidth(58),
              1: pw.FixedColumnWidth(42),
              2: pw.FlexColumnWidth(2.2),
              3: pw.FlexColumnWidth(2.0),
              4: pw.FixedColumnWidth(58),
              5: pw.FixedColumnWidth(58),
              6: pw.FixedColumnWidth(66),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.center,
              5: pw.Alignment.center,
              6: pw.Alignment.center,
            },
          ),
          if (report.lines.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                report.hasCostCenter
                    ? 'لا توجد حركات مرحلة على مركز تكلفة هذا العقار خلال الفترة المحددة.'
                    : 'هذا العقار غير مرتبط بمركز تكلفة، لذلك لا يمكن عرض حركاته.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          if (report.gaps.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PrintUtils.softBorder),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text(
                    'حركات لم يتم إسنادها إلى هذا العقار',
                    textDirection: pw.TextDirection.rtl,
                    textAlign: pw.TextAlign.right,
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PrintUtils.brandNavy,
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  ...report.gaps.map(
                    (gap) => pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 2),
                      child: pw.Text(
                        '• ${_gapLabel(gap)}: ${gap.lineCount} سطر، '
                        'مدين ${PrintUtils.formatPdfAmount(gap.debitMinor / 100.0)}، '
                        'دائن ${PrintUtils.formatPdfAmount(gap.creditMinor / 100.0)}',
                        textDirection: pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.right,
                        style: const pw.TextStyle(fontSize: 8.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    return pdf.save();
  }

  static String _gapLabel(PropertyStatementGap gap) => switch (gap.reason) {
    PropertyStatementGapReason.propertyWithoutCostCenter =>
      'العقار بلا مركز تكلفة',
    PropertyStatementGapReason.sharedCostCenter =>
      'مركز تكلفة مشترك مع عقارات أخرى',
    PropertyStatementGapReason.unassignedCostCenter => 'سطور بلا مركز تكلفة',
  };

  static pw.Widget _summaryCell(String label, int amountMinor) => pw.Expanded(
    child: PrintUtils.buildLabelValue(
      label,
      PrintUtils.formatPdfAmount(amountMinor / 100.0),
      valueDirection: pw.TextDirection.ltr,
      labelWidth: 102,
    ),
  );
}
