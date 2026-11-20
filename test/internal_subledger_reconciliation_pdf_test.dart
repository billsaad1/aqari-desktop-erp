import 'package:app/core/internal_subledger_reconciliation_pdf.dart';
import 'package:app/models/internal_subledger_reconciliation_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds a printable Arabic internal reconciliation PDF', () async {
    final report = InternalSubledgerReconciliationReport(
      startDate: '2026-01-01',
      endDate: '2026-01-31',
      currency: 'SAR',
      rows: const [
        InternalSubledgerReconciliationRow(
          source: InternalSubledgerSource.tenantReceipt,
          sourceId: 501,
          sourceDate: '2026-01-12',
          partyName: 'مستأجر الاختبار',
          amountMinor: 11500,
          state: InternalSubledgerRowState.matched,
          issueSummary: '',
          journalEntryId: 701,
          journalDate: '2026-01-12',
          journalPosted: true,
          journalDebitMinor: 11500,
          journalCreditMinor: 11500,
          controlCreditMinor: 11500,
          allocatedMinor: 10000,
          allocationStatus: 'مخصص جزئيًا',
        ),
      ],
    );

    final bytes = await InternalSubledgerReconciliationPdf.build(
      report: report,
      rows: report.rows,
      filterLabel: 'كل الحالات',
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(report.unallocatedMinor, 1500);
    expect(report.unallocatedCount, 1);
  });
}
