import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/tenant_aging_report_model.dart';
import 'print_utils.dart';

class TenantAgingReportPdf {
  static Future<Uint8List> build({
    required TenantAgingReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final agingRows = report.rows
        .map(
          (row) => [
            row.tenantName,
            row.propertyName,
            row.unitNumber,
            row.installmentId.toString(),
            row.dueDate,
            row.daysOverdue.toString(),
            row.bucket.label,
            PrintUtils.formatPdfAmount(row.obligationMinor / 100),
            PrintUtils.formatPdfAmount(row.paidMinor / 100),
            PrintUtils.formatPdfAmount(row.balanceMinor / 100),
          ],
        )
        .toList(growable: false);
    final exceptionRows = report.exceptions
        .map(
          (exception) => [
            exception.documentType,
            exception.documentId.toString(),
            exception.documentDate,
            exception.tenantName,
            PrintUtils.formatPdfAmount(exception.amountMinor / 100),
            exception.reason,
          ],
        )
        .toList(growable: false);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(22, 25, 22, 30),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'تقرير أعمار ديون المستأجرين',
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
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: PrintUtils.buildLabelValue(
                    'تاريخ القطع',
                    report.asOfDate,
                    valueDirection: pw.TextDirection.ltr,
                    labelWidth: 70,
                  ),
                ),
                pw.SizedBox(width: 18),
                pw.Expanded(
                  child: PrintUtils.buildLabelValue('العملة', currency),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                _summaryCell('غير مستحق', report.notDueMinor),
                _summaryCell('0–30 يومًا', report.days0To30Minor),
                _summaryCell('31–60 يومًا', report.days31To60Minor),
                _summaryCell('61–90 يومًا', report.days61To90Minor),
                _summaryCell('91+ يومًا', report.days91PlusMinor),
                _summaryCell(
                  'إجمالي الرصيد المؤكد',
                  report.totalOutstandingMinor,
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'تُحتسب الأيام من تاريخ الاستحقاق حتى تاريخ القطع؛ المستحق اليوم ضمن 0–30 يومًا. الرصيد المؤكد يخصم فقط تخصيصات القبض التفصيلية المتسقة والاستردادات المرتبطة الموثقة، ولا يعتمد paid_amount أو أرصدة التخصيص الحالية لإعادة بناء الماضي.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
          ),
          pw.Text(
            'القطع حسب تواريخ المستندات المنشورة حاليًا (الاستحقاق/الفاتورة/السند)، وليس لقطة لما كان معروفًا للنظام عند تاريخ القطع. القبوض غير المخصصة والسجلات القديمة وغير المتسقة معروضة أدناه للمراجعة ولا تخفض الذمم.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          if (agingRows.isEmpty)
            pw.Center(
              child: pw.Padding(
                padding: const pw.EdgeInsets.all(20),
                child: pw.Text(
                  'لا توجد أرصدة أقساط مؤكدة في تاريخ القطع.',
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: const [
                'المستأجر',
                'العقار',
                'الوحدة',
                'القسط',
                'الاستحقاق',
                'أيام التأخير',
                'الشريحة',
                'الالتزام',
                'المسدد المؤكد',
                'الرصيد',
              ],
              data: agingRows,
              headerStyle: pw.TextStyle(
                fontSize: 7,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 6.5, lineSpacing: 1),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 3,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(1.7),
                1: pw.FlexColumnWidth(1.5),
                2: pw.FlexColumnWidth(0.8),
                3: pw.FlexColumnWidth(0.55),
                4: pw.FlexColumnWidth(1),
                5: pw.FlexColumnWidth(0.7),
                6: pw.FlexColumnWidth(0.85),
                7: pw.FlexColumnWidth(0.9),
                8: pw.FlexColumnWidth(0.9),
                9: pw.FlexColumnWidth(0.9),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.45,
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'إجمالي الرصيد المؤكد: ${PrintUtils.formatPdfAmount(report.totalOutstandingMinor / 100)} $currency',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            'استثناءات للمراجعة — مبلغها لا يُخصم من الرصيد المؤكد',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 5),
          if (exceptionRows.isEmpty)
            pw.Text(
              'لا توجد استثناءات مسجلة.',
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(fontSize: 8),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: const [
                'المستند',
                'الرقم',
                'التاريخ',
                'المستأجر',
                'المبلغ المعزول',
                'سبب المراجعة',
              ],
              data: exceptionRows,
              headerStyle: pw.TextStyle(
                fontSize: 7,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 6.5, lineSpacing: 1),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 3,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(0.8),
                1: pw.FlexColumnWidth(0.6),
                2: pw.FlexColumnWidth(1),
                3: pw.FlexColumnWidth(1.5),
                4: pw.FlexColumnWidth(0.9),
                5: pw.FlexColumnWidth(3.5),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.45,
              ),
            ),
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget _summaryCell(String label, int amountMinor) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 6.8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          PrintUtils.formatPdfAmount(amountMinor / 100),
          textDirection: pw.TextDirection.ltr,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: PrintUtils.brandNavy,
          ),
        ),
      ],
    ),
  );
}
