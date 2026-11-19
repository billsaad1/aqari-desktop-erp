import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/account_statement_report_model.dart';
import 'print_utils.dart';

class AccountStatementPdf {
  static Future<Uint8List> build({
    required AccountStatementReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
    String statementTitle = 'كشف حساب دفتر الأستاذ',
    String? partyName,
    String partyLabel = 'المستأجر',
    String accountLabel = 'الحساب',
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final accountTypeArabic = switch (report.accountType) {
      'Asset' => 'أصول',
      'Liability' => 'التزامات',
      'Equity' => 'حقوق ملكية',
      'Revenue' => 'إيرادات',
      'Expense' => 'مصروفات',
      _ => report.accountType,
    };
    final tableData = report.lines
        .map(
          (line) => [
            line.date,
            line.journalEntryId.toString(),
            line.description,
            PrintUtils.formatPdfAmount(line.debit),
            PrintUtils.formatPdfAmount(line.credit),
            PrintUtils.formatPdfAmount(line.runningBalance),
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
              statementTitle,
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
                if (partyName != null)
                  PrintUtils.buildLabelValue(
                    partyLabel,
                    partyName,
                    labelWidth: 76,
                  ),
                PrintUtils.buildLabelValue(
                  accountLabel,
                  '${report.accountCode} - ${report.accountName}',
                  labelWidth: 76,
                ),
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: PrintUtils.buildLabelValue(
                        'نوع الحساب',
                        accountTypeArabic,
                        labelWidth: 76,
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: PrintUtils.buildLabelValue(
                        'العملة',
                        currency,
                        labelWidth: 55,
                      ),
                    ),
                  ],
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
                    _summaryCell('الرصيد الافتتاحي', report.openingBalance),
                    _summaryCell('إجمالي المدين', report.totalDebit),
                  ],
                ),
                pw.SizedBox(height: 6),
                pw.Row(
                  children: [
                    _summaryCell('إجمالي الدائن', report.totalCredit),
                    _summaryCell('الرصيد الختامي', report.closingBalance),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: [
              'التاريخ',
              'رقم القيد',
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
              0: pw.FixedColumnWidth(65),
              1: pw.FixedColumnWidth(54),
              2: pw.FlexColumnWidth(2.5),
              3: pw.FixedColumnWidth(65),
              4: pw.FixedColumnWidth(65),
              5: pw.FixedColumnWidth(75),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.center,
              4: pw.Alignment.center,
              5: pw.Alignment.center,
            },
          ),
          if (report.lines.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد حركات مرحلة خلال الفترة المحددة؛ يظهر الرصيد الافتتاحي والختامي أعلاه.',
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

  static pw.Widget _summaryCell(String label, double amount) => pw.Expanded(
    child: PrintUtils.buildLabelValue(
      label,
      PrintUtils.formatPdfAmount(amount),
      valueDirection: pw.TextDirection.ltr,
      labelWidth: 102,
    ),
  );
}
