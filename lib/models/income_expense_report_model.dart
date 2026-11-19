class IncomeExpenseCostCenter {
  const IncomeExpenseCostCenter({
    required this.id,
    required this.code,
    required this.name,
  });

  final int id;
  final String code;
  final String name;

  String get label => code.trim().isEmpty ? name : '$code - $name';
}

class IncomeExpenseAccountRow {
  const IncomeExpenseAccountRow({
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.accountType,
    required this.debitMinor,
    required this.creditMinor,
    this.costCenterId,
    this.costCenterCode,
    this.costCenterName,
  });

  final int accountId;
  final String accountCode;
  final String accountName;
  final String accountType;
  final int debitMinor;
  final int creditMinor;
  final int? costCenterId;
  final String? costCenterCode;
  final String? costCenterName;

  String get costCenterLabel {
    if (costCenterId == null) return 'غير مخصص';
    final name = costCenterName?.trim() ?? '';
    if (name.isEmpty) return 'مركز غير معروف (#$costCenterId)';
    final code = costCenterCode?.trim() ?? '';
    return code.isEmpty ? name : '$code - $name';
  }

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
    List<IncomeExpenseCostCenter> costCenters = const [],
    this.costCenterFilterKey = 'all',
    this.costCenterFilterLabel = 'كل مراكز التكلفة',
  }) : rows = List.unmodifiable(rows),
       costCenters = List.unmodifiable(costCenters);

  final String startDate;
  final String endDate;
  final String currency;
  final List<IncomeExpenseAccountRow> rows;
  final List<IncomeExpenseCostCenter> costCenters;
  final String costCenterFilterKey;
  final String costCenterFilterLabel;

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

  IncomeExpenseReport withCostCenterFilter({
    required List<IncomeExpenseAccountRow> filteredRows,
    required String filterKey,
    required String filterLabel,
  }) => IncomeExpenseReport(
    startDate: startDate,
    endDate: endDate,
    currency: currency,
    rows: filteredRows,
    costCenters: costCenters,
    costCenterFilterKey: filterKey,
    costCenterFilterLabel: filterLabel,
  );
}
