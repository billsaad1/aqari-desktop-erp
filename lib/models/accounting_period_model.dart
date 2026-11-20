import 'financial_close_readiness_report_model.dart';

class AccountingPeriod {
  const AccountingPeriod({
    required this.id,
    required this.startDate,
    required this.endDate,
    required this.status,
    required this.createdAt,
    required this.createdByUserId,
  });

  final int id;
  final String startDate;
  final String endDate;
  final String status;
  final String createdAt;
  final int createdByUserId;

  String get statusLabel => switch (status) {
    'open' => 'مفتوحة',
    'locked' => 'مقفلة للترحيل',
    'closed' => 'مقفلة نهائيًا',
    _ => 'حالة غير معروفة',
  };

  factory AccountingPeriod.fromMap(Map<String, Object?> row) =>
      AccountingPeriod(
        id: (row['id'] as num).toInt(),
        startDate: row['start_date']?.toString() ?? '',
        endDate: row['end_date']?.toString() ?? '',
        status: row['status']?.toString() ?? 'open',
        createdAt: row['created_at']?.toString() ?? '',
        createdByUserId: (row['created_by_user_id'] as num).toInt(),
      );
}

class AccountingPeriodEvent {
  const AccountingPeriodEvent({
    required this.id,
    required this.periodId,
    required this.action,
    required this.actorUserId,
    required this.actorName,
    required this.reason,
    required this.readinessSummary,
    required this.createdAt,
  });

  final int id;
  final int periodId;
  final String action;
  final int actorUserId;
  final String actorName;
  final String? reason;
  final String? readinessSummary;
  final String createdAt;

  String get actionLabel => switch (action) {
    'created' => 'إنشاء الفترة',
    'locked' => 'قفل الفترة',
    'closed' => 'الإقفال النهائي',
    'reopened' => 'إعادة فتح الفترة',
    _ => 'حدث غير معروف',
  };

  factory AccountingPeriodEvent.fromMap(Map<String, Object?> row) =>
      AccountingPeriodEvent(
        id: (row['id'] as num).toInt(),
        periodId: (row['period_id'] as num).toInt(),
        action: row['action']?.toString() ?? '',
        actorUserId: (row['actor_user_id'] as num).toInt(),
        actorName: row['actor_name']?.toString() ?? '',
        reason: row['reason']?.toString(),
        readinessSummary: row['readiness_summary']?.toString(),
        createdAt: row['created_at']?.toString() ?? '',
      );
}

class AccountingPeriodReadiness {
  const AccountingPeriodReadiness({
    required this.period,
    required this.report,
  });

  final AccountingPeriod period;
  final FinancialCloseReadinessReport report;
}
