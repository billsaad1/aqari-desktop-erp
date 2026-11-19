class FinancialPositionAccountRow {
  const FinancialPositionAccountRow({
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.accountType,
    required this.debitMinor,
    required this.creditMinor,
  });

  final int accountId;
  final String accountCode;
  final String accountName;
  final String accountType;
  final int debitMinor;
  final int creditMinor;

  bool get isClassified => const {
    'Asset',
    'Liability',
    'Equity',
    'Revenue',
    'Expense',
  }.contains(accountType);

  /// Positive amounts follow the normal balance for the known account type.
  int get normalBalanceMinor => switch (accountType) {
    'Liability' || 'Equity' || 'Revenue' => creditMinor - debitMinor,
    'Asset' || 'Expense' => debitMinor - creditMinor,
    _ => debitMinor - creditMinor,
  };

  String get typeLabel => switch (accountType) {
    'Asset' => 'أصول',
    'Liability' => 'خصوم',
    'Equity' => 'حقوق ملكية',
    'Revenue' => 'إيرادات',
    'Expense' => 'مصروفات',
    _ => 'غير مصنف',
  };
}

class FinancialPositionReport {
  FinancialPositionReport({
    required this.asOfDate,
    required this.currency,
    required List<FinancialPositionAccountRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String asOfDate;
  final String currency;
  final List<FinancialPositionAccountRow> rows;

  List<FinancialPositionAccountRow> get assetRows =>
      rows.where((row) => row.accountType == 'Asset').toList(growable: false);
  List<FinancialPositionAccountRow> get liabilityRows => rows
      .where((row) => row.accountType == 'Liability')
      .toList(growable: false);
  List<FinancialPositionAccountRow> get equityRows =>
      rows.where((row) => row.accountType == 'Equity').toList(growable: false);
  List<FinancialPositionAccountRow> get revenueRows =>
      rows.where((row) => row.accountType == 'Revenue').toList(growable: false);
  List<FinancialPositionAccountRow> get expenseRows =>
      rows.where((row) => row.accountType == 'Expense').toList(growable: false);
  List<FinancialPositionAccountRow> get unclassifiedRows =>
      rows.where((row) => !row.isClassified).toList(growable: false);

  int get assetsMinor =>
      assetRows.fold(0, (sum, row) => sum + row.normalBalanceMinor);
  int get liabilitiesMinor =>
      liabilityRows.fold(0, (sum, row) => sum + row.normalBalanceMinor);
  int get equityAccountsMinor =>
      equityRows.fold(0, (sum, row) => sum + row.normalBalanceMinor);
  int get revenuesMinor =>
      revenueRows.fold(0, (sum, row) => sum + row.normalBalanceMinor);
  int get expensesMinor =>
      expenseRows.fold(0, (sum, row) => sum + row.normalBalanceMinor);

  /// Cumulative posted revenue less expense balances not closed into equity.
  int get unclosedEarningsMinor => revenuesMinor - expensesMinor;
  int get equityIncludingUnclosedEarningsMinor =>
      equityAccountsMinor + unclosedEarningsMinor;
  int get liabilitiesAndEquityMinor =>
      liabilitiesMinor + equityIncludingUnclosedEarningsMinor;
  int get equationDifferenceMinor => assetsMinor - liabilitiesAndEquityMinor;
  bool get isAccountingEquationBalanced => equationDifferenceMinor == 0;
  bool get hasUnclassifiedAccounts => unclassifiedRows.isNotEmpty;
  bool get isReadyForReview =>
      isAccountingEquationBalanced && !hasUnclassifiedAccounts;
}
