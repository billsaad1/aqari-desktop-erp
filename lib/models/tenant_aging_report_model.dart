enum TenantAgingBucket { notDue, days0To30, days31To60, days61To90, days91Plus }

extension TenantAgingBucketLabel on TenantAgingBucket {
  String get label => switch (this) {
    TenantAgingBucket.notDue => 'غير مستحق',
    TenantAgingBucket.days0To30 => '0–30 يومًا',
    TenantAgingBucket.days31To60 => '31–60 يومًا',
    TenantAgingBucket.days61To90 => '61–90 يومًا',
    TenantAgingBucket.days91Plus => '91+ يومًا',
  };
}

class TenantAgingReportRow {
  const TenantAgingReportRow({
    required this.installmentId,
    required this.contractId,
    required this.tenantId,
    required this.tenantName,
    required this.propertyName,
    required this.unitNumber,
    required this.dueDate,
    required this.daysOverdue,
    required this.bucket,
    required this.obligationMinor,
    required this.paidMinor,
    required this.balanceMinor,
  });

  final int installmentId;
  final int contractId;
  final int tenantId;
  final String tenantName;
  final String propertyName;
  final String unitNumber;
  final String dueDate;
  final int daysOverdue;
  final TenantAgingBucket bucket;
  final int obligationMinor;
  final int paidMinor;
  final int balanceMinor;
}

class TenantAgingReviewException {
  const TenantAgingReviewException({
    required this.documentId,
    required this.documentDate,
    required this.documentType,
    required this.tenantName,
    required this.amountMinor,
    required this.reason,
  });

  final int documentId;
  final String documentDate;
  final String documentType;
  final String tenantName;
  final int amountMinor;
  final String reason;
}

class TenantAgingReport {
  TenantAgingReport({
    required this.asOfDate,
    required this.currency,
    required List<TenantAgingReportRow> rows,
    required List<TenantAgingReviewException> exceptions,
  }) : rows = List.unmodifiable(rows),
       exceptions = List.unmodifiable(exceptions);

  final String asOfDate;
  final String currency;
  final List<TenantAgingReportRow> rows;
  final List<TenantAgingReviewException> exceptions;

  int get totalOutstandingMinor =>
      rows.fold(0, (total, row) => total + row.balanceMinor);

  int totalFor(TenantAgingBucket bucket) => rows
      .where((row) => row.bucket == bucket)
      .fold(0, (total, row) => total + row.balanceMinor);

  int get notDueMinor => totalFor(TenantAgingBucket.notDue);
  int get days0To30Minor => totalFor(TenantAgingBucket.days0To30);
  int get days31To60Minor => totalFor(TenantAgingBucket.days31To60);
  int get days61To90Minor => totalFor(TenantAgingBucket.days61To90);
  int get days91PlusMinor => totalFor(TenantAgingBucket.days91Plus);
  int get exceptionAmountMinor =>
      exceptions.fold(0, (total, exception) => total + exception.amountMinor);
}
