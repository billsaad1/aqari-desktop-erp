import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/internal_subledger_reconciliation_report_model.dart';
import '../models/invoice_ledger_reconciliation_report_model.dart';

class InternalSubledgerReconciliationService {
  InternalSubledgerReconciliationService._();

  static Future<InternalSubledgerReconciliationReport> load({
    required DatabaseExecutor db,
    required String startDate,
    required String endDate,
    required String exclusiveEndDate,
    required String currency,
    required InvoiceLedgerReconciliationReport invoices,
  }) async {
    final rows = <InternalSubledgerReconciliationRow>[
      for (final invoice in invoices.rows) _invoiceRow(invoice),
      ...await _tenantReceipts(db, startDate, exclusiveEndDate),
      ...await _tenantReceiptCorrections(db, startDate, exclusiveEndDate),
      ...await _tenantRefunds(db, startDate, exclusiveEndDate),
      ...await _ownerSettlements(db, startDate, exclusiveEndDate),
      ...await _legacyOwnerVouchers(db, startDate, exclusiveEndDate),
      ...await _creditNotes(db, startDate, exclusiveEndDate),
      ...await _generalVouchersOnSubledgerAccounts(
        db,
        startDate,
        exclusiveEndDate,
      ),
      ...await _unlinkedJournalEntries(db, startDate, exclusiveEndDate),
    ];
    rows.sort((a, b) {
      final dateOrder = a.sourceDate.compareTo(b.sourceDate);
      if (dateOrder != 0) return dateOrder;
      final typeOrder = a.source.index.compareTo(b.source.index);
      return typeOrder != 0 ? typeOrder : a.sourceId.compareTo(b.sourceId);
    });
    return InternalSubledgerReconciliationReport(
      startDate: startDate,
      endDate: endDate,
      currency: currency,
      rows: rows,
    );
  }

  static InternalSubledgerReconciliationRow _invoiceRow(
    InvoiceLedgerReconciliationRow invoice,
  ) {
    final state = invoice.isReconciled
        ? InternalSubledgerRowState.matched
        : invoice.journalEntryId != null &&
              invoice.journalExists &&
              !invoice.journalPosted
        ? InternalSubledgerRowState.notPosted
        : InternalSubledgerRowState.needsReview;
    return InternalSubledgerReconciliationRow(
      source: InternalSubledgerSource.invoice,
      sourceId: invoice.invoiceId,
      sourceDate: invoice.invoiceDate,
      partyName: invoice.tenantName ?? 'غير محدد',
      amountMinor: invoice.totalMinor,
      state: state,
      issueSummary: invoice.issueSummary,
      journalEntryId: invoice.journalEntryId,
      journalPosted: invoice.journalPosted,
      journalDebitMinor: invoice.journalDebitMinor,
      journalCreditMinor: invoice.journalCreditMinor,
      controlDebitMinor: invoice.tenantReceivableDebitMinor,
      controlCreditMinor:
          invoice.revenueCreditMinor + invoice.taxLiabilityCreditMinor,
    );
  }

