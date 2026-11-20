import 'package:app/models/internal_subledger_reconciliation_report_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const balancedDirectJournal = InternalSubledgerReconciliationRow(
    source: InternalSubledgerSource.directJournal,
    sourceId: 10,
    sourceDate: '2026-01-12',
    partyName: 'قيد مباشر',
    amountMinor: 5000,
    state: InternalSubledgerRowState.needsReview,
    issueSummary: 'لا يوجد ربط صريح بمستند فرعي',
    journalEntryId: 10,
    journalDate: '2026-01-12',
    journalPosted: true,
    journalDebitMinor: 5000,
    journalCreditMinor: 5000,
  );

  test('acknowledgement requires a posted balanced direct journal', () {
    expect(balancedDirectJournal.requiresManualAcknowledgement, isTrue);
    expect(
      balancedDirectJournal.copyWithForTest(
        journalPosted: false,
      ).requiresManualAcknowledgement,
      isFalse,
    );
    expect(
      balancedDirectJournal.copyWithForTest(
        journalCreditMinor: 4000,
      ).requiresManualAcknowledgement,
      isFalse,
    );
  });

  test('legacy item without a journal needs acknowledgement', () {
    const legacyVoucher = InternalSubledgerReconciliationRow(
      source: InternalSubledgerSource.legacyOwnerVoucher,
      sourceId: 20,
      sourceDate: '2026-01-20',
      partyName: 'سند تاريخي',
      amountMinor: 7500,
      state: InternalSubledgerRowState.legacyReview,
      issueSummary: 'لا يُستنتج المالك أو القيد',
    );
    expect(legacyVoucher.requiresManualAcknowledgement, isTrue);
    expect(
      legacyVoucher.copyWithForTest(
        journalEntryId: 20,
        journalDate: '2026-01-20',
        journalPosted: false,
        journalDebitMinor: 7500,
        journalCreditMinor: 7500,
      ).requiresManualAcknowledgement,
      isFalse,
    );
  });
}

extension on InternalSubledgerReconciliationRow {
  InternalSubledgerReconciliationRow copyWithForTest({
    int? journalEntryId,
    String? journalDate,
    bool? journalPosted,
    int? journalDebitMinor,
    int? journalCreditMinor,
  }) =>
      InternalSubledgerReconciliationRow(
        source: source,
        sourceId: sourceId,
        sourceDate: sourceDate,
        partyName: partyName,
        amountMinor: amountMinor,
        state: state,
        issueSummary: issueSummary,
        journalEntryId: journalEntryId ?? this.journalEntryId,
        journalDate: journalDate ?? this.journalDate,
        journalPosted: journalPosted ?? this.journalPosted,
        journalDebitMinor: journalDebitMinor ?? this.journalDebitMinor,
        journalCreditMinor: journalCreditMinor ?? this.journalCreditMinor,
        controlDebitMinor: controlDebitMinor,
        controlCreditMinor: controlCreditMinor,
        allocatedMinor: allocatedMinor,
        allocationStatus: allocationStatus,
      );
}
