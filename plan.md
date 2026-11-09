1. **Create Utility for Printing Vouchers**:
   - Instead of duplicating code in both `tenant_receipt_screen.dart` and `tenant_payment_screen.dart`, create a helper method `PrintUtils.printVoucher(...)` in a new file `lib/core/print_utils.dart` that handles fetching company info, loading Arabic fonts, and generating the PDF layout for a voucher (supporting both Receipt and Payment). Include `logoPath` handling.
2. **Update `TenantReceiptScreen`**:
   - Make `DatabaseHelper.instance.insertTenantReceiptVoucher` return the `voucherId` so we know the voucher number to print. (Modify `database_helper.dart` as well).
   - In `_processReceipt()`, after successful save, immediately call `PrintUtils.printVoucher(...)` passing the details (voucher no, date, tenant name, amount, description/type).
3. **Update `TenantPaymentScreen`**:
   - Make `DatabaseHelper.instance.insertTenantPaymentVoucher` return the `voucherId`.
   - In `_processPayment()`, call `PrintUtils.printVoucher(...)` similarly.
4. **Update `AccountStatementScreen` and `OccupancyReportScreen` and `TaxInvoiceScreen`**:
   - Update their PDF generation logic to dynamically fetch `company_info` (name, address, tax number, logo_path) to construct the unified letterhead, similar to what was done for contracts.
5. **Execute Pre-commit instructions**: Run `flutter analyze` and `flutter test`. Skip playwright.
6. **Submit changes**.
