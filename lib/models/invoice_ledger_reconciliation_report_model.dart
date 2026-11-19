enum InvoiceLedgerReconciliationIssue {
  missingJournalLink,
  missingJournalEntry,
  journalNotPosted,
  missingTenantAccount,
  missingInvoiceContract,
  missingInvoiceInstallment,
  missingTaxAccountSource,
  invoiceInstallmentContractMismatch,
  installmentAmountMismatch,
  duplicateJournalLink,
  invoiceTotalMismatch,
  journalUnbalanced,
  journalTotalMismatch,
  tenantReceivableMismatch,
  revenueMismatch,
  taxLiabilityMismatch,
}

extension InvoiceLedgerReconciliationIssueLabel
    on InvoiceLedgerReconciliationIssue {
  String get label => switch (this) {
    InvoiceLedgerReconciliationIssue.missingJournalLink =>
      'الفاتورة بلا رابط قيد',
    InvoiceLedgerReconciliationIssue.missingJournalEntry =>
      'القيد المرتبط غير موجود',
    InvoiceLedgerReconciliationIssue.journalNotPosted => 'القيد غير مرحّل',
    InvoiceLedgerReconciliationIssue.missingTenantAccount =>
      'حساب ذمم المستأجر غير محدد',
    InvoiceLedgerReconciliationIssue.missingInvoiceContract =>
      'عقد الفاتورة غير مرتبط',
    InvoiceLedgerReconciliationIssue.missingInvoiceInstallment =>
      'قسط الفاتورة غير مرتبط',
    InvoiceLedgerReconciliationIssue.missingTaxAccountSource =>
      'حساب الضريبة غير محفوظ بالفاتورة',
    InvoiceLedgerReconciliationIssue.invoiceInstallmentContractMismatch =>
      'عقد الفاتورة لا يطابق عقد القسط',
    InvoiceLedgerReconciliationIssue.installmentAmountMismatch =>
      'صافي الفاتورة لا يطابق مبلغ القسط',
    InvoiceLedgerReconciliationIssue.duplicateJournalLink =>
      'القيد مرتبط بأكثر من فاتورة',
    InvoiceLedgerReconciliationIssue.invoiceTotalMismatch =>
      'صافي الفاتورة والضريبة لا يساويان إجماليها',
    InvoiceLedgerReconciliationIssue.journalUnbalanced => 'القيد غير متوازن',
    InvoiceLedgerReconciliationIssue.journalTotalMismatch =>
      'إجمالي القيد لا يطابق إجمالي الفاتورة',
    InvoiceLedgerReconciliationIssue.tenantReceivableMismatch =>
      'مدين ذمم المستأجر غير مطابق',
    InvoiceLedgerReconciliationIssue.revenueMismatch =>
      'دائن الإيراد غير مطابق لصافي الفاتورة',
    InvoiceLedgerReconciliationIssue.taxLiabilityMismatch =>
      'دائن حساب الضريبة المحفوظ غير مطابق',
  };
}

class InvoiceLedgerReconciliationRow {
  InvoiceLedgerReconciliationRow._({
    required this.invoiceId,
    required this.invoiceDate,
    required this.tenantName,
    required this.tenantAccountId,
    required this.netMinor,
    required this.taxMinor,
    required this.totalMinor,
    required this.taxAccountId,
    required this.journalEntryId,
    required this.journalExists,
    required this.journalPosted,
    required this.invoiceContractMissing,
    required this.invoiceInstallmentMissing,
    required this.invoiceInstallmentContractMismatch,
    required this.installmentAmountMinor,
    required this.installmentAmountMismatch,
    required this.linkedInvoiceCount,
    required this.journalDebitMinor,
    required this.journalCreditMinor,
    required this.tenantReceivableDebitMinor,
    required this.revenueCreditMinor,
    required this.taxLiabilityCreditMinor,
    required List<InvoiceLedgerReconciliationIssue> issues,
  }) : issues = List.unmodifiable(issues);

