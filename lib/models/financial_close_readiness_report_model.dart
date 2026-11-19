class FinancialCloseEntryIssue {
  const FinancialCloseEntryIssue({
    required this.journalEntryId,
    required this.entryDate,
    required this.description,
    required this.debitMinor,
    required this.creditMinor,
    required this.lineCount,
    required this.isPosted,
  });

  final int journalEntryId;
  final String entryDate;
  final String description;
  final int debitMinor;
  final int creditMinor;
  final int lineCount;
  final bool isPosted;

  int get differenceMinor => debitMinor - creditMinor;
  bool get hasNoLines => lineCount == 0;
  String get statusLabel {
    if (!isPosted) return 'قيد غير مرحّل';
    if (hasNoLines) return 'قيد مرحّل بلا سطور';
    return 'قيد مرحّل غير متوازن';
  }

  factory FinancialCloseEntryIssue.fromMap(
    Map<String, Object?> row, {
    required bool isPosted,
  }) => FinancialCloseEntryIssue(
    journalEntryId: (row['journal_entry_id'] as num).toInt(),
    entryDate: row['entry_date']?.toString() ?? '',
    description: row['description']?.toString() ?? '',
    debitMinor: (row['debit_minor'] as num?)?.toInt() ?? 0,
    creditMinor: (row['credit_minor'] as num?)?.toInt() ?? 0,
    lineCount: (row['line_count'] as num?)?.toInt() ?? 0,
    isPosted: isPosted,
  );
}

class FinancialCloseReadinessReport {
  FinancialCloseReadinessReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<FinancialCloseEntryIssue> unpostedEntries,
    required List<FinancialCloseEntryIssue> unbalancedPostedEntries,
  }) : unpostedEntries = List.unmodifiable(unpostedEntries),
       unbalancedPostedEntries = List.unmodifiable(unbalancedPostedEntries);

  final String startDate;
  final String endDate;
  final String currency;
  final List<FinancialCloseEntryIssue> unpostedEntries;
  final List<FinancialCloseEntryIssue> unbalancedPostedEntries;

  bool get hasBlockingIssues =>
      unpostedEntries.isNotEmpty || unbalancedPostedEntries.isNotEmpty;
  bool get isReadyForManualReview => !hasBlockingIssues;
  int get unpostedDebitMinor =>
      unpostedEntries.fold(0, (sum, row) => sum + row.debitMinor);
  int get unpostedCreditMinor =>
      unpostedEntries.fold(0, (sum, row) => sum + row.creditMinor);
}
