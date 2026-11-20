enum InternalSubledgerSource {
  invoice,
  tenantReceipt,
  tenantRefund,
  ownerSettlement,
  legacyOwnerVoucher,
  generalVoucher,
  creditNote,
  creditNoteReversal,
  directJournal,
}

extension InternalSubledgerSourceLabel on InternalSubledgerSource {
  String get label => switch (this) {
    InternalSubledgerSource.invoice => 'فاتورة مستأجر',
    InternalSubledgerSource.tenantReceipt => 'قبض مستأجر',
    InternalSubledgerSource.tenantRefund => 'رد مستأجر',
    InternalSubledgerSource.ownerSettlement => 'سداد مستحقات مالك',
    InternalSubledgerSource.legacyOwnerVoucher => 'سند مالك تاريخي',
    InternalSubledgerSource.generalVoucher => 'سند عام على حساب فرعي',
    InternalSubledgerSource.creditNote => 'إشعار دائن',
    InternalSubledgerSource.creditNoteReversal => 'عكس إشعار دائن',
    InternalSubledgerSource.directJournal => 'قيد أستاذ بلا مستند فرعي',
  };
}

enum InternalSubledgerRowState { matched, needsReview, notPosted, legacyReview }

extension InternalSubledgerRowStateLabel on InternalSubledgerRowState {
  String get label => switch (this) {
    InternalSubledgerRowState.matched => 'مطابق مع الأستاذ',
    InternalSubledgerRowState.needsReview => 'يحتاج مراجعة',
    InternalSubledgerRowState.notPosted => 'غير مرحّل',
    InternalSubledgerRowState.legacyReview => 'تاريخي للمراجعة',
  };
}

class InternalSubledgerReconciliationRow {
  const InternalSubledgerReconciliationRow({
    required this.source,
    required this.sourceId,
    required this.sourceDate,
    required this.partyName,
    required this.amountMinor,
    required this.state,
    required this.issueSummary,
    this.journalEntryId,
    this.journalDate,
    this.journalPosted = false,
    this.journalDebitMinor = 0,
    this.journalCreditMinor = 0,
    this.controlDebitMinor = 0,
    this.controlCreditMinor = 0,
    this.allocatedMinor,
    this.allocationStatus,
  });

  final InternalSubledgerSource source;
  final int sourceId;
  final String sourceDate;
  final String partyName;
  final int amountMinor;
  final InternalSubledgerRowState state;
  final String issueSummary;
  final int? journalEntryId;
  final String? journalDate;
  final bool journalPosted;
  final int journalDebitMinor;
  final int journalCreditMinor;
  final int controlDebitMinor;
  final int controlCreditMinor;
  final int? allocatedMinor;
  final String? allocationStatus;

  bool get isLedgerMatched => state == InternalSubledgerRowState.matched;
  bool get hasReviewablePostedJournal =>
      journalEntryId != null &&
      journalPosted &&
      journalDate != null &&
      journalDate!.isNotEmpty &&
      journalDebitMinor > 0 &&
      journalDebitMinor == journalCreditMinor;

  bool get requiresManualAcknowledgement {
    if (state == InternalSubledgerRowState.legacyReview) {
      return journalEntryId == null || hasReviewablePostedJournal;
    }
    if (state != InternalSubledgerRowState.needsReview ||
        !hasReviewablePostedJournal) return false;
    return source == InternalSubledgerSource.directJournal ||
        source == InternalSubledgerSource.generalVoucher;
  }

  int get unallocatedMinor => allocatedMinor == null
      ? 0
      : (amountMinor - allocatedMinor!).clamp(0, amountMinor).toInt();

  factory InternalSubledgerReconciliationRow.fromMap(
    Map<String, Object?> row,
  ) {
    int value(String key) => (row[key] as num?)?.toInt() ?? 0;
    int? optional(String key) => (row[key] as num?)?.toInt();
    final source = InternalSubledgerSource.values.firstWhere(
      (item) => item.name == row['source_kind']?.toString(),
      orElse: () => InternalSubledgerSource.directJournal,
    );
    final state = InternalSubledgerRowState.values.firstWhere(
      (item) => item.name == row['row_state']?.toString(),
      orElse: () => InternalSubledgerRowState.needsReview,
    );
    return InternalSubledgerReconciliationRow(
      source: source,
      sourceId: value('source_id'),
      sourceDate: row['source_date']?.toString() ?? '',
      partyName: row['party_name']?.toString() ?? '',
      amountMinor: value('amount_minor'),
      state: state,
      issueSummary: row['issue_summary']?.toString() ?? '',
      journalEntryId: optional('journal_entry_id'),
      journalDate: row['journal_date']?.toString(),
      journalPosted: value('journal_posted') == 1,
      journalDebitMinor: value('journal_debit_minor'),
      journalCreditMinor: value('journal_credit_minor'),
      controlDebitMinor: value('control_debit_minor'),
      controlCreditMinor: value('control_credit_minor'),
      allocatedMinor: optional('allocated_minor'),
      allocationStatus: row['allocation_status']?.toString(),
    );
  }
}

class InternalSubledgerReconciliationReport {
  InternalSubledgerReconciliationReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<InternalSubledgerReconciliationRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final List<InternalSubledgerReconciliationRow> rows;

  int get matchedCount => rows.where((row) => row.isLedgerMatched).length;
  int get reviewCount => rows.length - matchedCount;
  int get unallocatedCount => rows
      .where((row) => row.unallocatedMinor > 0)
      .length;
  int get unallocatedMinor => rows.fold(
    0,
    (sum, row) => sum + row.unallocatedMinor,
  );
  int get legacyReviewCount => rows
      .where((row) => row.state == InternalSubledgerRowState.legacyReview)
      .length;
  int get directJournalCount => rows
      .where((row) => row.source == InternalSubledgerSource.directJournal)
      .length;
}
