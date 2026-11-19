class TenantStatementAccount {
  const TenantStatementAccount({
    required this.tenantId,
    required this.tenantName,
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.isReportable,
  });

  final int tenantId;
  final String tenantName;
  final int? accountId;
  final String? accountCode;
  final String? accountName;
  final bool isReportable;

  factory TenantStatementAccount.fromMap(Map<String, dynamic> row) {
    final accountId = (row['account_id'] as num?)?.toInt();
    final reportable = (row['is_reportable'] as num?)?.toInt() == 1;
    return TenantStatementAccount(
      tenantId: (row['id'] as num).toInt(),
      tenantName: row['name']?.toString() ?? '',
      accountId: accountId,
      accountCode: row['account_code']?.toString(),
      accountName: row['account_name']?.toString(),
      isReportable: reportable && accountId != null,
    );
  }
}
