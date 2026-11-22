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
    this.sourceConsistencyStatus = 'غير محدد',
    this.sourceMismatchCount = 0,
    required this.sourceReceiptVoucherIds,
    required this.linkedAllocationMinor,
    this.isCorrectionReversal = false,
    this.isVerifiedCorrectionReversal = false,
    this.replacementReceiptVoucherId,
    this.correctionReason,
  });

  final int voucherId;
  final String voucherDate;
  final int tenantId;
  final String tenantName;
  final bool isRefund;
  final bool isVerifiedRefund;
  final bool isCorrectionReversal;
  final bool isVerifiedCorrectionReversal;
  final int? replacementReceiptVoucherId;
  final String? correctionReason;

  /// Receipts are positive; refunds and correction reversals are negative.
  final int amountMinor;
  final String allocationStatus;
  final String sourceConsistencyStatus;
  final int sourceMismatchCount;
  final String sourceReceiptVoucherIds;
  final int linkedAllocationMinor;
}

class TenantCollectionReport {
  TenantCollectionReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<TenantCollectionReportRow> rows,
    this.tenantName,
    this.tenantId,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final String? tenantName;
  final int? tenantId;
  final List<TenantCollectionReportRow> rows;

  int get grossReceiptsMinor => rows
      .where((row) => !row.isRefund && row.amountMinor > 0)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get linkedRefundsMinor => -rows
      .where((row) => row.isRefund && row.isVerifiedRefund)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get linkedReceiptCorrectionsMinor => -rows
      .where(
        (row) => row.isCorrectionReversal && row.isVerifiedCorrectionReversal,
      )
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get unverifiedRefundsMinor => -rows
      .where((row) => row.isRefund && !row.isVerifiedRefund)
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get unverifiedCorrectionReversalsMinor => -rows
      .where(
        (row) => row.isCorrectionReversal && !row.isVerifiedCorrectionReversal,
      )
      .fold(0, (sum, row) => sum + row.amountMinor);
  int get unverifiedCorrectionReversalCount => rows
      .where(
        (row) => row.isCorrectionReversal && !row.isVerifiedCorrectionReversal,
      )
      .length;
  int get netCollectedMinor =>
      grossReceiptsMinor - linkedRefundsMinor - linkedReceiptCorrectionsMinor;
  int get unverifiedRefundCount =>
      rows.where((row) => row.isRefund && !row.isVerifiedRefund).length;
  int get sourceMismatchVoucherCount =>
      rows.where((row) => row.sourceMismatchCount > 0).length;
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
  int get receiptCount =>
      rows.where((row) => !row.isRefund && !row.isCorrectionReversal).length;
  int get linkedRefundCount =>
      rows.where((row) => row.isRefund && row.isVerifiedRefund).length;
}
