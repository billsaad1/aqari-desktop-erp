import 'package:app/core/tenant_aging_report_pdf.dart';
import 'package:app/models/tenant_aging_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'builds Arabic Cairo RTL PDF with bucket totals and review exceptions',
    () async {
      final rows = List.generate(
        72,
        (index) => TenantAgingReportRow(
          installmentId: index + 1,
          contractId: 7,
          tenantId: index + 20,
          tenantName: index.isEven
              ? 'مستأجر تجريبي $index'
              : 'مستأجرة عربية $index',
          propertyName: 'عقار التقرير',
          unitNumber: 'وحدة-${index + 1}',
          dueDate: '2026-03-01',
          daysOverdue: 121,
          bucket: TenantAgingBucket.days91Plus,
          obligationMinor: 12500,
          paidMinor: 2500,
          balanceMinor: 10000,
        ),
      );
      final report = TenantAgingReport(
        asOfDate: '2026-06-30',
        currency: 'SAR',
        rows: rows,
        exceptions: const [
          TenantAgingReviewException(
            documentId: 501,
            documentDate: '2026-06-20',
            documentType: 'قبض',
            tenantName: 'مستأجر استثناء',
            amountMinor: 7500,
            reason: 'سجل تاريخي غير متسق؛ للمراجعة فقط.',
          ),
          TenantAgingReviewException(
            documentId: 502,
            documentDate: '2026-06-21',
            documentType: 'استرداد',
            tenantName: 'مستأجر استثناء',
            amountMinor: 1200,
            reason: 'استرداد بلا مصدر موثق.',
          ),
        ],
      );

      final bytes = await TenantAgingReportPdf.build(
        report: report,
        companyInfo: {'name_ar': 'شركة اختبار عربية'},
        currency: 'ريال سعودي',
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(report.asOfDate, '2026-06-30');
      expect(report.days91PlusMinor, 720000);
      expect(report.totalOutstandingMinor, 720000);
      expect(report.exceptionAmountMinor, 8700);
      final pdfText = String.fromCharCodes(bytes);
      final pageCount = RegExp(
        r'/Type\s*/Page(?!s)',
      ).allMatches(pdfText).length;
      expect(
        pageCount,
        greaterThan(1),
        reason: 'long Arabic tables must paginate',
      );
    },
  );
}
