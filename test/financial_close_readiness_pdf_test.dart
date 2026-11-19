import 'package:app/core/financial_close_readiness_pdf.dart';
import 'package:app/models/financial_close_readiness_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds Arabic PDF for an unresolved manual close review', () async {
    final report = FinancialCloseReadinessReport(
      startDate: '2026-06-01',
      endDate: '2026-06-30',
      currency: 'SAR',
      unpostedEntries: const [
        FinancialCloseEntryIssue(
          journalEntryId: 7,
          entryDate: '2026-06-30',
          description: 'مسودة شهرية',
          debitMinor: 12500,
          creditMinor: 10000,
          lineCount: 2,
          isPosted: false,
        ),
      ],
      unbalancedPostedEntries: const [
        FinancialCloseEntryIssue(
          journalEntryId: 9,
          entryDate: '2026-06-25',
          description: 'قيد غير متوازن',
          debitMinor: 22000,
          creditMinor: 21000,
          lineCount: 2,
          isPosted: true,
        ),
      ],
    );

    final bytes = await FinancialCloseReadinessPdf.build(
      report: report,
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(report.hasBlockingIssues, isTrue);
  });
}
