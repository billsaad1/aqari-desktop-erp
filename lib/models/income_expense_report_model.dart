class IncomeExpenseAccountRow {
  const IncomeExpenseAccountRow({
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

  int get netMinor => accountType == 'Revenue'
      ? creditMinor - debitMinor
      : debitMinor - creditMinor;
}

class IncomeExpenseReport {
  IncomeExpenseReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<IncomeExpenseAccountRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final List<IncomeExpenseAccountRow> rows;

  int get revenueDebitMinor => rows
      .where((row) => row.accountType == 'Revenue')
      .fold(0, (sum, row) => sum + row.debitMinor);
  int get revenueCreditMinor => rows
      .where((row) => row.accountType == 'Revenue')
      .fold(0, (sum, row) => sum + row.creditMinor);
  int get revenueNetMinor => rows
      .where((row) => row.accountType == 'Revenue')
      .fold(0, (sum, row) => sum + row.netMinor);
  int get expenseDebitMinor => rows
      .where((row) => row.accountType == 'Expense')
      .fold(0, (sum, row) => sum + row.debitMinor);
  int get expenseCreditMinor => rows
      .where((row) => row.accountType == 'Expense')
      .fold(0, (sum, row) => sum + row.creditMinor);
  int get expenseNetMinor => rows
      .where((row) => row.accountType == 'Expense')
      .fold(0, (sum, row) => sum + row.netMinor);

  int get netResultMinor => revenueNetMinor - expenseNetMinor;
}
