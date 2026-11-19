import 'package:app/core/financial_position_pdf.dart';
import 'package:app/models/financial_position_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds Arabic financial-position PDF without balancing plug', () async {
    final report = FinancialPositionReport(
      asOfDate: '2026-06-30',
      currency: 'SAR',
      rows: const [
        FinancialPositionAccountRow(
          accountId: 1,
          accountCode: '1101',
          accountName: 'الصندوق الرئيسي',
          accountType: 'Asset',
          debitMinor: 115000,
          creditMinor: 0,
        ),
        FinancialPositionAccountRow(
          accountId: 2,
          accountCode: '3',
          accountName: 'رأس المال',
          accountType: 'Equity',
          debitMinor: 0,
          creditMinor: 100000,
        ),
        FinancialPositionAccountRow(
          accountId: 3,
          accountCode: '4101',
          accountName: 'إيراد إيجار',
          accountType: 'Revenue',
          debitMinor: 0,
          creditMinor: 20000,
        ),
        FinancialPositionAccountRow(
          accountId: 4,
          accountCode: '5101',
          accountName: 'مصروف إداري',
          accountType: 'Expense',
          debitMinor: 5000,
          creditMinor: 0,
        ),
      ],
    );

    final bytes = await FinancialPositionPdf.build(
      report: report,
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(report.equationDifferenceMinor, 0);
    expect(report.equityIncludingUnclosedEarningsMinor, 115000);
  });
}
