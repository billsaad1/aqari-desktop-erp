class OwnerStatementAccount {
  const OwnerStatementAccount({
    required this.ownerId,
    required this.ownerName,
    required this.accountId,
    required this.accountCode,
    required this.accountName,
    required this.isReportable,
  });

  final int ownerId;
  final String ownerName;
  final int? accountId;
  final String? accountCode;
  final String? accountName;
  final bool isReportable;

  factory OwnerStatementAccount.fromMap(Map<String, dynamic> row) {
    final accountId = (row['account_id'] as num?)?.toInt();
    final reportable = (row['is_reportable'] as num?)?.toInt() == 1;
    return OwnerStatementAccount(
      ownerId: (row['id'] as num).toInt(),
      ownerName: row['name']?.toString() ?? '',
      accountId: accountId,
      accountCode: row['account_code']?.toString(),
      accountName: row['account_name']?.toString(),
      isReportable: reportable && accountId != null,
    );
  }
}
