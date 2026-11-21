import 'package:app/core/account_statement_pdf.dart';
import 'package:app/models/account_statement_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account statement PDF builds with opening, totals and closing balance',
    () async {
      final report = AccountStatementReport(
        accountId: 101,
        accountCode: '1104',
        accountName: 'حساب أصول تجريبي',
        accountType: 'Asset',
        currency: 'SAR',
        startDate: '2026-02-01',
        endDate: '2026-02-28',
        openingBalance: 100,
        totalDebit: 30,
        totalCredit: 10,
        closingBalance: 120,
        lines: const [
          AccountStatementLine(
            date: '2026-02-01',
            journalEntryId: 77,
            description: 'حركة أول الفترة',
            debit: 30,
            credit: 0,
            runningBalance: 130,
          ),
          AccountStatementLine(
            date: '2026-02-28',
            journalEntryId: 81,
            description: 'حركة آخر الفترة',
            debit: 0,
            credit: 10,
            runningBalance: 120,
          ),
        ],
      );

      final bytes = await AccountStatementPdf.build(
        report: report,
        companyInfo: null,
        currency: 'ريال سعودي',
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    },
  );

  test(
    'tenant statement PDF uses the same valid ledger report payload',
    () async {
      final report = AccountStatementReport(
        accountId: 901,
        accountCode: '120901',
        accountName: 'ذمم المستأجر',
        accountType: 'Asset',
        currency: 'SAR',
        startDate: '2026-02-01',
        endDate: '2026-02-28',
        openingBalance: 250,
        totalDebit: 40,
        totalCredit: 15,
        closingBalance: 275,
        lines: const [],
      );
      final bytes = await AccountStatementPdf.build(
        report: report.forSelectedPeriodOnly(),
        companyInfo: null,
        currency: 'ريال سعودي',
        statementTitle: 'كشف حساب المستأجر',
        partyName: 'مستأجر للاختبار',
        accountLabel: 'حساب الذمم',
        periodOnly: true,
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    },
  );

  test('owner statement PDF labels the linked party as the owner', () async {
    final report = AccountStatementReport(
      accountId: 210101,
      accountCode: '210101',
      accountName: 'حساب المالك الجاري',
      accountType: 'Liability',
      currency: 'SAR',
      startDate: '2026-02-01',
      endDate: '2026-02-28',
      openingBalance: 250,
      totalDebit: 15,
      totalCredit: 40,
      closingBalance: 275,
      lines: const [],
    );
    final bytes = await AccountStatementPdf.build(
      report: report,
      companyInfo: null,
      currency: 'ريال سعودي',
      statementTitle: 'كشف حساب المالك',
      partyName: 'مالك للاختبار',
      partyLabel: 'المالك',
      accountLabel: 'حساب الملاك الجاري',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