  static Future<List<InternalSubledgerReconciliationRow>> _tenantReceipts(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      WITH journal_totals AS (
        SELECT je.id AS journal_id, je.entry_date, je.is_posted,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        GROUP BY je.id
      ), journal_link_counts AS (
        SELECT journal_entry_id, COUNT(*) AS link_count
        FROM vouchers WHERE journal_entry_id IS NOT NULL
        GROUP BY journal_entry_id
      ), receipt_lines AS (
        SELECT v.id AS voucher_id,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = t.account_id
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS tenant_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = t.account_id
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS tenant_credit_minor,
          CAST(ROUND(COALESCE(SUM(CASE
            WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE
            WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_credit_minor,
          SUM(CASE WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            AND (COALESCE(jl.debit, 0) != 0 OR COALESCE(jl.credit, 0) != 0)
            THEN 1 ELSE 0 END) AS cash_line_count
        FROM vouchers v
        LEFT JOIN tenants t ON t.id = v.tenant_id
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = v.journal_entry_id
        LEFT JOIN accounts a ON a.id = jl.account_id
        WHERE v.voucher_type = 'قبض مستأجر'
        GROUP BY v.id
      ), receipt_allocations AS (
        SELECT voucher_id, SUM(amount_minor) AS allocated_minor
        FROM collection_allocations GROUP BY voucher_id
      ), receipt_data AS (
        SELECT v.id AS source_id, v.voucher_date AS source_date,
          COALESCE(t.name, v.party_name, 'غير محدد') AS party_name,
          CAST(ROUND(COALESCE(v.amount, 0) * 100) AS INTEGER)
            AS amount_minor,
          v.journal_entry_id,
          jt.entry_date AS journal_date,
          COALESCE(jt.is_posted, 0) AS journal_posted,
          COALESCE(jt.debit_minor, 0) AS journal_debit_minor,
          COALESCE(jt.credit_minor, 0) AS journal_credit_minor,
          COALESCE(lines.tenant_debit_minor, 0) AS control_debit_minor,
          COALESCE(lines.tenant_credit_minor, 0) AS control_credit_minor,
          COALESCE(lines.cash_debit_minor, 0) AS cash_debit_minor,
          COALESCE(lines.cash_credit_minor, 0) AS cash_credit_minor,
          COALESCE(lines.cash_line_count, 0) AS cash_line_count,
          t.account_id AS tenant_account_id,
          COALESCE(links.link_count, 0) AS journal_link_count,
          COALESCE(alloc.allocated_minor, 0) AS allocated_minor,
          COALESCE(legacy.status, '') AS legacy_status
        FROM vouchers v
        LEFT JOIN tenants t ON t.id = v.tenant_id
        LEFT JOIN journal_totals jt ON jt.journal_id = v.journal_entry_id
        LEFT JOIN receipt_lines lines ON lines.voucher_id = v.id
        LEFT JOIN journal_link_counts links
          ON links.journal_entry_id = v.journal_entry_id
        LEFT JOIN receipt_allocations alloc ON alloc.voucher_id = v.id
        LEFT JOIN legacy_tenant_payment_reviews legacy
          ON legacy.voucher_id = v.id
        WHERE v.voucher_type = 'قبض مستأجر'
          AND v.voucher_date >= ? AND v.voucher_date < ?
          AND NOT EXISTS (
            SELECT 1 FROM tenant_receipt_corrections correction
            WHERE correction.source_receipt_voucher_id = v.id
               OR correction.replacement_receipt_voucher_id = v.id
          )
      )
      SELECT receipt_data.*,
        CASE
          WHEN legacy_status = 'pending' THEN 'legacyReview'
          WHEN tenant_account_id IS NULL THEN 'needsReview'
          WHEN journal_entry_id IS NULL OR journal_date IS NULL
            THEN 'needsReview'
          WHEN journal_posted != 1 THEN 'notPosted'
          WHEN journal_link_count != 1 THEN 'needsReview'
          WHEN amount_minor <= 0 OR journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            OR control_debit_minor != 0
            OR control_credit_minor != amount_minor
            OR cash_debit_minor != amount_minor
            OR cash_credit_minor != 0 OR cash_line_count != 1
            THEN 'needsReview'
          WHEN allocated_minor > amount_minor THEN 'needsReview'
          ELSE 'matched'
        END AS row_state,
        CASE
          WHEN legacy_status = 'pending' THEN 'سند تاريخي غير مصنف ويحتاج مراجعة'
          WHEN tenant_account_id IS NULL THEN 'حساب ذمم المستأجر غير محدد'
          WHEN journal_entry_id IS NULL THEN 'سند القبض بلا رابط قيد'
          WHEN journal_date IS NULL THEN 'القيد المرتبط غير موجود'
          WHEN journal_posted != 1 THEN 'القيد المرتبط غير مرحّل'
          WHEN journal_link_count != 1 THEN 'القيد مرتبط بأكثر من سند'
          WHEN journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            THEN 'إجمالي القيد لا يطابق مبلغ سند القبض'
          WHEN control_debit_minor != 0 OR control_credit_minor != amount_minor
            THEN 'حركة حساب ذمم المستأجر لا تطابق القبض'
          WHEN cash_debit_minor != amount_minor OR cash_credit_minor != 0
            OR cash_line_count != 1
            THEN 'حركة الصندوق أو البنك لا تطابق القبض'
          WHEN allocated_minor > amount_minor
            THEN 'التخصيصات تتجاوز مبلغ سند القبض'
          ELSE ''
        END AS issue_summary,
        CASE
          WHEN legacy_status = 'pending' THEN 'تاريخي للمراجعة'
          WHEN allocated_minor = 0 THEN 'غير مخصص'
          WHEN allocated_minor = amount_minor THEN 'مخصص بالكامل'
          WHEN allocated_minor < amount_minor THEN 'مخصص جزئيًا'
          ELSE 'يتجاوز مبلغ السند'
        END AS allocation_status
      FROM receipt_data
      ORDER BY source_date, source_id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map(
          (row) => {
            ...row,
            'source_kind': InternalSubledgerSource.tenantReceipt.name,
          },
        )
        .map(InternalSubledgerReconciliationRow.fromMap)
        .toList(growable: false);
  }

  /// Returns the three linked rows as one reconciliation unit. The reversal is
  /// a posted journal reversal, not a tenant cash-refund voucher.
  static Future<List<InternalSubledgerReconciliationRow>>
  _tenantReceiptCorrections(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery('''
      WITH journal_totals AS (
        SELECT je.id AS journal_id, je.entry_date, je.is_posted,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        GROUP BY je.id
      )
      SELECT correction.id AS correction_id,
        correction.reason AS correction_reason,
        correction.source_receipt_voucher_id AS source_voucher_id,
        correction.reversal_voucher_id AS reversal_voucher_id,
        correction.replacement_receipt_voucher_id AS replacement_voucher_id,
        source.id AS source_exists, source.voucher_type AS source_type,
        source.voucher_date AS source_date,
        CAST(ROUND(COALESCE(source.amount, 0) * 100) AS INTEGER)
          AS source_amount_minor,
        source.tenant_id AS source_tenant_id,
        source.journal_entry_id AS source_journal_id,
        source_journal.entry_date AS source_journal_date,
        COALESCE(source_journal.is_posted, 0) AS source_journal_posted,
        COALESCE(source_journal.debit_minor, 0) AS source_journal_debit_minor,
        COALESCE(source_journal.credit_minor, 0) AS source_journal_credit_minor,
        COALESCE((SELECT review.status FROM legacy_tenant_payment_reviews review
          WHERE review.voucher_id = source.id), '') AS source_legacy_status,
        (SELECT COUNT(*) FROM vouchers linked
          WHERE linked.journal_entry_id = source.journal_entry_id)
          AS source_journal_link_count,
        reversal.id AS reversal_exists,
        reversal.voucher_type AS reversal_type,
        reversal.voucher_date AS reversal_date,
        CAST(ROUND(COALESCE(reversal.amount, 0) * 100) AS INTEGER)
          AS reversal_amount_minor,
        reversal.tenant_id AS reversal_tenant_id,
        reversal.journal_entry_id AS reversal_journal_id,
        reversal_journal.entry_date AS reversal_journal_date,
        COALESCE(reversal_journal.is_posted, 0) AS reversal_journal_posted,
        COALESCE(reversal_journal.debit_minor, 0)
          AS reversal_journal_debit_minor,
        COALESCE(reversal_journal.credit_minor, 0)
          AS reversal_journal_credit_minor,
        (SELECT COUNT(*) FROM vouchers linked
          WHERE linked.journal_entry_id = reversal.journal_entry_id)
          AS reversal_journal_link_count,
        replacement.id AS replacement_exists,
        replacement.voucher_type AS replacement_type,
        replacement.voucher_date AS replacement_date,
        CAST(ROUND(COALESCE(replacement.amount, 0) * 100) AS INTEGER)
          AS replacement_amount_minor,
        replacement.tenant_id AS replacement_tenant_id,
        replacement.journal_entry_id AS replacement_journal_id,
        replacement_journal.entry_date AS replacement_journal_date,
        COALESCE(replacement_journal.is_posted, 0)
          AS replacement_journal_posted,
        COALESCE(replacement_journal.debit_minor, 0)
          AS replacement_journal_debit_minor,
        COALESCE(replacement_journal.credit_minor, 0)
          AS replacement_journal_credit_minor,
        COALESCE((SELECT review.status FROM legacy_tenant_payment_reviews review
          WHERE review.voucher_id = replacement.id), '')
          AS replacement_legacy_status,
        (SELECT COUNT(*) FROM vouchers linked
          WHERE linked.journal_entry_id = replacement.journal_entry_id)
          AS replacement_journal_link_count,
        tenant.name AS tenant_name, tenant.account_id AS tenant_account_id
      FROM tenant_receipt_corrections correction
      LEFT JOIN vouchers source
        ON source.id = correction.source_receipt_voucher_id
      LEFT JOIN journal_totals source_journal
        ON source_journal.journal_id = source.journal_entry_id
      LEFT JOIN vouchers reversal
        ON reversal.id = correction.reversal_voucher_id
      LEFT JOIN journal_totals reversal_journal
        ON reversal_journal.journal_id = reversal.journal_entry_id
      LEFT JOIN vouchers replacement
        ON replacement.id = correction.replacement_receipt_voucher_id
      LEFT JOIN journal_totals replacement_journal
        ON replacement_journal.journal_id = replacement.journal_entry_id
      LEFT JOIN tenants tenant ON tenant.id = source.tenant_id
      ORDER BY correction.id
      ''');
    int? number(Map<String, Object?> row, String key) =>
        (row[key] as num?)?.toInt();
    String? text(Map<String, Object?> row, String key) => row[key]?.toString();
    bool inRange(String? date) =>
        date != null &&
        date.compareTo(startDate) >= 0 &&
        date.compareTo(exclusiveEndDate) < 0;

    final result = <InternalSubledgerReconciliationRow>[];
    for (final row in data) {
      final correctionId = number(row, 'correction_id') ?? 0;
      final sourceId = number(row, 'source_voucher_id') ?? 0;
      final reversalId = number(row, 'reversal_voucher_id') ?? 0;
      final replacementId = number(row, 'replacement_voucher_id') ?? 0;
      final sourceDate = text(row, 'source_date') ?? '';
      final reversalDate = text(row, 'reversal_date') ?? '';
      final replacementDate = text(row, 'replacement_date') ?? '';
      if (!inRange(sourceDate) &&
          !inRange(reversalDate) &&
          !inRange(replacementDate)) {
        continue;
      }

      final sourceAmount = number(row, 'source_amount_minor') ?? 0;
      final reversalAmount = number(row, 'reversal_amount_minor') ?? 0;
      final replacementAmount = number(row, 'replacement_amount_minor') ?? 0;
      final tenantAccountId = number(row, 'tenant_account_id');
      final sourceJournalId = number(row, 'source_journal_id');
      final reversalJournalId = number(row, 'reversal_journal_id');
      final replacementJournalId = number(row, 'replacement_journal_id');
      final sourcePosted = number(row, 'source_journal_posted') == 1;
      final reversalPosted = number(row, 'reversal_journal_posted') == 1;
      final replacementPosted = number(row, 'replacement_journal_posted') == 1;
      var groupState = InternalSubledgerRowState.matched;
      var groupIssue = '';
      var allocationsMatch = false;

      void review(String message) {
        groupState = InternalSubledgerRowState.needsReview;
        groupIssue = message;
      }

      if (sourceId == 0 ||
          reversalId == 0 ||
          replacementId == 0 ||
          sourceId == reversalId ||
          sourceId == replacementId ||
          reversalId == replacementId ||
          row['source_exists'] == null ||
          row['reversal_exists'] == null ||
          row['replacement_exists'] == null) {
        review('روابط مجموعة التصحيح غير مكتملة أو تشير إلى مستند مفقود');
      } else if (text(row, 'source_type') != 'قبض مستأجر' ||
          text(row, 'reversal_type') != 'عكس قبض مستأجر' ||
          text(row, 'replacement_type') != 'قبض مستأجر') {
        review('أنواع مستندات مجموعة التصحيح غير صحيحة');
      } else if (text(row, 'source_legacy_status') == 'pending' ||
          text(row, 'replacement_legacy_status') == 'pending') {
        groupState = InternalSubledgerRowState.legacyReview;
        groupIssue =
            'الأصل أو السند البديل معلّق في مراجعة المستندات التاريخية';
      } else if (number(row, 'source_tenant_id') == null ||
          number(row, 'source_tenant_id') !=
              number(row, 'reversal_tenant_id') ||
          number(row, 'source_tenant_id') !=
              number(row, 'replacement_tenant_id') ||
          tenantAccountId == null) {
        review('المستأجر أو حساب الذمم غير متطابق بين الأصل والعكس والبديل');
      } else if (sourceAmount <= 0 ||
          reversalAmount != sourceAmount ||
          replacementAmount <= 0) {
        review(
          'مبلغ العكس يجب أن يساوي الأصل، ومبلغ السند البديل يجب أن يكون موجبًا',
        );
      } else if (sourceJournalId == null ||
          reversalJournalId == null ||
          replacementJournalId == null ||
          text(row, 'source_journal_date') == null ||
          text(row, 'reversal_journal_date') == null ||
          text(row, 'replacement_journal_date') == null) {
        review('أحد قيود الأصل أو العكس أو البديل مفقود أو غير مرتبط');
      } else if (!sourcePosted || !reversalPosted || !replacementPosted) {
        groupState = InternalSubledgerRowState.notPosted;
        groupIssue = 'أحد قيود مجموعة التصحيح غير مرحّل؛ لم تُطابق المجموعة';
      } else if (sourceJournalId == reversalJournalId ||
          sourceJournalId == replacementJournalId ||
          reversalJournalId == replacementJournalId ||
          number(row, 'source_journal_link_count') != 1 ||
          number(row, 'reversal_journal_link_count') != 1 ||
          number(row, 'replacement_journal_link_count') != 1) {
        review('قيد في مجموعة التصحيح مكرر أو مرتبط بأكثر من مستند');
      } else if (reversalDate != replacementDate ||
          text(row, 'reversal_journal_date') != reversalDate ||
          text(row, 'replacement_journal_date') != replacementDate) {
        review('تاريخا العكس والبديل أو تاريخا قيديهما غير متطابقة');
      } else if (number(row, 'source_journal_debit_minor') != sourceAmount ||
          number(row, 'source_journal_credit_minor') != sourceAmount ||
          number(row, 'reversal_journal_debit_minor') != sourceAmount ||
          number(row, 'reversal_journal_credit_minor') != sourceAmount ||
          number(row, 'replacement_journal_debit_minor') != replacementAmount ||
          number(row, 'replacement_journal_credit_minor') !=
              replacementAmount) {
        review('أحد قيود المجموعة غير متوازن أو لا يساوي مبلغ مستنده');
      } else {
        final sourceJournalValid = await _isStandardTenantReceiptJournal(
          db,
          journalId: sourceJournalId,
          tenantAccountId: tenantAccountId,
          amountMinor: sourceAmount,
        );
        final replacementJournalValid = await _isStandardTenantReceiptJournal(
          db,
          journalId: replacementJournalId,
          tenantAccountId: tenantAccountId,
          amountMinor: replacementAmount,
        );
        final reversalMatchesOriginal = await _journalReversesJournal(
          db,
          originalJournalId: sourceJournalId,
          reversalJournalId: reversalJournalId,
        );
        allocationsMatch = await _tenantReceiptCorrectionAllocationsMatch(
          db,
          correctionId: correctionId,
          sourceVoucherId: sourceId,
          sourceAmountMinor: sourceAmount,
          replacementVoucherId: replacementId,
          replacementAmountMinor: replacementAmount,
        );
        final reversalLinks = await db.rawQuery(
          '''
          SELECT
            (SELECT COUNT(*) FROM collection_allocations
              WHERE voucher_id = ?) AS allocation_count,
            (SELECT COUNT(*) FROM refund_allocations
              WHERE refund_voucher_id = ?) AS refund_count
          ''',
          [reversalId, reversalId],
        );
        final reversalHasCashRefund =
            ((reversalLinks.first['allocation_count'] as num?)?.toInt() ?? 0) >
                0 ||
            ((reversalLinks.first['refund_count'] as num?)?.toInt() ?? 0) > 0;
        if (!sourceJournalValid) {
          review(
            'قيد الأصل لا يحتوي حركة قبض قياسية متوازنة على الذمم والنقدية',
          );
        } else if (!reversalMatchesOriginal) {
          review('قيد العكس لا يعكس مبالغ وحسابات قيد الأصل سطرًا بسطر');
        } else if (!replacementJournalValid) {
          review('قيد السند البديل لا يطابق قبضًا قياسيًا متوازنًا');
        } else if (reversalHasCashRefund) {
          review(
            'عكس التصحيح مرتبط بتخصيص أو سند استرداد نقدي على نحو غير صحيح',
          );
        } else if (!allocationsMatch) {
          review(
            'تخصيصات الأصل أو البديل غير مكتملة أو غير مطابقة لجدول التصحيح',
          );
        } else {
          groupIssue =
              'مجموعة تصحيح مكتملة: الأصل #$sourceId، العكس #$reversalId '
              '(عكس محاسبي غير نقدي وليس استردادًا نقديًا)، البديل #$replacementId';
        }
      }

      InternalSubledgerReconciliationRow groupRow({
        required InternalSubledgerSource source,
        required int id,
        required String date,
        required int amount,
        required int? journalId,
        required String? journalDate,
        required bool posted,
        required int debit,
        required int credit,
        required int controlDebit,
        required int controlCredit,
        required String allocationStatus,
        int? allocated,
      }) => InternalSubledgerReconciliationRow(
        source: source,
        sourceId: id,
        sourceDate: date,
        partyName: text(row, 'tenant_name') ?? 'غير محدد',
        amountMinor: amount,
        state: groupState,
        issueSummary: groupIssue,
        journalEntryId: journalId,
        journalDate: journalDate,
        journalPosted: posted,
        journalDebitMinor: debit,
        journalCreditMinor: credit,
        controlDebitMinor: controlDebit,
        controlCreditMinor: controlCredit,
        allocatedMinor: allocated,
        allocationStatus: allocationStatus,
        correctionSourceVoucherId: sourceId,
        correctionReversalVoucherId: reversalId,
        correctionReplacementVoucherId: replacementId,
      );

      if (inRange(sourceDate)) {
        result.add(
          groupRow(
            source: InternalSubledgerSource.tenantReceipt,
            id: sourceId,
            date: sourceDate,
            amount: sourceAmount,
            journalId: sourceJournalId,
            journalDate: text(row, 'source_journal_date'),
            posted: sourcePosted,
            debit: number(row, 'source_journal_debit_minor') ?? 0,
            credit: number(row, 'source_journal_credit_minor') ?? 0,
            controlDebit: 0,
            controlCredit: sourceAmount,
            allocationStatus: 'أصل ضمن مجموعة تصحيح',
            allocated: allocationsMatch ? sourceAmount : null,
          ),
        );
      }
      if (inRange(reversalDate)) {
        result.add(
          groupRow(
            source: InternalSubledgerSource.tenantReceiptCorrectionReversal,
            id: reversalId,
            date: reversalDate,
            amount: reversalAmount,
            journalId: reversalJournalId,
            journalDate: text(row, 'reversal_journal_date'),
            posted: reversalPosted,
            debit: number(row, 'reversal_journal_debit_minor') ?? 0,
            credit: number(row, 'reversal_journal_credit_minor') ?? 0,
            controlDebit: reversalAmount,
            controlCredit: reversalAmount,
            allocationStatus: 'عكس محاسبي — ليس استردادًا نقديًا',
          ),
        );
      }
      if (inRange(replacementDate)) {
        result.add(
          groupRow(
            source: InternalSubledgerSource.tenantReceipt,
            id: replacementId,
            date: replacementDate,
            amount: replacementAmount,
            journalId: replacementJournalId,
            journalDate: text(row, 'replacement_journal_date'),
            posted: replacementPosted,
            debit: number(row, 'replacement_journal_debit_minor') ?? 0,
            credit: number(row, 'replacement_journal_credit_minor') ?? 0,
            controlDebit: 0,
            controlCredit: replacementAmount,
            allocationStatus: 'سند بديل ضمن مجموعة التصحيح',
            allocated: allocationsMatch ? replacementAmount : null,
          ),
        );
      }
    }
    return result;
  }

  static Future<bool> _isStandardTenantReceiptJournal(
    DatabaseExecutor db, {
    required int journalId,
    required int tenantAccountId,
    required int amountMinor,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT jl.account_id, account.account_type, account.code,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS credit_minor,
        SUM(CASE WHEN COALESCE(jl.debit, 0) != 0
          OR COALESCE(jl.credit, 0) != 0 THEN 1 ELSE 0 END) AS line_count
      FROM journal_lines jl
      JOIN accounts account ON account.id = jl.account_id
      WHERE jl.journal_entry_id = ?
      GROUP BY jl.account_id
      ''',
      [journalId],
    );
    final activeRows = rows.where(
      (line) => (line['line_count'] as num).toInt() > 0,
    );
    if (activeRows.length != 2) return false;
    final tenantLines = activeRows.where(
      (line) => (line['account_id'] as num).toInt() == tenantAccountId,
    );
    final cashLines = activeRows.where(
      (line) =>
          line['account_type'] == 'Asset' &&
          (line['code']?.toString() ?? '').startsWith('11'),
    );
    if (tenantLines.length != 1 || cashLines.length != 1) return false;
    final tenant = tenantLines.single;
    final cash = cashLines.single;
    return (tenant['debit_minor'] as num).toInt() == 0 &&
        (tenant['credit_minor'] as num).toInt() == amountMinor &&
        (cash['debit_minor'] as num).toInt() == amountMinor &&
        (cash['credit_minor'] as num).toInt() == 0 &&
        (cash['line_count'] as num).toInt() == 1;
  }

  static Future<bool> _tenantReceiptCorrectionAllocationsMatch(
    DatabaseExecutor db, {
    required int correctionId,
    required int sourceVoucherId,
    required int sourceAmountMinor,
    required int replacementVoucherId,
    required int replacementAmountMinor,
  }) async {
    final sourceRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS allocation_count,
        COALESCE(SUM(amount_minor), 0) AS allocated_minor,
        SUM(CASE WHEN invoice_id IS NOT NULL OR amount_minor <= 0
          OR amount_minor != rent_amount_minor OR tax_amount_minor != 0
          OR EXISTS (SELECT 1 FROM refund_allocations refund
            WHERE refund.collection_allocation_id = collection_allocations.id)
          THEN 1 ELSE 0 END) AS invalid_count
      FROM collection_allocations WHERE voucher_id = ?
      ''',
      [sourceVoucherId],
    );
    final correctionRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS allocation_count,
        COALESCE(SUM(correction_allocation.amount_minor), 0)
          AS allocated_minor,
        SUM(CASE WHEN source_allocation.id IS NULL
          OR source_allocation.voucher_id != ?
          OR source_allocation.invoice_id IS NOT NULL
          OR correction_allocation.amount_minor != source_allocation.amount_minor
          OR source_allocation.amount_minor != source_allocation.rent_amount_minor
          OR source_allocation.tax_amount_minor != 0
          OR EXISTS (SELECT 1 FROM refund_allocations refund
            WHERE refund.collection_allocation_id = source_allocation.id)
          THEN 1 ELSE 0 END) AS invalid_count
      FROM tenant_receipt_correction_allocations correction_allocation
      LEFT JOIN collection_allocations source_allocation
        ON source_allocation.id = correction_allocation.collection_allocation_id
      WHERE correction_allocation.correction_id = ?
      ''',
      [sourceVoucherId, correctionId],
    );
    final replacementRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS allocation_count,
        COALESCE(SUM(amount_minor), 0) AS allocated_minor,
        SUM(CASE WHEN invoice_id IS NOT NULL OR amount_minor <= 0
          OR amount_minor != rent_amount_minor OR tax_amount_minor != 0
          THEN 1 ELSE 0 END) AS invalid_count
      FROM collection_allocations WHERE voucher_id = ?
      ''',
      [replacementVoucherId],
    );
    int field(Map<String, Object?> row, String key) =>
        (row[key] as num?)?.toInt() ?? 0;
    final source = sourceRows.single;
    final correction = correctionRows.single;
    final replacement = replacementRows.single;
    final sourceCount = field(source, 'allocation_count');
    return sourceCount > 0 &&
        field(source, 'allocated_minor') == sourceAmountMinor &&
        field(source, 'invalid_count') == 0 &&
        field(correction, 'allocation_count') == sourceCount &&
        field(correction, 'allocated_minor') == sourceAmountMinor &&
        field(correction, 'invalid_count') == 0 &&
        field(replacement, 'allocation_count') > 0 &&
        field(replacement, 'allocated_minor') == replacementAmountMinor &&
        field(replacement, 'invalid_count') == 0;
  }

  static Future<List<InternalSubledgerReconciliationRow>> _tenantRefunds(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      WITH journal_totals AS (
        SELECT je.id AS journal_id, je.entry_date, je.is_posted,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        GROUP BY je.id
      ), journal_link_counts AS (
        SELECT journal_entry_id, COUNT(*) AS link_count
        FROM vouchers WHERE journal_entry_id IS NOT NULL
        GROUP BY journal_entry_id
      ), refund_lines AS (
        SELECT v.id AS voucher_id,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = t.account_id
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS tenant_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = t.account_id
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS tenant_credit_minor,
          CAST(ROUND(COALESCE(SUM(CASE
            WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE
            WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_credit_minor,
          SUM(CASE WHEN a.account_type = 'Asset' AND a.code LIKE '11%'
            AND (COALESCE(jl.debit, 0) != 0 OR COALESCE(jl.credit, 0) != 0)
            THEN 1 ELSE 0 END) AS cash_line_count
        FROM vouchers v
        LEFT JOIN tenants t ON t.id = v.tenant_id
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = v.journal_entry_id
        LEFT JOIN accounts a ON a.id = jl.account_id
        WHERE v.voucher_type = 'صرف مستأجر'
        GROUP BY v.id
      ), refund_allocation_totals AS (
        SELECT ra.refund_voucher_id,
          SUM(ra.amount_minor) AS allocated_minor,
          SUM(CASE WHEN ca.id IS NULL OR source.id IS NULL
              OR source.voucher_type != 'قبض مستأجر'
              OR source.tenant_id IS NOT refund.tenant_id
              OR source_journal.is_posted IS NOT 1
              OR balance.remaining_minor < 0
              OR balance.remaining_rent_minor < 0
              OR balance.remaining_tax_minor < 0
              OR (ra.credit_note_id IS NOT NULL
                AND (note.id IS NULL OR note.status != 'posted'))
            THEN 1 ELSE 0 END) AS invalid_source_count,
          COUNT(ra.id) AS allocation_count
        FROM refund_allocations ra
        JOIN vouchers refund ON refund.id = ra.refund_voucher_id
        LEFT JOIN collection_allocations ca
          ON ca.id = ra.collection_allocation_id
        LEFT JOIN vouchers source ON source.id = ca.voucher_id
        LEFT JOIN journal_entries source_journal
          ON source_journal.id = source.journal_entry_id
        LEFT JOIN collection_allocation_balances balance
          ON balance.id = ca.id
        LEFT JOIN credit_notes note ON note.id = ra.credit_note_id
        GROUP BY ra.refund_voucher_id
      ), refund_data AS (
        SELECT v.id AS source_id, v.voucher_date AS source_date,
          COALESCE(t.name, v.party_name, 'غير محدد') AS party_name,
          CAST(ROUND(COALESCE(v.amount, 0) * 100) AS INTEGER)
            AS amount_minor,
          v.journal_entry_id,
          jt.entry_date AS journal_date,
          COALESCE(jt.is_posted, 0) AS journal_posted,
          COALESCE(jt.debit_minor, 0) AS journal_debit_minor,
          COALESCE(jt.credit_minor, 0) AS journal_credit_minor,
          COALESCE(lines.tenant_debit_minor, 0) AS control_debit_minor,
          COALESCE(lines.tenant_credit_minor, 0) AS control_credit_minor,
          COALESCE(lines.cash_debit_minor, 0) AS cash_debit_minor,
          COALESCE(lines.cash_credit_minor, 0) AS cash_credit_minor,
          COALESCE(lines.cash_line_count, 0) AS cash_line_count,
          t.account_id AS tenant_account_id,
          COALESCE(links.link_count, 0) AS journal_link_count,
          COALESCE(alloc.allocated_minor, 0) AS allocated_minor,
          COALESCE(alloc.invalid_source_count, 0) AS invalid_source_count,
          COALESCE(alloc.allocation_count, 0) AS allocation_count,
          COALESCE(legacy.status, '') AS legacy_status
        FROM vouchers v
        LEFT JOIN tenants t ON t.id = v.tenant_id
        LEFT JOIN journal_totals jt ON jt.journal_id = v.journal_entry_id
        LEFT JOIN refund_lines lines ON lines.voucher_id = v.id
        LEFT JOIN journal_link_counts links
          ON links.journal_entry_id = v.journal_entry_id
        LEFT JOIN refund_allocation_totals alloc
          ON alloc.refund_voucher_id = v.id
        LEFT JOIN legacy_tenant_payment_reviews legacy
          ON legacy.voucher_id = v.id
        WHERE v.voucher_type = 'صرف مستأجر'
          AND v.voucher_date >= ? AND v.voucher_date < ?
      )
      SELECT refund_data.*,
        CASE
          WHEN legacy_status = 'pending' THEN 'legacyReview'
          WHEN tenant_account_id IS NULL THEN 'needsReview'
          WHEN journal_entry_id IS NULL OR journal_date IS NULL
            THEN 'needsReview'
          WHEN journal_posted != 1 THEN 'notPosted'
          WHEN allocation_count = 0 THEN 'needsReview'
          WHEN allocated_minor != amount_minor OR invalid_source_count > 0
            THEN 'needsReview'
          WHEN journal_link_count != 1 THEN 'needsReview'
          WHEN amount_minor <= 0 OR journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            OR control_debit_minor != amount_minor
            OR control_credit_minor != 0
            OR cash_debit_minor != 0 OR cash_credit_minor != amount_minor
            OR cash_line_count != 1 THEN 'needsReview'
          ELSE 'matched'
        END AS row_state,
        CASE
          WHEN legacy_status = 'pending' THEN 'سند استرداد تاريخي غير مصنف'
          WHEN tenant_account_id IS NULL THEN 'حساب ذمم المستأجر غير محدد'
          WHEN journal_entry_id IS NULL THEN 'سند الاسترداد بلا رابط قيد'
          WHEN journal_date IS NULL THEN 'القيد المرتبط غير موجود'
          WHEN journal_posted != 1 THEN 'القيد المرتبط غير مرحّل'
          WHEN allocation_count = 0 THEN 'لا يوجد تخصيص لمصدر القبض'
          WHEN allocated_minor != amount_minor
            THEN 'مجموع تخصيصات الاسترداد لا يساوي مبلغ السند'
          WHEN invalid_source_count > 0
            THEN 'مصدر القبض أو الإشعار الدائن يحتاج مراجعة'
          WHEN journal_link_count != 1 THEN 'القيد مرتبط بأكثر من سند'
          WHEN journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            THEN 'إجمالي القيد لا يطابق مبلغ الاسترداد'
          WHEN control_debit_minor != amount_minor OR control_credit_minor != 0
            THEN 'حركة ذمم المستأجر لا تطابق الاسترداد'
          WHEN cash_debit_minor != 0 OR cash_credit_minor != amount_minor
            OR cash_line_count != 1
            THEN 'حركة الصندوق أو البنك لا تطابق الاسترداد'
          ELSE ''
        END AS issue_summary,
        CASE
          WHEN legacy_status = 'pending' THEN 'تاريخي للمراجعة'
          WHEN allocation_count = 0 THEN 'غير مرتبط بمصدر قبض'
          WHEN allocated_minor = amount_minor AND invalid_source_count = 0
            THEN 'مرتبط بمصدر قبض صالح'
          ELSE 'تخصيص مصدر يحتاج مراجعة'
        END AS allocation_status
      FROM refund_data
      ORDER BY source_date, source_id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map(
          (row) => {
            ...row,
            'source_kind': InternalSubledgerSource.tenantRefund.name,
          },
        )
        .map(InternalSubledgerReconciliationRow.fromMap)
        .toList(growable: false);
  }

  static Future<List<InternalSubledgerReconciliationRow>> _ownerSettlements(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      WITH journal_totals AS (
        SELECT je.id AS journal_id, je.entry_date, je.is_posted,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        GROUP BY je.id
      ), settlement_lines AS (
        SELECT s.id AS settlement_id,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = s.owner_account_id
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS owner_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = s.owner_account_id
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS owner_credit_minor,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = s.cash_account_id
            THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_debit_minor,
          CAST(ROUND(COALESCE(SUM(CASE WHEN jl.account_id = s.cash_account_id
            THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
            AS cash_credit_minor
        FROM owner_settlements s
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = s.journal_entry_id
        GROUP BY s.id
      ), settlement_data AS (
        SELECT s.id AS source_id, s.settlement_date AS source_date,
          COALESCE(s.owner_name_snapshot, owner.name, 'غير محدد') AS party_name,
          s.amount_minor AS amount_minor,
          s.journal_entry_id,
          jt.entry_date AS journal_date,
          COALESCE(jt.is_posted, 0) AS journal_posted,
          COALESCE(jt.debit_minor, 0) AS journal_debit_minor,
          COALESCE(jt.credit_minor, 0) AS journal_credit_minor,
          COALESCE(lines.owner_debit_minor, 0) AS control_debit_minor,
          COALESCE(lines.owner_credit_minor, 0) AS control_credit_minor,
          COALESCE(lines.cash_debit_minor, 0) AS cash_debit_minor,
          COALESCE(lines.cash_credit_minor, 0) AS cash_credit_minor,
          CASE WHEN owner.account_id = s.owner_account_id THEN 1 ELSE 0 END
            AS owner_link_valid,
          CASE WHEN v.id IS NOT NULL
            AND v.voucher_type = 'صرف مستحقات مالك'
            AND v.journal_entry_id = s.journal_entry_id
            AND v.voucher_date = s.settlement_date
            AND CAST(ROUND(v.amount * 100) AS INTEGER) = s.amount_minor
            THEN 1 ELSE 0 END AS voucher_link_valid
        FROM owner_settlements s
        LEFT JOIN owners owner ON owner.id = s.owner_id
        LEFT JOIN vouchers v ON v.id = s.voucher_id
        LEFT JOIN journal_totals jt ON jt.journal_id = s.journal_entry_id
        LEFT JOIN settlement_lines lines ON lines.settlement_id = s.id
        WHERE s.settlement_date >= ? AND s.settlement_date < ?
      )
      SELECT settlement_data.*,
        CASE
          WHEN journal_date IS NULL THEN 'needsReview'
          WHEN journal_posted != 1 THEN 'notPosted'
          WHEN owner_link_valid != 1 OR voucher_link_valid != 1
            THEN 'needsReview'
          WHEN journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            OR control_debit_minor != amount_minor
            OR control_credit_minor != 0
            OR cash_debit_minor != 0 OR cash_credit_minor != amount_minor
            THEN 'needsReview'
          ELSE 'matched'
        END AS row_state,
        CASE
          WHEN journal_date IS NULL THEN 'قيد تسوية المالك غير موجود'
          WHEN journal_posted != 1 THEN 'قيد تسوية المالك غير مرحّل'
          WHEN owner_link_valid != 1 THEN 'حساب التسوية لا يطابق حساب المالك'
          WHEN voucher_link_valid != 1 THEN 'سند التسوية لا يطابق التاريخ أو المبلغ أو القيد'
          WHEN journal_debit_minor != amount_minor
            OR journal_credit_minor != amount_minor
            THEN 'إجمالي القيد لا يطابق مبلغ التسوية'
          WHEN control_debit_minor != amount_minor OR control_credit_minor != 0
            THEN 'حركة حساب التزام المالك لا تطابق التسوية'
          WHEN cash_debit_minor != 0 OR cash_credit_minor != amount_minor
            THEN 'حركة الصندوق أو البنك لا تطابق التسوية'
          ELSE ''
        END AS issue_summary
      FROM settlement_data
      ORDER BY source_date, source_id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map(
          (row) => {
            ...row,
            'source_kind': InternalSubledgerSource.ownerSettlement.name,
          },
        )
        .map(InternalSubledgerReconciliationRow.fromMap)
        .toList(growable: false);
  }

  static Future<List<InternalSubledgerReconciliationRow>> _legacyOwnerVouchers(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      SELECT v.id AS source_id, v.voucher_date AS source_date,
        COALESCE(v.party_name, 'غير محدد') AS party_name,
        CAST(ROUND(COALESCE(v.amount, 0) * 100) AS INTEGER) AS amount_minor,
        v.journal_entry_id, je.entry_date AS journal_date,
        COALESCE(je.is_posted, 0) AS journal_posted,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          WHERE jl.journal_entry_id = v.journal_entry_id), 0) * 100)
          AS INTEGER) AS journal_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          WHERE jl.journal_entry_id = v.journal_entry_id), 0) * 100)
          AS INTEGER) AS journal_credit_minor
      FROM vouchers v
      LEFT JOIN journal_entries je ON je.id = v.journal_entry_id
      WHERE v.voucher_type = 'صرف مستحقات مالك'
        AND v.voucher_date >= ? AND v.voucher_date < ?
        AND NOT EXISTS (
          SELECT 1 FROM owner_settlements s WHERE s.voucher_id = v.id
        )
      ORDER BY v.voucher_date, v.id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map((row) {
          return InternalSubledgerReconciliationRow(
            source: InternalSubledgerSource.legacyOwnerVoucher,
            sourceId: (row['source_id'] as num).toInt(),
            sourceDate: row['source_date']?.toString() ?? '',
            partyName: row['party_name']?.toString() ?? 'غير محدد',
            amountMinor: (row['amount_minor'] as num?)?.toInt() ?? 0,
            state: InternalSubledgerRowState.legacyReview,
            issueSummary:
                'سند قديم بلا سجل تسوية مالك صريح؛ لا يُستنتج المالك أو الربط',
            journalEntryId: (row['journal_entry_id'] as num?)?.toInt(),
            journalDate: row['journal_date']?.toString(),
            journalPosted: (row['journal_posted'] as num?)?.toInt() == 1,
            journalDebitMinor:
                (row['journal_debit_minor'] as num?)?.toInt() ?? 0,
            journalCreditMinor:
                (row['journal_credit_minor'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  static Future<List<InternalSubledgerReconciliationRow>> _creditNotes(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      WITH journal_totals AS (
        SELECT je.id AS journal_id, je.entry_date, je.is_posted,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        GROUP BY je.id
      )
      SELECT note.id AS source_id, note.note_date AS source_date,
        note.status AS note_status, note.invoice_id,
        invoice.journal_entry_id AS source_invoice_journal_id,
        note.net_amount_minor, note.tax_amount_minor, note.total_amount_minor,
        note.tax_account_id, note.journal_entry_id,
        original.entry_date AS journal_date,
        COALESCE(original.is_posted, 0) AS journal_posted,
        COALESCE(original.debit_minor, 0) AS journal_debit_minor,
        COALESCE(original.credit_minor, 0) AS journal_credit_minor,
        note.reversal_journal_entry_id,
        reverse.entry_date AS reversal_journal_date,
        COALESCE(reverse.is_posted, 0) AS reversal_journal_posted,
        COALESCE(reverse.debit_minor, 0) AS reversal_debit_minor,
        COALESCE(reverse.credit_minor, 0) AS reversal_credit_minor,
        COALESCE(tenant.name, 'غير محدد') AS party_name,
        tenant.account_id AS tenant_account_id,
        note.reversed_at,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND jl.account_id = tenant.account_id), 0) * 100) AS INTEGER)
          AS tenant_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND jl.account_id = tenant.account_id), 0) * 100) AS INTEGER)
          AS tenant_credit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND a.account_type = 'Revenue'), 0) * 100) AS INTEGER)
          AS revenue_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND a.account_type = 'Revenue'), 0) * 100) AS INTEGER)
          AS revenue_credit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND jl.account_id = note.tax_account_id), 0) * 100) AS INTEGER)
          AS tax_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.journal_entry_id
            AND jl.account_id = note.tax_account_id), 0) * 100) AS INTEGER)
          AS tax_credit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND jl.account_id = tenant.account_id), 0) * 100) AS INTEGER)
          AS reverse_tenant_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND jl.account_id = tenant.account_id), 0) * 100) AS INTEGER)
          AS reverse_tenant_credit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND a.account_type = 'Revenue'), 0) * 100) AS INTEGER)
          AS reverse_revenue_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND a.account_type = 'Revenue'), 0) * 100) AS INTEGER)
          AS reverse_revenue_credit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND jl.account_id = note.tax_account_id), 0) * 100) AS INTEGER)
          AS reverse_tax_debit_minor,
        CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
          WHERE jl.journal_entry_id = note.reversal_journal_entry_id
            AND jl.account_id = note.tax_account_id), 0) * 100) AS INTEGER)
          AS reverse_tax_credit_minor
      FROM credit_notes note
      LEFT JOIN tax_invoices invoice ON invoice.id = note.invoice_id
      LEFT JOIN contracts contract ON contract.id = invoice.contract_id
      LEFT JOIN tenants tenant ON tenant.id = contract.tenant_id
      LEFT JOIN journal_totals original
        ON original.journal_id = note.journal_entry_id
      LEFT JOIN journal_totals reverse
        ON reverse.journal_id = note.reversal_journal_entry_id
      WHERE (note.note_date >= ? AND note.note_date < ?)
         OR (note.status = 'reversed'
           AND COALESCE(
             reverse.entry_date,
             substr(COALESCE(note.reversed_at, ''), 1, 10)
           ) >= ?
           AND COALESCE(
             reverse.entry_date,
             substr(COALESCE(note.reversed_at, ''), 1, 10)
           ) < ?)
      ORDER BY note.note_date, note.id
      ''',
      [startDate, exclusiveEndDate, startDate, exclusiveEndDate],
    );
    final result = <InternalSubledgerReconciliationRow>[];
    for (final row in data) {
      final noteDate = row['source_date']?.toString() ?? '';
      final reversedAt = row['reversed_at']?.toString() ?? '';
      final ledgerReversalDate = row['reversal_journal_date']?.toString();
      final reversalDate =
          ledgerReversalDate != null && ledgerReversalDate.isNotEmpty
          ? ledgerReversalDate
          : reversedAt.length >= 10
          ? reversedAt.substring(0, 10)
          : '';
      final amount = (row['total_amount_minor'] as num?)?.toInt() ?? 0;
      final net = (row['net_amount_minor'] as num?)?.toInt() ?? 0;
      final tax = (row['tax_amount_minor'] as num?)?.toInt() ?? 0;
      final status = row['note_status']?.toString() ?? 'legacy_review';
      final journalId = (row['journal_entry_id'] as num?)?.toInt();
      final journalDate = row['journal_date']?.toString();
      final posted = (row['journal_posted'] as num?)?.toInt() == 1;
      final debit = (row['journal_debit_minor'] as num?)?.toInt() ?? 0;
      final credit = (row['journal_credit_minor'] as num?)?.toInt() ?? 0;
      final tenantAccountId = (row['tenant_account_id'] as num?)?.toInt();
      final tenantCredit = (row['tenant_credit_minor'] as num?)?.toInt() ?? 0;
      final revenueDebit = (row['revenue_debit_minor'] as num?)?.toInt() ?? 0;
      final taxDebit = (row['tax_debit_minor'] as num?)?.toInt() ?? 0;
      final sourceInvoiceJournalId = (row['source_invoice_journal_id'] as num?)
          ?.toInt();
      final revenueAccountsMatch =
          status == 'legacy_review' || status == 'draft'
          ? true
          : await _creditNoteRevenueSharesMatch(
              db,
              sourceJournalId: sourceInvoiceJournalId,
              creditNoteJournalId: journalId,
              amountMinor: net,
            );
      final noteState = _creditNoteState(
        status: status,
        amount: amount,
        net: net,
        tax: tax,
        journalId: journalId,
        journalDate: journalDate,
        posted: posted,
        debit: debit,
        credit: credit,
        tenantAccountId: tenantAccountId,
        tenantControl: tenantCredit,
        revenueControl: revenueDebit,
        taxControl: taxDebit,
        revenueAccountsMatch: revenueAccountsMatch,
      );
      if (noteDate.compareTo(startDate) >= 0 &&
          noteDate.compareTo(exclusiveEndDate) < 0) {
        result.add(
          InternalSubledgerReconciliationRow(
            source: InternalSubledgerSource.creditNote,
            sourceId: (row['source_id'] as num).toInt(),
            sourceDate: noteDate,
            partyName: row['party_name']?.toString() ?? 'غير محدد',
            amountMinor: amount,
            state: noteState.$1,
            issueSummary: noteState.$2,
            journalEntryId: journalId,
            journalDate: journalDate,
            journalPosted: posted,
            journalDebitMinor: debit,
            journalCreditMinor: credit,
            controlDebitMinor: revenueDebit + taxDebit,
            controlCreditMinor: tenantCredit,
          ),
        );
      }
      if (status == 'reversed' &&
          reversalDate.compareTo(startDate) >= 0 &&
          reversalDate.compareTo(exclusiveEndDate) < 0) {
        final reversalId = (row['reversal_journal_entry_id'] as num?)?.toInt();
        final reversalPosted =
            (row['reversal_journal_posted'] as num?)?.toInt() == 1;
        final reversalDebit =
            (row['reversal_debit_minor'] as num?)?.toInt() ?? 0;
        final reversalCredit =
            (row['reversal_credit_minor'] as num?)?.toInt() ?? 0;
        final reverseTenantDebit =
            (row['reverse_tenant_debit_minor'] as num?)?.toInt() ?? 0;
        final reverseRevenueCredit =
            (row['reverse_revenue_credit_minor'] as num?)?.toInt() ?? 0;
        final reverseTaxCredit =
            (row['reverse_tax_credit_minor'] as num?)?.toInt() ?? 0;
        final reversalLinesMatch = await _journalReversesJournal(
          db,
          originalJournalId: journalId,
          reversalJournalId: reversalId,
        );
        final reversalIssue = _reversalIssue(
          amount: amount,
          net: net,
          tax: tax,
          journalId: reversalId,
          journalDate: ledgerReversalDate,
          posted: reversalPosted,
          debit: reversalDebit,
          credit: reversalCredit,
          tenantAccountId: tenantAccountId,
          tenantControl: reverseTenantDebit,
          revenueControl: reverseRevenueCredit,
          taxControl: reverseTaxCredit,
          reversalLinesMatch: reversalLinesMatch,
        );
        result.add(
          InternalSubledgerReconciliationRow(
            source: InternalSubledgerSource.creditNoteReversal,
            sourceId: (row['source_id'] as num).toInt(),
            sourceDate: reversalDate,
            partyName: row['party_name']?.toString() ?? 'غير محدد',
            amountMinor: amount,
            state: reversalIssue.$1,
            issueSummary: reversalIssue.$2,
            journalEntryId: reversalId,
            journalDate: ledgerReversalDate,
            journalPosted: reversalPosted,
            journalDebitMinor: reversalDebit,
            journalCreditMinor: reversalCredit,
            controlDebitMinor: reverseTenantDebit,
            controlCreditMinor: reverseRevenueCredit + reverseTaxCredit,
          ),
        );
      }
    }
    return result;
  }

  static Future<bool> _creditNoteRevenueSharesMatch(
    DatabaseExecutor db, {
    required int? sourceJournalId,
    required int? creditNoteJournalId,
    required int amountMinor,
  }) async {
    if (sourceJournalId == null || creditNoteJournalId == null) return false;
    final sourceLines = await db.rawQuery(
      '''
      SELECT jl.account_id, jl.credit
      FROM journal_lines jl
      JOIN accounts account ON account.id = jl.account_id
      WHERE jl.journal_entry_id = ?
        AND account.account_type = 'Revenue'
        AND jl.credit > 0
      ORDER BY jl.id
      ''',
      [sourceJournalId],
    );
    if (sourceLines.isEmpty) return false;
    final weights = sourceLines
        .map((line) => ((line['credit'] as num).toDouble() * 100).round())
        .toList(growable: false);
    final totalWeight = weights.fold<int>(0, (sum, value) => sum + value);
    if (totalWeight <= 0) return false;
    final expected = <int, int>{};
    var allocated = 0;
    for (var index = 0; index < sourceLines.length; index++) {
      final share = index == sourceLines.length - 1
          ? amountMinor - allocated
          : (BigInt.from(amountMinor) *
                    BigInt.from(weights[index]) ~/
                    BigInt.from(totalWeight))
                .toInt();
      allocated += share;
      final accountId = (sourceLines[index]['account_id'] as num).toInt();
      if (share > 0) expected[accountId] = (expected[accountId] ?? 0) + share;
    }
    final actualRows = await db.rawQuery(
      '''
      SELECT jl.account_id,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS credit_minor
      FROM journal_lines jl
      JOIN accounts account ON account.id = jl.account_id
      WHERE jl.journal_entry_id = ? AND account.account_type = 'Revenue'
      GROUP BY jl.account_id
      ''',
      [creditNoteJournalId],
    );
    final actual = <int, int>{};
    for (final row in actualRows) {
      final accountId = (row['account_id'] as num).toInt();
      final debit = (row['debit_minor'] as num?)?.toInt() ?? 0;
      final credit = (row['credit_minor'] as num?)?.toInt() ?? 0;
      if (credit != 0 || debit <= 0) return false;
      actual[accountId] = debit;
    }
    if (expected.length != actual.length) return false;
    for (final entry in expected.entries) {
      if (actual[entry.key] != entry.value) return false;
    }
    return true;
  }

  static Future<bool> _journalReversesJournal(
    DatabaseExecutor db, {
    required int? originalJournalId,
    required int? reversalJournalId,
  }) async {
    if (originalJournalId == null || reversalJournalId == null) return false;
    Future<Map<int, (int, int)>> lines(int journalId) async {
      final rows = await db.rawQuery(
        '''
        SELECT account_id,
          CAST(ROUND(COALESCE(SUM(debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_lines
        WHERE journal_entry_id = ?
        GROUP BY account_id
        ''',
        [journalId],
      );
      return {
        for (final row in rows)
          (row['account_id'] as num).toInt(): (
            (row['debit_minor'] as num?)?.toInt() ?? 0,
            (row['credit_minor'] as num?)?.toInt() ?? 0,
          ),
      };
    }

    final original = await lines(originalJournalId);
    final reversal = await lines(reversalJournalId);
    if (original.isEmpty || original.length != reversal.length) return false;
    for (final entry in original.entries) {
      final reversed = reversal[entry.key];
      if (reversed == null ||
          reversed.$1 != entry.value.$2 ||
          reversed.$2 != entry.value.$1) {
        return false;
      }
    }
    return true;
  }

  static (InternalSubledgerRowState, String) _creditNoteState({
    required String status,
    required int amount,
    required int net,
    required int tax,
    required int? journalId,
    required String? journalDate,
    required bool posted,
    required int debit,
    required int credit,
    required int? tenantAccountId,
    required int tenantControl,
    required int revenueControl,
    required int taxControl,
    required bool revenueAccountsMatch,
  }) {
    if (status == 'legacy_review') {
      return (
        InternalSubledgerRowState.legacyReview,
        'سجل تاريخي؛ لم يُستنتج له قيد أو تفصيل ضريبي',
      );
    }
    if (status == 'draft') {
      return (
        InternalSubledgerRowState.notPosted,
        'مسودة إشعار دائن؛ لا تمثل أثرًا مرحّلًا في الأستاذ',
      );
    }
    if (journalId == null) {
      return (InternalSubledgerRowState.needsReview, 'الإشعار بلا رابط قيد');
    }
    if (journalDate == null) {
      return (InternalSubledgerRowState.needsReview, 'قيد الإشعار غير موجود');
    }
    if (!posted) {
      return (InternalSubledgerRowState.notPosted, 'قيد الإشعار غير مرحّل');
    }
    if (tenantAccountId == null) {
      return (
        InternalSubledgerRowState.needsReview,
        'حساب ذمم المستأجر غير محدد',
      );
    }
    if (debit != amount || credit != amount) {
      return (
        InternalSubledgerRowState.needsReview,
        'إجمالي قيد الإشعار غير متوازن أو لا يطابق المبلغ',
      );
    }
    if (tenantControl != amount) {
      return (
        InternalSubledgerRowState.needsReview,
        'دائن ذمم المستأجر لا يطابق الإشعار',
      );
    }
    if (revenueControl != net) {
      return (
        InternalSubledgerRowState.needsReview,
        'مدين الإيراد لا يطابق صافي الإشعار',
      );
    }
    if (!revenueAccountsMatch) {
      return (
        InternalSubledgerRowState.needsReview,
        'توزيع مدين الإيراد لا يطابق حسابات الفاتورة الأصلية',
      );
    }
    if (taxControl != tax) {
      return (
        InternalSubledgerRowState.needsReview,
        'مدين حساب الضريبة لا يطابق ضريبة الإشعار',
      );
    }
    return (InternalSubledgerRowState.matched, '');
  }

  static (InternalSubledgerRowState, String) _reversalIssue({
    required int amount,
    required int net,
    required int tax,
    required int? journalId,
    required String? journalDate,
    required bool posted,
    required int debit,
    required int credit,
    required int? tenantAccountId,
    required int tenantControl,
    required int revenueControl,
    required int taxControl,
    required bool reversalLinesMatch,
  }) {
    if (journalId == null) {
      return (
        InternalSubledgerRowState.needsReview,
        'عكس الإشعار بلا رابط قيد',
      );
    }
    if (journalDate == null) {
      return (
        InternalSubledgerRowState.needsReview,
        'قيد عكس الإشعار غير موجود',
      );
    }
    if (!posted) {
      return (InternalSubledgerRowState.notPosted, 'قيد عكس الإشعار غير مرحّل');
    }
    if (tenantAccountId == null) {
      return (
        InternalSubledgerRowState.needsReview,
        'حساب ذمم المستأجر غير محدد',
      );
    }
    if (debit != amount || credit != amount) {
      return (
        InternalSubledgerRowState.needsReview,
        'قيد عكس الإشعار غير متوازن أو لا يطابق المبلغ',
      );
    }
    if (tenantControl != amount || revenueControl != net || taxControl != tax) {
      return (
        InternalSubledgerRowState.needsReview,
        'أسطر العكس لا تطابق الذمم وصافي الإشعار والضريبة',
      );
    }
    if (!reversalLinesMatch) {
      return (
        InternalSubledgerRowState.needsReview,
        'قيد العكس لا يعكس حسابات القيد الأصلي سطرًا بحساب',
      );
    }
    return (InternalSubledgerRowState.matched, '');
  }

  static Future<List<InternalSubledgerReconciliationRow>>
  _generalVouchersOnSubledgerAccounts(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      SELECT v.id AS source_id, v.voucher_date AS source_date,
        COALESCE(v.party_name, 'طرف غير محدد') AS party_name,
        CAST(ROUND(COALESCE(v.amount, 0) * 100) AS INTEGER) AS amount_minor,
        v.journal_entry_id, je.entry_date AS journal_date,
        COALESCE(je.is_posted, 0) AS journal_posted,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS journal_debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS journal_credit_minor,
        CAST(ROUND(COALESCE(SUM(CASE WHEN linked.id IS NOT NULL
          THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
          AS control_debit_minor,
        CAST(ROUND(COALESCE(SUM(CASE WHEN linked.id IS NOT NULL
          THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
          AS control_credit_minor
      FROM vouchers v
      LEFT JOIN journal_entries je ON je.id = v.journal_entry_id
      LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
      LEFT JOIN accounts linked ON linked.id = jl.account_id AND (
        linked.id IN (SELECT account_id FROM tenants WHERE account_id IS NOT NULL)
        OR linked.id IN (SELECT account_id FROM owners WHERE account_id IS NOT NULL)
        OR linked.id IN (SELECT tax_account_id FROM tax_invoices
          WHERE tax_account_id IS NOT NULL)
        OR linked.id IN (SELECT tax_account_id FROM credit_notes
          WHERE tax_account_id IS NOT NULL)
      )
      WHERE v.voucher_type IN ('قبض عام', 'صرف عام')
        AND v.voucher_date >= ? AND v.voucher_date < ?
        AND (v.journal_entry_id IS NULL OR EXISTS (
          SELECT 1 FROM journal_lines control_line
          WHERE control_line.journal_entry_id = v.journal_entry_id
            AND control_line.account_id IN (
              SELECT account_id FROM tenants WHERE account_id IS NOT NULL
              UNION SELECT account_id FROM owners WHERE account_id IS NOT NULL
              UNION SELECT tax_account_id FROM tax_invoices
                WHERE tax_account_id IS NOT NULL
              UNION SELECT tax_account_id FROM credit_notes
                WHERE tax_account_id IS NOT NULL
            )
        ))
      GROUP BY v.id, je.id
      ORDER BY v.voucher_date, v.id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map((row) {
          final journalId = (row['journal_entry_id'] as num?)?.toInt();
          final journalDate = row['journal_date']?.toString();
          final posted = (row['journal_posted'] as num?)?.toInt() == 1;
          final state = journalId == null || journalDate == null
              ? InternalSubledgerRowState.needsReview
              : !posted
              ? InternalSubledgerRowState.notPosted
              : InternalSubledgerRowState.needsReview;
          return InternalSubledgerReconciliationRow(
            source: InternalSubledgerSource.generalVoucher,
            sourceId: (row['source_id'] as num).toInt(),
            sourceDate: row['source_date']?.toString() ?? '',
            partyName: row['party_name']?.toString() ?? '',
            amountMinor: (row['amount_minor'] as num?)?.toInt() ?? 0,
            state: state,
            issueSummary: journalId == null
                ? 'السند العام بلا رابط قيد'
                : journalDate == null
                ? 'القيد المرتبط غير موجود'
                : !posted
                ? 'القيد المرتبط غير مرحّل'
                : 'السند العام يلمس حسابًا فرعيًا دون رابط هوية صريح؛ لا يُستنتج الطرف',
            journalEntryId: journalId,
            journalDate: journalDate,
            journalPosted: posted,
            journalDebitMinor:
                (row['journal_debit_minor'] as num?)?.toInt() ?? 0,
            journalCreditMinor:
                (row['journal_credit_minor'] as num?)?.toInt() ?? 0,
            controlDebitMinor:
                (row['control_debit_minor'] as num?)?.toInt() ?? 0,
            controlCreditMinor:
                (row['control_credit_minor'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  static Future<List<InternalSubledgerReconciliationRow>>
  _unlinkedJournalEntries(
    DatabaseExecutor db,
    String startDate,
    String exclusiveEndDate,
  ) async {
    final data = await db.rawQuery(
      '''
      SELECT je.id AS source_id, je.entry_date AS source_date,
        COALESCE(je.description, 'قيد بلا بيان') AS party_name,
        CAST(ROUND(COALESCE(SUM(CASE WHEN linked.id IS NOT NULL
          THEN ABS(COALESCE(jl.debit, 0)) + ABS(COALESCE(jl.credit, 0))
          ELSE 0 END), 0) * 100) AS INTEGER) AS amount_minor,
        je.id AS journal_entry_id, je.entry_date AS journal_date,
        COALESCE(je.is_posted, 0) AS journal_posted,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS journal_debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS journal_credit_minor,
        CAST(ROUND(COALESCE(SUM(CASE WHEN linked.id IS NOT NULL
          THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
          AS control_debit_minor,
        CAST(ROUND(COALESCE(SUM(CASE WHEN linked.id IS NOT NULL
          THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
          AS control_credit_minor
      FROM journal_entries je
      JOIN journal_lines jl ON jl.journal_entry_id = je.id
      LEFT JOIN accounts linked ON linked.id = jl.account_id AND (
        linked.id IN (SELECT account_id FROM tenants WHERE account_id IS NOT NULL)
        OR linked.id IN (SELECT account_id FROM owners WHERE account_id IS NOT NULL)
        OR linked.id IN (SELECT tax_account_id FROM tax_invoices
          WHERE tax_account_id IS NOT NULL)
        OR linked.id IN (SELECT tax_account_id FROM credit_notes
          WHERE tax_account_id IS NOT NULL)
      )
      WHERE je.entry_date >= ? AND je.entry_date < ?
        AND EXISTS (
          SELECT 1 FROM journal_lines target_line
          WHERE target_line.journal_entry_id = je.id
            AND target_line.account_id IN (
              SELECT account_id FROM tenants WHERE account_id IS NOT NULL
              UNION SELECT account_id FROM owners WHERE account_id IS NOT NULL
              UNION SELECT tax_account_id FROM tax_invoices
                WHERE tax_account_id IS NOT NULL
              UNION SELECT tax_account_id FROM credit_notes
                WHERE tax_account_id IS NOT NULL
            )
        )
        AND NOT EXISTS (
          SELECT 1 FROM tax_invoices invoice
          WHERE invoice.journal_entry_id = je.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM vouchers voucher
          WHERE voucher.journal_entry_id = je.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM credit_notes note
          WHERE note.journal_entry_id = je.id
             OR note.reversal_journal_entry_id = je.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM owner_settlements settlement
          WHERE settlement.journal_entry_id = je.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM legacy_tenant_payment_reviews legacy
          WHERE legacy.reclassification_journal_entry_id = je.id
        )
      GROUP BY je.id
      ORDER BY je.entry_date, je.id
      ''',
      [startDate, exclusiveEndDate],
    );
    return data
        .map((row) {
          final posted = (row['journal_posted'] as num?)?.toInt() == 1;
          return InternalSubledgerReconciliationRow(
            source: InternalSubledgerSource.directJournal,
            sourceId: (row['source_id'] as num).toInt(),
            sourceDate: row['source_date']?.toString() ?? '',
            partyName: row['party_name']?.toString() ?? '',
            amountMinor: (row['amount_minor'] as num?)?.toInt() ?? 0,
            state: posted
                ? InternalSubledgerRowState.needsReview
                : InternalSubledgerRowState.notPosted,
            issueSummary:
                'قيد يمس حساب ذمم فرعيًا دون مستند فرعي مرتبط؛ يلزم تتبع يدوي',
            journalEntryId: (row['journal_entry_id'] as num?)?.toInt(),
            journalDate: row['journal_date']?.toString(),
            journalPosted: posted,
            journalDebitMinor:
                (row['journal_debit_minor'] as num?)?.toInt() ?? 0,
            journalCreditMinor:
                (row['journal_credit_minor'] as num?)?.toInt() ?? 0,
            controlDebitMinor:
                (row['control_debit_minor'] as num?)?.toInt() ?? 0,
            controlCreditMinor:
                (row['control_credit_minor'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }
}
