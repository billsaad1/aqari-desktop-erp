import 'package:app/core/property_statement_pdf.dart';
import 'package:app/models/property_statement_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

PropertyStatementReport _report({
  int? costCenterId = 7,
  List<PropertyStatementLine> lines = const [],
  List<PropertyStatementGap> gaps = const [],
}) => PropertyStatementReport(
  propertyId: 3,
  propertyName: 'عقار النخيل',
  ownerName: 'مالك النخيل',
  costCenterId: costCenterId,
  costCenterCode: 'CC-7',
  costCenterName: 'النخيل',
  currency: 'SAR',
  startDate: '2026-01-01',
  endDate: '2026-01-31',
  openingBalanceMinor: 0,
  totalDebitMinor: 0,
  totalCreditMinor: 150000,
  closingBalanceMinor: -150000,
  lines: lines,
  gaps: gaps,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds an Arabic property statement PDF with movements', () async {
    final bytes = await PropertyStatementPdf.build(
      report: _report(
        lines: const [
          PropertyStatementLine(
            date: '2026-01-10',
            journalEntryId: 5,
            journalLineId: 9,
            accountCode: '4101',
            accountName: 'إيراد إيجار',
            description: 'إيجار يناير',
            debitMinor: 0,
            creditMinor: 150000,
            runningBalanceMinor: -150000,
          ),
        ],
      ),
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('builds a PDF for a property without a cost centre', () async {
    final bytes = await PropertyStatementPdf.build(
      report: _report(
        costCenterId: null,
        gaps: const [
          PropertyStatementGap(
            reason: PropertyStatementGapReason.propertyWithoutCostCenter,
            lineCount: 2,
            debitMinor: 50000,
            creditMinor: 50000,
          ),
        ],
      ),
      companyInfo: null,
      currency: 'ريال سعودي',
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
