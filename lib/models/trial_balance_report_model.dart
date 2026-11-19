class TrialBalanceRow {
  const TrialBalanceRow({
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.accountType,
    required this.openingDebitMinor,
    required this.openingCreditMinor,
    required this.periodDebitMinor,
    required this.periodCreditMinor,
    required this.closingDebitMinor,
    required this.closingCreditMinor,
  });

  final int accountId;
  final String accountCode;
  final String accountName;
  final String accountType;
  final int openingDebitMinor;
  final int openingCreditMinor;
  final int periodDebitMinor;
  final int periodCreditMinor;
  final int closingDebitMinor;
  final int closingCreditMinor;

  factory TrialBalanceRow.fromMap(Map<String, dynamic> row) {
    int minor(String key) => (row[key] as num?)?.toInt() ?? 0;

    final openingNet =
        minor('opening_debit_minor') - minor('opening_credit_minor');
    final periodDebit = minor('period_debit_minor');
    final periodCredit = minor('period_credit_minor');
    final closingNet = openingNet + periodDebit - periodCredit;
    return TrialBalanceRow(
      accountId: (row['account_id'] as num).toInt(),
      accountCode: row['account_code']?.toString() ?? '',
      accountName: row['account_name']?.toString() ?? '',
      accountType: row['account_type']?.toString() ?? '',
      openingDebitMinor: openingNet > 0 ? openingNet : 0,
      openingCreditMinor: openingNet < 0 ? -openingNet : 0,
      periodDebitMinor: periodDebit,
      periodCreditMinor: periodCredit,
      closingDebitMinor: closingNet > 0 ? closingNet : 0,
      closingCreditMinor: closingNet < 0 ? -closingNet : 0,
    );
  }
}

class TrialBalanceReport {
  TrialBalanceReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<TrialBalanceRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final List<TrialBalanceRow> rows;

  int get openingDebitMinor =>
      rows.fold(0, (sum, row) => sum + row.openingDebitMinor);
  int get openingCreditMinor =>
      rows.fold(0, (sum, row) => sum + row.openingCreditMinor);
  int get periodDebitMinor =>
      rows.fold(0, (sum, row) => sum + row.periodDebitMinor);
  int get periodCreditMinor =>
      rows.fold(0, (sum, row) => sum + row.periodCreditMinor);
  int get closingDebitMinor =>
      rows.fold(0, (sum, row) => sum + row.closingDebitMinor);
  int get closingCreditMinor =>
      rows.fold(0, (sum, row) => sum + row.closingCreditMinor);

  bool get openingIsBalanced => openingDebitMinor == openingCreditMinor;
  bool get periodIsBalanced => periodDebitMinor == periodCreditMinor;
  bool get closingIsBalanced => closingDebitMinor == closingCreditMinor;
}
