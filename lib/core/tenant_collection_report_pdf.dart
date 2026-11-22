import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/tenant_collection_report_model.dart';
import 'print_utils.dart';

class TenantCollectionReportPdf {
  static Future<Uint8List> build({
    required TenantCollectionReport report,
    required Map<String, dynamic>? companyInfo,
    required String currency,
    String? tenantName,
  }) async {
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    final rows = report.rows
        .map(
          (row) => [
            row.voucherId.toString(),
            row.voucherDate,
            row.tenantName,
            row.isCorrectionReversal
                ? row.isVerifiedCorrectionReversal
                      ? 'عكس تصحيح قبض\n(غير نقدي)'
                      : 'عكس تصحيح قبض\n(غير نقدي - للمراجعة)'
                : row.isRefund
                ? row.isVerifiedRefund
                      ? 'استرداد نقدي مرتبط'
                      : 'استرداد نقدي للمراجعة'
                : 'قبض نقدي',
            PrintUtils.formatPdfAmount(row.amountMinor / 100),
            row.sourceReceiptVoucherIds.isEmpty
                ? '—'
                : row.isCorrectionReversal
                ? 'الأصل: ${row.sourceReceiptVoucherIds}\n'
                      'البديل: ${row.replacementReceiptVoucherId ?? '—'}'
                : row.sourceReceiptVoucherIds,
            row.allocationStatus,
            row.isCorrectionReversal &&
                    row.correctionReason?.trim().isNotEmpty == true
                ? '${row.sourceConsistencyStatus}\n'
                      'السبب: ${row.correctionReason}'
                : row.sourceConsistencyStatus,
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
              tenantName == null || tenantName.trim().isEmpty
                  ? 'تقرير تحصيل المستأجرين'
                  : 'كشف تحصيل المستأجر: ${tenantName.trim()}',
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
          if (tenantName != null && tenantName.trim().isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: PrintUtils.buildLabelValue('المستأجر', tenantName.trim()),
            ),
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
                _summaryCell(
                  'إجمالي القبوضات النقدية المرحلة',
                  report.grossReceiptsMinor,
                ),
                _summaryCell(
                  'الاستردادات النقدية المرتبطة المطابقة',
                  report.linkedRefundsMinor,
                ),
                _summaryCell(
                  'صافي التحصيل النقدي المؤكد',
                  report.grossReceiptsMinor - report.linkedRefundsMinor,
                ),
                _summaryCell(
                  'قبوض بلا تخصيص مثبت',
                  report.unallocatedReceiptsMinor,
                ),
                _summaryCell(
                  'استردادات تحتاج مراجعة',
                  report.unverifiedRefundsMinor,
                ),
              ],
            ),
          ),
          if (report.rows.any((row) => row.isCorrectionReversal)) ...[
            pw.SizedBox(height: 6),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.indigo50,
                border: pw.Border.all(color: PdfColors.indigo200),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text(
                    'عكوس تصحيح القبض — حركات محاسبية غير نقدية',
                    textDirection: pw.TextDirection.rtl,
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: PrintUtils.brandNavy,
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Row(
                    children: [
                      _summaryCell(
                        'عكوس تصحيح موثقة (غير نقدية)',
                        report.linkedReceiptCorrectionsMinor,
                      ),
                      _summaryCell(
                        'عكوس تصحيح تحتاج مراجعة (غير نقدية)',
                        report.unverifiedCorrectionReversalsMinor,
                      ),
                      _summaryCountCell(
                        'عدد عكوس التصحيح غير النقدية',
                        report.rows
                            .where((row) => row.isCorrectionReversal)
                            .length,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          pw.SizedBox(height: 6),
          pw.Text(
            'يقارن التقرير التخصيصات التفصيلية بالسجلات التاريخية للفواتير والأقساط. لا يُخصم الاسترداد النقدي إلا إذا طابق سند الرد والمصدر المرحّل للمستأجر نفسه وبقي ضمن سقف المبلغ الأصلي بعد احتساب جميع الردود. عكس تصحيح القبض حركة محاسبية غير نقدية، وتُعرض منفصلة عن القبوضات والاستردادات وصافي التحصيل النقدي.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 9),
          if (rows.isEmpty)
            pw.Center(
              child: pw.Padding(
                padding: const pw.EdgeInsets.all(24),
                child: pw.Text(
                  'لا توجد سندات تحصيل أو استردادات مرتبطة في الفترة المحددة.',
                  textDirection: pw.TextDirection.rtl,
                  style: const pw.TextStyle(fontSize: 11),
                ),
              ),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: const [
                'رقم السند',
                'التاريخ',
                'المستأجر',
                'النوع',
                'المبلغ (موقّع)',
                'السند المصدر / الأصل',
                'حالة التخصيص',
                'اتساق مرجع التخصيص',
              ],
              data: rows,
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 7.5, lineSpacing: 1.3),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 4,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(0.7),
                1: pw.FlexColumnWidth(1.1),
                2: pw.FlexColumnWidth(1.9),
                3: pw.FlexColumnWidth(1.1),
                4: pw.FlexColumnWidth(1.2),
                5: pw.FlexColumnWidth(1.2),
                6: pw.FlexColumnWidth(1.8),
                7: pw.FlexColumnWidth(2.2),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.5,
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'عدد سندات القبض: ${report.receiptCount}    '
            'الاستردادات الموثقة والمطابقة: ${report.linkedRefundCount}    '
            'استردادات للمراجعة: ${report.unverifiedRefundCount}    '
            'عكوس تصحيح القبض (غير نقدية): '
            '${report.rows.where((row) => row.isCorrectionReversal).length}    '
            'سندات تخصيصها يحتاج مراجعة: ${report.sourceMismatchVoucherCount}',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
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
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          PrintUtils.formatPdfAmount(minor / 100),
          textDirection: pw.TextDirection.ltr,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: minor < 0 ? PdfColors.red : PrintUtils.brandNavy,
          ),
        ),
      ],
    ),
  );

  static pw.Widget _summaryCountCell(String label, int count) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          '$count',
          textDirection: pw.TextDirection.ltr,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: PrintUtils.brandNavy,
          ),
        ),
      ],
    ),
  );
}
