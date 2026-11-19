import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/invoice_ledger_reconciliation_report_model.dart';
import 'print_utils.dart';

class InvoiceLedgerReconciliationPdf {
  static Future<Uint8List> build({
    required InvoiceLedgerReconciliationReport report,
    required List<InvoiceLedgerReconciliationRow> rows,
    required String filterLabel,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final matched = rows.where((row) => row.isReconciled).length;
    final needsReview = rows.length - matched;
    final tableData = rows
        .map(
          (row) => [
            '${row.invoiceId}',
            row.invoiceDate,
            row.tenantName?.trim().isNotEmpty == true
                ? row.tenantName!.trim()
                : 'غير مرتبط',
            '${PrintUtils.formatPdfAmount(row.netMinor / 100)} / '
                '${row.installmentAmountMinor == null ? '—' : PrintUtils.formatPdfAmount(row.installmentAmountMinor! / 100)}',
            PrintUtils.formatPdfAmount(row.totalMinor / 100),
            PrintUtils.formatPdfAmount(row.journalDebitMinor / 100),
            PrintUtils.formatPdfAmount(row.journalCreditMinor / 100),
            row.isReconciled
                ? 'مطابق'
                : '${row.statusLabel}\n${row.issueSummary}',
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(28, 24, 28, 28),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'مطابقة الفواتير مع دفتر الأستاذ',
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
                    'من تاريخ الفاتورة',
                    report.startDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 75,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'إلى تاريخ الفاتورة',
                    report.endDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 75,
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'حالة العرض',
                    filterLabel,
                    labelWidth: 55,
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
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                _metric('الفواتير المعروضة', '${rows.length}'),
                pw.SizedBox(width: 18),
                _metric(
                  'مطابق',
                  '$matched',
                  valueColor: PrintUtils.brandEmerald,
                ),
                pw.SizedBox(width: 18),
                _metric(
                  'يحتاج مراجعة',
                  '$needsReview',
                  valueColor: needsReview == 0
                      ? PrintUtils.brandEmerald
                      : PdfColors.red,
                ),
                pw.SizedBox(width: 18),
                _metric(
                  'إجمالي الفواتير المعروضة',
                  '${PrintUtils.formatPdfAmount(rows.fold<int>(0, (sum, row) => sum + row.totalMinor) / 100)} $currency',
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'المطابقة داخلية وقراءة فقط: تتحقق من القسط وحساب الضريبة المحفوظ بالفاتورة وربطها بالقيد وتوازنه وحساب ذمم المستأجر والإيراد. الفواتير التاريخية التي لا تحفظ حساب الضريبة تظهر للمراجعة. لا تُصحح المخالفات آليًا، ولا يمثل التقرير إثبات امتثال ضريبي رسمي.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: const [
              'رقم الفاتورة',
              'التاريخ',
              'المستأجر',
              'صافي الفاتورة / القسط',
              'إجمالي الفاتورة',
              'مدين القيد',
              'دائن القيد',
              'نتيجة المطابقة / الملاحظات',
            ],
            data: tableData,
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 7, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 5,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FixedColumnWidth(55),
              1: pw.FixedColumnWidth(68),
              2: pw.FlexColumnWidth(1.25),
              3: pw.FixedColumnWidth(90),
              4: pw.FixedColumnWidth(80),
              5: pw.FixedColumnWidth(70),
              6: pw.FixedColumnWidth(70),
              7: pw.FlexColumnWidth(2.8),
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
              6: pw.Alignment.center,
              7: pw.Alignment.centerRight,
            },
          ),
          if (rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.all(12),
              child: pw.Text(
                'لا توجد فواتير ضمن الفترة وحالة العرض المحددتين.',
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

  static pw.Widget _metric(
    String label,
    String value, {
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
          value,
          textDirection: pw.TextDirection.rtl,
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
