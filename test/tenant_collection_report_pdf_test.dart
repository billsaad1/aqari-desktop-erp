import 'package:app/core/tenant_collection_report_pdf.dart';
import 'package:app/models/tenant_collection_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'builds Arabic tenant collection PDF with signed linked refunds',
    () async {
      final report = TenantCollectionReport(
        startDate: '2026-02-01',
        endDate: '2026-02-28',
        currency: 'SAR',
        rows: const [
          TenantCollectionReportRow(
            voucherId: 100,
            voucherDate: '2026-02-10',
            tenantId: 10,
            tenantName: 'مستأجر تجريبي',
            isRefund: false,
            isVerifiedRefund: false,
            amountMinor: 10000,
            allocationStatus: 'التخصيص مطابق',
            sourceReceiptVoucherIds: '',
            linkedAllocationMinor: 10000,
          ),
          TenantCollectionReportRow(
            voucherId: 101,
            voucherDate: '2026-02-12',
            tenantId: 10,
            tenantName: 'مستأجر تجريبي',
            isRefund: true,
            isVerifiedRefund: true,
            amountMinor: -2500,
            allocationStatus: 'مرتبط ومطابق',
            sourceReceiptVoucherIds: '100',
            linkedAllocationMinor: 2500,
          ),
          TenantCollectionReportRow(
            voucherId: 102,
            voucherDate: '2026-02-14',
            tenantId: 10,
            tenantName: 'مستأجر تجريبي',
            isRefund: true,
            isVerifiedRefund: false,
            amountMinor: -1000,
            allocationStatus: 'يحتاج مراجعة',
            sourceReceiptVoucherIds: '100',
            linkedAllocationMinor: 500,
          ),
        ],
      );

      final bytes = await TenantCollectionReportPdf.build(
        report: report,
        companyInfo: null,
        currency: 'ريال سعودي',
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(report.grossReceiptsMinor, 10000);
      expect(report.linkedRefundsMinor, 2500);
      expect(report.unverifiedRefundsMinor, 1000);
      expect(report.netCollectedMinor, 7500);
    },
  );
}
