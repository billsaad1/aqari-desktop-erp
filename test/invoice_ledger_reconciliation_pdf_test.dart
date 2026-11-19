import 'package:app/core/invoice_ledger_reconciliation_pdf.dart';
import 'package:app/models/invoice_ledger_reconciliation_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'builds Arabic landscape invoice-to-ledger reconciliation PDF',
    () async {
      final matched = InvoiceLedgerReconciliationRow.fromMap({
        'invoice_id': 301,
        'invoice_date': '2026-03-01',
        'tenant_name': 'مستأجر مطابق',
        'tenant_account_id': 51,
        'net_minor': 10000,
        'tax_minor': 1500,
        'total_minor': 11500,
        'tax_account_id': 2103,
        'installment_amount_minor': 10000,
        'journal_entry_id': 9001,
        'journal_entry_exists': 1,
        'journal_is_posted': 1,
        'linked_invoice_count': 1,
        'journal_debit_minor': 11500,
        'journal_credit_minor': 11500,
        'tenant_receivable_debit_minor': 11500,
        'revenue_credit_minor': 10000,
        'tax_liability_credit_minor': 1500,
      });
      final needsReview = InvoiceLedgerReconciliationRow.fromMap({
        'invoice_id': 302,
        'invoice_date': '2026-03-02',
        'tenant_name': 'مستأجر للمراجعة',
        'tenant_account_id': 52,
        'net_minor': 5000,
        'tax_minor': 0,
        'total_minor': 5000,
        'journal_entry_id': null,
        'journal_entry_exists': 0,
        'journal_is_posted': 0,
        'linked_invoice_count': 0,
        'journal_debit_minor': 0,
        'journal_credit_minor': 0,
        'tenant_receivable_debit_minor': 0,
        'revenue_credit_minor': 0,
        'tax_liability_credit_minor': 0,
      });
      final report = InvoiceLedgerReconciliationReport(
        startDate: '2026-03-01',
        endDate: '2026-03-31',
        currency: 'SAR',
        rows: [matched, needsReview],
      );

      final bytes = await InvoiceLedgerReconciliationPdf.build(
        report: report,
        rows: report.rows,
        filterLabel: 'كل الفواتير',
        companyInfo: null,
        currency: 'ريال سعودي',
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(report.reconciledCount, 1);
      expect(report.reviewCount, 1);
      expect(needsReview.issueSummary, contains('الفاتورة بلا رابط قيد'));
    },
  );
}
