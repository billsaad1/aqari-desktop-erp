import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/financial_close_readiness_report_model.dart';
import '../models/internal_subledger_reconciliation_report_model.dart';
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
    final reconciliationRows = report.internalReconciliation.rows
        .where((row) => !row.isLedgerMatched)
        .toList(growable: false);
    final reconciliationTableRows = reconciliationRows
        .map(
          (row) => [
            row.state.label,
            row.source.label,
            row.sourceId.toString(),
            row.sourceDate,
            row.partyName,
            PrintUtils.formatPdfAmount(row.amountMinor / 100),
            row.issueSummary,
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
                pw.SizedBox(height: 8),
                pw.Row(
                  children: [
                    _metric(
                      'استثناءات مطابقة داخلية مانعة',
                      report.blockingReconciliationCount.toString(),
                    ),
                    _metric(
                      'بنود تاريخية للمراجعة',
                      report.legacyReviewCount.toString(),
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Row(
                  children: [
                    _metric(
                      'استثناءات تتطلب إقرار مراجعة',
                      report.manualReviewAcknowledgementCount.toString(),
                    ),
                    _metric(
                      'قيود أستاذ مباشرة',
                      report.internalReconciliation.directJournalCount
                          .toString(),
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
              color: !report.isReadyForManualReview
                  ? PdfColors.orange50
                  : report.requiresManualReviewAcknowledgement
                  ? PdfColors.orange50
                  : PdfColors.green50,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Text(
              !report.isReadyForManualReview
                  ? 'توجد قيود أو استثناءات مطابقة داخلية تحتاج معالجة يدوية قبل القفل.'
                  : report.requiresManualReviewAcknowledgement
                  ? 'لا توجد موانع تشغيلية، لكن توجد حركات تتطلب قرار مراجعة يدويًا وتوثيقًا عند القفل.'
                  : 'اجتازت الفترة فحوص التوازن والمطابقة الداخلية الأساسية؛ يظل الاعتماد اليدوي مطلوبًا.',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: !report.isReadyForManualReview
                    ? PdfColors.deepOrange
                    : report.requiresManualReviewAcknowledgement
                    ? PdfColors.deepOrange
                    : PrintUtils.brandEmerald,
              ),
            ),
          ),
          pw.SizedBox(height: 9),
          if (issues.isNotEmpty)
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
          pw.SizedBox(height: 10),
          pw.Text(
            'استثناءات المطابقة الداخلية بين المستندات والأستاذ',
            textDirection: pw.TextDirection.rtl,
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 5),
          if (reconciliationTableRows.isNotEmpty)
            pw.TableHelper.fromTextArray(
              headers: const [
                'الحالة',
                'المصدر',
                'رقم المصدر',
                'التاريخ',
                'الطرف / البيان',
                'المبلغ',
                'سبب المراجعة',
              ],
              data: reconciliationTableRows,
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 7, lineSpacing: 1.2),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 3,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(1.0),
                1: pw.FlexColumnWidth(1.2),
                2: pw.FlexColumnWidth(0.7),
                3: pw.FlexColumnWidth(1.0),
                4: pw.FlexColumnWidth(1.5),
                5: pw.FlexColumnWidth(0.8),
                6: pw.FlexColumnWidth(2.0),
              },
              border: pw.TableBorder.all(
                color: PrintUtils.softBorder,
                width: 0.5,
              ),
              cellAlignments: {
                0: pw.Alignment.centerRight,
                1: pw.Alignment.centerRight,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.centerRight,
                5: pw.Alignment.center,
                6: pw.Alignment.centerRight,
              },
            )
          else
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text(
                'لا توجد استثناءات مطابقة داخلية ظاهرة ضمن الفترة.',
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          pw.SizedBox(height: 8),
          pw.Text(
            'العملة: $currency. المطابقة هنا داخلية فقط ولا تعتمد على كشوف خارجية. يكشف التقرير المسودات والقيود غير المتوازنة ومشكلات ربط المستندات؛ لا ينشئ قيود تصحيح أو قيد إقفال أرباح وخسائر ولا يغير الأرصدة. لا تُخمن روابط السجلات التاريخية أو القيود المباشرة الملتبسة؛ يلزم توثيق المراجعة قبل القفل.',
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
