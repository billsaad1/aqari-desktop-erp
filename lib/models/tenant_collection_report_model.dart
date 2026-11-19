class TenantCollectionReportRow {
  const TenantCollectionReportRow({
    required this.voucherId,
    required this.voucherDate,
    required this.tenantId,
    required this.tenantName,
    required this.isRefund,
    required this.isVerifiedRefund,
    required this.amountMinor,
    required this.allocationStatus,
    required this.sourceReceiptVoucherIds,
    required this.linkedAllocationMinor,
  });

  final int voucherId;
  final String voucherDate;
  final int tenantId;
  final String tenantName;
  final bool isRefund;
  final bool isVerifiedRefund;

  /// Receipts are positive; source-linked refunds are negative.
  final int amountMinor;
  final String allocationStatus;
  final String sourceReceiptVoucherIds;
  final int linkedAllocationMinor;
}

class TenantCollectionReport {
  TenantCollectionReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<TenantCollectionReportRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final List<TenantCollectionReportRow> rows;

  int get grossReceiptsMinor => rows
      .where((row) => !row.isRefund && row.amountMinor > 0)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get linkedRefundsMinor => -rows
      .where((row) => row.isRefund && row.isVerifiedRefund)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get unverifiedRefundsMinor => -rows
      .where((row) => row.isRefund && !row.isVerifiedRefund)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get netCollectedMinor => grossReceiptsMinor - linkedRefundsMinor;
  int get unverifiedRefundCount =>
      rows.where((row) => row.isRefund && !row.isVerifiedRefund).length;
  int get unallocatedReceiptsMinor => rows
      .where((row) => !row.isRefund && row.amountMinor > 0)
      .fold(
        0,
        (sum, row) =>
            sum +
            (row.amountMinor - row.linkedAllocationMinor).clamp(
              0,
              row.amountMinor,
            ),
      );
  int get receiptCount => rows.where((row) => !row.isRefund).length;
  int get linkedRefundCount =>
      rows.where((row) => row.isRefund && row.isVerifiedRefund).length;
}