  factory InvoiceLedgerReconciliationRow.fromMap(Map<String, Object?> row) {
    int minor(String key) => (row[key] as num?)?.toInt() ?? 0;
    int? optionalId(String key) => (row[key] as num?)?.toInt();
    final invoiceId = (row['invoice_id'] as num).toInt();
    final netMinor = minor('net_minor');
    final taxMinor = minor('tax_minor');
    final totalMinor = minor('total_minor');
    final taxAccountId = optionalId('tax_account_id');
    final journalEntryId = optionalId('journal_entry_id');
    final journalExists = minor('journal_entry_exists') == 1;
    final journalPosted = minor('journal_is_posted') == 1;
    final invoiceContractMissing = minor('invoice_contract_missing') == 1;
    final invoiceInstallmentMissing = minor('invoice_installment_missing') == 1;
    final invoiceInstallmentContractMismatch =
        minor('invoice_installment_contract_mismatch') == 1;
    final installmentAmountMismatch =
        minor('invoice_installment_amount_mismatch') == 1;
    final installmentAmountMinor = (row['installment_amount_minor'] as num?)
        ?.toInt();
    final linkedInvoiceCount = minor('linked_invoice_count');
    final journalDebitMinor = minor('journal_debit_minor');
    final journalCreditMinor = minor('journal_credit_minor');
    final tenantAccountId = optionalId('tenant_account_id');
    final tenantReceivableDebitMinor = minor('tenant_receivable_debit_minor');
    final revenueCreditMinor = minor('revenue_credit_minor');
    final taxLiabilityCreditMinor = minor('tax_liability_credit_minor');
    final issues = <InvoiceLedgerReconciliationIssue>[];

    if (netMinor + taxMinor != totalMinor) {
      issues.add(InvoiceLedgerReconciliationIssue.invoiceTotalMismatch);
    }
    if (taxMinor > 0 && taxAccountId == null) {
      issues.add(InvoiceLedgerReconciliationIssue.missingTaxAccountSource);
    }
    if (invoiceContractMissing) {
      issues.add(InvoiceLedgerReconciliationIssue.missingInvoiceContract);
    }
    if (invoiceInstallmentMissing) {
      issues.add(InvoiceLedgerReconciliationIssue.missingInvoiceInstallment);
    }
    if (invoiceInstallmentContractMismatch) {
      issues.add(
        InvoiceLedgerReconciliationIssue.invoiceInstallmentContractMismatch,
      );
    }
    if (installmentAmountMismatch) {
      issues.add(InvoiceLedgerReconciliationIssue.installmentAmountMismatch);
    }
    if (journalEntryId == null) {
      issues.add(InvoiceLedgerReconciliationIssue.missingJournalLink);
    } else if (!journalExists) {
      issues.add(InvoiceLedgerReconciliationIssue.missingJournalEntry);
    } else {
      if (linkedInvoiceCount > 1) {
        issues.add(InvoiceLedgerReconciliationIssue.duplicateJournalLink);
      }
      if (!journalPosted) {
        issues.add(InvoiceLedgerReconciliationIssue.journalNotPosted);
      } else {
        if (tenantAccountId == null) {
          issues.add(InvoiceLedgerReconciliationIssue.missingTenantAccount);
        }
        if (journalDebitMinor != journalCreditMinor) {
          issues.add(InvoiceLedgerReconciliationIssue.journalUnbalanced);
        }
        if (journalDebitMinor != totalMinor ||
            journalCreditMinor != totalMinor) {
          issues.add(InvoiceLedgerReconciliationIssue.journalTotalMismatch);
        }
        if (tenantAccountId != null &&
            tenantReceivableDebitMinor != totalMinor) {
          issues.add(InvoiceLedgerReconciliationIssue.tenantReceivableMismatch);
        }
        if (revenueCreditMinor != netMinor) {
          issues.add(InvoiceLedgerReconciliationIssue.revenueMismatch);
        }
        if (taxAccountId != null && taxLiabilityCreditMinor != taxMinor) {
          issues.add(InvoiceLedgerReconciliationIssue.taxLiabilityMismatch);
        }
      }
    }

    return InvoiceLedgerReconciliationRow._(
      invoiceId: invoiceId,
      invoiceDate: row['invoice_date']?.toString() ?? '',
      tenantName: row['tenant_name']?.toString(),
      tenantAccountId: tenantAccountId,
      netMinor: netMinor,
      taxMinor: taxMinor,
      totalMinor: totalMinor,
      taxAccountId: taxAccountId,
      journalEntryId: journalEntryId,
      journalExists: journalExists,
      journalPosted: journalPosted,
      invoiceContractMissing: invoiceContractMissing,
      invoiceInstallmentMissing: invoiceInstallmentMissing,
      invoiceInstallmentContractMismatch: invoiceInstallmentContractMismatch,
      installmentAmountMinor: installmentAmountMinor,
      installmentAmountMismatch: installmentAmountMismatch,
      linkedInvoiceCount: linkedInvoiceCount,
      journalDebitMinor: journalDebitMinor,
      journalCreditMinor: journalCreditMinor,
      tenantReceivableDebitMinor: tenantReceivableDebitMinor,
      revenueCreditMinor: revenueCreditMinor,
      taxLiabilityCreditMinor: taxLiabilityCreditMinor,
      issues: issues,
    );
  }

  final int invoiceId;
  final String invoiceDate;
  final String? tenantName;
  final int? tenantAccountId;
  final int netMinor;
  final int taxMinor;
  final int totalMinor;
  final int? taxAccountId;
  final int? journalEntryId;
  final bool journalExists;
  final bool journalPosted;
  final bool invoiceContractMissing;
  final bool invoiceInstallmentMissing;
  final bool invoiceInstallmentContractMismatch;
  final int? installmentAmountMinor;
  final bool installmentAmountMismatch;
  final int linkedInvoiceCount;
  final int journalDebitMinor;
  final int journalCreditMinor;
  final int tenantReceivableDebitMinor;
  final int revenueCreditMinor;
  final int taxLiabilityCreditMinor;
  final List<InvoiceLedgerReconciliationIssue> issues;

  bool get isReconciled => issues.isEmpty;
  String get statusLabel => isReconciled ? 'مطابق' : 'يحتاج مراجعة';
  String get issueSummary => issues.map((issue) => issue.label).join('، ');
}

class InvoiceLedgerReconciliationReport {
  InvoiceLedgerReconciliationReport({
    required this.startDate,
    required this.endDate,
    required this.currency,
    required List<InvoiceLedgerReconciliationRow> rows,
  }) : rows = List.unmodifiable(rows);

  final String startDate;
  final String endDate;
  final String currency;
  final List<InvoiceLedgerReconciliationRow> rows;

  int get invoiceCount => rows.length;
  int get reconciledCount => rows.where((row) => row.isReconciled).length;
  int get reviewCount => invoiceCount - reconciledCount;
  int get invoiceTotalMinor => rows.fold(0, (sum, row) => sum + row.totalMinor);
}
