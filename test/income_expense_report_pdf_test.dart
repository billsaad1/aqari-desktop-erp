import 'package:app/core/income_expense_report_pdf.dart';
import 'package:app/models/income_expense_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds an Arabic period income and expense PDF', () async {
    final report = IncomeExpenseReport(
      startDate: '2026-02-01',
      endDate: '2026-02-28',
      currency: 'SAR',
      costCenters: const [
        IncomeExpenseCostCenter(id: 10, code: 'CC-01', name: 'مركز الإيرادات'),
      ],
      costCenterFilterLabel: 'كل مراكز التكلفة',
      rows: const [
        IncomeExpenseAccountRow(
          accountId: 10,
          accountCode: '4101',
          accountName: 'إيراد إيجار',
          accountType: 'Revenue',
          debitMinor: 500,
          creditMinor: 8000,
          costCenterId: 10,
          costCenterCode: 'CC-01',
          costCenterName: 'مركز الإيرادات',
        ),
        IncomeExpenseAccountRow(
          accountId: 20,
          accountCode: '5101',
          accountName: 'مصروف صيانة',
          accountType: 'Expense',
          debitMinor: 2500,
          creditMinor: 500,
        ),
      ],
    );

    final bytes = await IncomeExpenseReportPdf.build(
      report: report,
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(report.revenueNetMinor, 7500);
    expect(report.expenseNetMinor, 2000);
    expect(report.netResultMinor, 5500);
    expect(report.rows.first.costCenterLabel, 'CC-01 - مركز الإيرادات');
  });
}
