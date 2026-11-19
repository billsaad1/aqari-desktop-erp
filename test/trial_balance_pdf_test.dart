import 'package:app/core/trial_balance_pdf.dart';
import 'package:app/models/trial_balance_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds an Arabic landscape trial balance PDF', () async {
    final report = TrialBalanceReport(
      startDate: '2026-02-01',
      endDate: '2026-02-28',
      currency: 'SAR',
      rows: const [
        TrialBalanceRow(
          accountId: 10,
          accountCode: '1101',
          accountName: 'الصندوق الرئيسي',
          accountType: 'Asset',
          openingDebitMinor: 10000,
          openingCreditMinor: 0,
          periodDebitMinor: 2500,
          periodCreditMinor: 0,
          closingDebitMinor: 12500,
          closingCreditMinor: 0,
        ),
        TrialBalanceRow(
          accountId: 20,
          accountCode: '4101',
          accountName: 'الإيراد',
          accountType: 'Revenue',
          openingDebitMinor: 0,
          openingCreditMinor: 10000,
          periodDebitMinor: 0,
          periodCreditMinor: 2500,
          closingDebitMinor: 0,
          closingCreditMinor: 12500,
        ),
      ],
    );

    final bytes = await TrialBalancePdf.build(
      report: report,
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
