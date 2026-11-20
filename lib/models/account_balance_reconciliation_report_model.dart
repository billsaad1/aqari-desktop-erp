class AccountBalanceReconciliationRow {
  const AccountBalanceReconciliationRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.accountType,
    required this.storedBalanceMinor,
    required this.ledgerBalanceMinor,
    required this.isSupportedAccountType,
  });

  final int accountId;
  final String code;
  final String name;
  final String accountType;
  final int storedBalanceMinor;
  final int ledgerBalanceMinor;
  final bool isSupportedAccountType;

  int get differenceMinor => storedBalanceMinor - ledgerBalanceMinor;
  bool get isReconciled => isSupportedAccountType && differenceMinor == 0;

  factory AccountBalanceReconciliationRow.fromMap(Map<String, Object?> row) {
    int minor(String key) => (row[key] as num?)?.toInt() ?? 0;
    final type = row['account_type']?.toString() ?? '';
    return AccountBalanceReconciliationRow(
      accountId: (row['account_id'] as num).toInt(),
      code: row['account_code']?.toString() ?? '',
      name: row['account_name']?.toString() ?? '',
      accountType: type,
      storedBalanceMinor: minor('stored_balance_minor'),
      ledgerBalanceMinor: minor('ledger_balance_minor'),
      isSupportedAccountType: const {
        'Asset',
        'Liability',
        'Equity',
        'Revenue',
        'Expense',
      }.contains(type),
    );
  }
}

class AccountBalanceReconciliationReport {
  AccountBalanceReconciliationReport({
    required List<AccountBalanceReconciliationRow> rows,
  }) : rows = List.unmodifiable(rows);

  final List<AccountBalanceReconciliationRow> rows;

  int get reconciledCount => rows.where((row) => row.isReconciled).length;
  int get reviewCount => rows.length - reconciledCount;
}
