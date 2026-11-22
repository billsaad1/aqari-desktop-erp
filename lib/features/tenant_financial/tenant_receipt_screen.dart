import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';
import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import 'tenant_receivable_sorter.dart';

class TenantReceiptScreen extends StatefulWidget {
  const TenantReceiptScreen({super.key});

  @override
  State<TenantReceiptScreen> createState() => _TenantReceiptScreenState();
}

class _TenantReceiptScreenState extends State<TenantReceiptScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  int? _selectedTenantId;
  int? _selectedCashAccountId;
  int? _selectedInvoiceId;
  int? _selectedInstallmentId;
  int? _selectedPropertyId;
  int? _selectedContractId;
  bool _isInvoicePaymentMode = false;

  List<Map<String, dynamic>> _unpaidInstallments = [];
  List<Map<String, dynamic>> _openTaxInvoices = [];
  bool _isLoadingReceivables = false;
  bool _isProcessing = false;
  List<Map<String, dynamic>> _legacyPayments = [];
  List<Map<String, dynamic>> _legacyInvoices = [];
  String? _legacyPaymentsError;
  int _receivablesRequestId = 0;

  Map<String, dynamic>? get _selectedInvoice {
    for (final invoice in _openTaxInvoices) {
      final id = invoice['id'];
      if (id is num && id.toInt() == _selectedInvoiceId) return invoice;
    }
    return null;
  }

  Map<String, dynamic>? get _selectedInstallment {
    for (final installment in _unpaidInstallments) {
      final id = installment['id'];
      if (id is num && id.toInt() == _selectedInstallmentId) {
        return installment;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get _allReceivables => _isInvoicePaymentMode
      ? _openTaxInvoices
      : _unpaidInstallments;

  int? _rowId(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  List<Map<String, dynamic>> _propertyOptions(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final options = <int, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = _rowId(row, 'property_id');
      if (id != null) options.putIfAbsent(id, () => row);
    }
    final result = options.values.toList();
    result.sort(
      (a, b) => (a['property_name'] ?? '').toString().toLowerCase().compareTo(
        (b['property_name'] ?? '').toString().toLowerCase(),
      ),
    );
    return result;
  }

  List<Map<String, dynamic>> _contractOptions(
    Iterable<Map<String, dynamic>> rows, {
    int? propertyId,
  }) {
    final options = <int, Map<String, dynamic>>{};
    for (final row in rows) {
      if (propertyId != null && _rowId(row, 'property_id') != propertyId) {
        continue;
      }
      final id = _rowId(row, 'contract_id');
      if (id != null) options.putIfAbsent(id, () => row);
    }
    return options.values.toList();
  }

  bool get _needsPropertySelection =>
      _propertyOptions(_allReceivables).length > 1 &&
      _selectedPropertyId == null;

  bool get _needsContractSelection {
    if (_needsPropertySelection) return false;
    return _contractOptions(
          _allReceivables,
          propertyId: _selectedPropertyId,
        ).length >
        1 &&
        _selectedContractId == null;
  }

  List<Map<String, dynamic>> get _visibleReceivables {
    if (_needsPropertySelection || _needsContractSelection) return const [];
    return filterTenantReceivables(
      receivables: _allReceivables,
      propertyId: _selectedPropertyId,
      contractId: _selectedContractId,
    );
  }

  String _amountInput(dynamic value) =>
      ((value as num?) ?? 0).toDouble().toStringAsFixed(2);

  String _displayAmount(dynamic value) =>
      NumberFormat('#,##0.00').format(((value as num?) ?? 0).toDouble());

  bool _isFutureDueDate(Object? value) {
    final dueDate = DateTime.tryParse(value?.toString() ?? '');
    if (dueDate == null) return false;
    final today = DateTime.now();
    return DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
    ).isAfter(DateTime(today.year, today.month, today.day));
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) {
      setState(
        () => _dateController.text = DateFormat('yyyy-MM-dd').format(date),
      );
    }
  }

  Future<void> _loadTenantReceivables(int? tenantId) async {
    final requestId = ++_receivablesRequestId;
    final invoiceMode = _isInvoicePaymentMode;
    setState(() {
      _isLoadingReceivables = tenantId != null;
      _unpaidInstallments = [];
      _openTaxInvoices = [];
      _selectedInvoiceId = null;
      _selectedInstallmentId = null;
      _selectedPropertyId = null;
      _selectedContractId = null;
      _amountController.clear();
      if (tenantId == null) {
        _legacyPayments = [];
        _legacyInvoices = [];
        _legacyPaymentsError = null;
      }
    });
    if (tenantId == null) return;

    try {
      final results = await Future.wait([
        invoiceMode
            ? DatabaseHelper.instance.getOpenTaxInvoicesForTenant(tenantId)
            : DatabaseHelper.instance.getUnbilledInstallmentsForTenant(
                tenantId,
              ),
        DatabaseHelper.instance.getPendingLegacyTenantPayments(tenantId),
        DatabaseHelper.instance.getPendingLegacyInvoiceReviewsForTenant(
          tenantId,
        ),
      ]);
      final receivables = sortInstallmentsByDueDate(results[0]);
      final properties = _propertyOptions(receivables);
      final propertyId = properties.length == 1
          ? _rowId(properties.single, 'property_id')
          : null;
      final contracts = _contractOptions(
        receivables,
        propertyId: propertyId,
      );
      final contractId = contracts.length == 1
          ? _rowId(contracts.single, 'contract_id')
          : null;
      if (!mounted ||
          requestId != _receivablesRequestId ||
          tenantId != _selectedTenantId ||
          invoiceMode != _isInvoicePaymentMode) {
        return;
      }
      setState(() {
        _selectedPropertyId = propertyId;
        _selectedContractId = contractId;
        _legacyPayments = results[1];
        _legacyInvoices = results[2];
        _legacyPaymentsError = null;
        if (invoiceMode) {
          _openTaxInvoices = receivables;
        } else {
          _unpaidInstallments = receivables;
        }
        _isLoadingReceivables = false;
      });
    } catch (error) {
      if (!mounted ||
          requestId != _receivablesRequestId ||
          tenantId != _selectedTenantId ||
          invoiceMode != _isInvoicePaymentMode) {
        return;
      }
      setState(() {
        _isLoadingReceivables = false;
        _legacyPaymentsError =
            'تعذر التحقق من المراجعات أو تحميل المستحقات: $error';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            invoiceMode
                ? 'تعذر تحميل الفواتير: $error'
                : 'تعذر تحميل الأقساط: $error',
          ),
        ),
      );
    }
  }

  void _onTenantChanged(int? tenantId) {
    setState(() {
      _selectedTenantId = tenantId;
      _selectedInvoiceId = null;
      _selectedInstallmentId = null;
      _selectedPropertyId = null;
      _selectedContractId = null;
      _unpaidInstallments = [];
      _openTaxInvoices = [];
      _amountController.clear();
      _descriptionController.clear();
      _legacyPayments = [];
      _legacyInvoices = [];
      _legacyPaymentsError = null;
    });
    _loadTenantReceivables(tenantId);
  }

  void _onModeChanged(bool? invoiceMode) {
    if (invoiceMode == null) return;
    setState(() {
      _isInvoicePaymentMode = invoiceMode;
      _selectedInvoiceId = null;
      _selectedInstallmentId = null;
      _selectedPropertyId = null;
      _selectedContractId = null;
      _unpaidInstallments = [];
      _openTaxInvoices = [];
      _amountController.clear();
      _descriptionController.clear();
    });
    _loadTenantReceivables(_selectedTenantId);
  }

  void _onPropertyChanged(int? propertyId) {
    final contracts = _contractOptions(
      _allReceivables,
      propertyId: propertyId,
    );
    final contractId = contracts.length == 1
        ? _rowId(contracts.single, 'contract_id')
        : null;
    setState(() {
      _selectedPropertyId = propertyId;
      _selectedContractId = contractId;
      _selectedInvoiceId = null;
      _selectedInstallmentId = null;
      _amountController.clear();
    });
  }

  void _onContractChanged(int? contractId) {
    setState(() {
      _selectedContractId = contractId;
      _selectedInvoiceId = null;
      _selectedInstallmentId = null;
      _amountController.clear();
    });
  }

  void _onInvoiceChanged(int? invoiceId) {
    setState(() {
      _selectedInvoiceId = invoiceId;
      final invoice = _selectedInvoice;
      _amountController.text = invoice == null
          ? ''
          : _amountInput(invoice['remaining_amount']);
    });
  }

  void _onInstallmentChanged(int? installmentId) {
    setState(() {
      _selectedInstallmentId = installmentId;
      final installment = _selectedInstallment;
      if (installment == null) {
        _amountController.clear();
      } else {
        final total = (installment['amount'] as num).toDouble();
        final paid = ((installment['paid_amount'] as num?) ?? 0).toDouble();
        _amountController.text = _amountInput((total - paid).clamp(0, total));
      }
    });
  }

  Future<void> _processReceipt({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    if (_legacyPaymentsError != null ||
        _legacyPayments.isNotEmpty ||
        _legacyInvoices.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _legacyPaymentsError ??
                (_legacyInvoices.isNotEmpty
                    ? 'راجع الفواتير التاريخية غير المرتبطة بقسط قبل تسجيل أي حركة جديدة'
                    : 'راجع سندات الصرف التاريخية للمستأجر قبل تسجيل قبض جديد'),
          ),
        ),
      );
      return;
    }
    if (!_formKey.currentState!.validate() ||
        _selectedTenantId == null ||
        _selectedCashAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة')),
      );
      return;
    }

    final invoice = _isInvoicePaymentMode ? _selectedInvoice : null;
    if (_isInvoicePaymentMode && invoice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار الفاتورة المراد سدادها')),
      );
      return;
    }
    final installment = _isInvoicePaymentMode ? null : _selectedInstallment;
    if (!_isInvoicePaymentMode && installment == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر القسط المراد تحصيله أولاً')),
      );
      return;
    }

    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (!amount.isFinite || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')),
      );
      return;
    }
    final amountCents = (amount * 100).round();
    if (amountCents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')),
      );
      return;
    }

    if (invoice != null) {
      final remainingCents =
          (((invoice['remaining_amount'] as num).toDouble()) * 100).round();
      if (amountCents > remainingCents) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'المبلغ يتجاوز المتبقي على الفاتورة (${_displayAmount(invoice['remaining_amount'])})',
            ),
          ),
        );
        return;
      }
    } else if (installment != null) {
      final totalCents = ((installment['amount'] as num).toDouble() * 100)
          .round();
      final paidCents =
          (((installment['paid_amount'] as num?) ?? 0).toDouble() * 100)
              .round();
      if (amountCents > totalCents - paidCents) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'المبلغ يتجاوز المتبقي على الدفعة (${_displayAmount((totalCents - paidCents) / 100)})',
            ),
          ),
        );
        return;
      }
    }

    final receiptTenantId = _selectedTenantId!;
    final cashAccountId = _selectedCashAccountId!;
    final receiptDate = _dateController.text;
    final invoiceId = invoice == null ? null : (invoice['id'] as num).toInt();
    final invoiceMode = _isInvoicePaymentMode;
    final updates = <Map<String, dynamic>>[];
    if (!invoiceMode) {
      final selected = installment!;
      final totalMinor = ((selected['amount'] as num).toDouble() * 100).round();
      final oldPaidMinor =
          (((selected['paid_amount'] as num?) ?? 0).toDouble() * 100).round();
      final newPaidMinor = oldPaidMinor + amountCents;
      updates.add({
        'id': selected['id'],
        'paid_amount': newPaidMinor / 100,
        'status': newPaidMinor >= totalMinor ? 'Paid' : 'Partially Paid',
      });
    }

    final leasingProvider = Provider.of<LeasingProvider>(
      context,
      listen: false,
    );
    final accountingProvider = Provider.of<AccountingProvider>(
      context,
      listen: false,
    );
    setState(() => _isProcessing = true);
    late final int voucherId;
    try {
      if (invoiceMode) {
        voucherId = await DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: receiptTenantId,
          amount: amountCents / 100,
          voucherDate: receiptDate,
          cashAccountId: cashAccountId,
          installmentsToUpdate: const [],
          invoiceId: invoiceId!,
          description: _descriptionController.text.trim(),
        );
      } else {
        voucherId = await DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: receiptTenantId,
          amount: amountCents / 100,
          voucherDate: receiptDate,
          cashAccountId: cashAccountId,
          installmentsToUpdate: updates,
          description: _descriptionController.text.trim(),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ سند القبض: $e')));
        setState(() => _isProcessing = false);
      }
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          invoiceMode
              ? 'تم حفظ سند القبض رقم $voucherId لسداد الفاتورة رقم $invoiceId وترحيل القيد'
              : 'تم حفظ سند القبض رقم $voucherId وترحيل القيد',
        ),
      ),
    );
    try {
      final tenantName = leasingProvider.tenants
          .firstWhere((t) => t['id'] == receiptTenantId)['name']
          .toString();
      final accountName = accountingProvider.accounts
          .firstWhere((a) => a['id'] == cashAccountId)['name']
          .toString();
      final voucherDetails = await DatabaseHelper.instance
          .getTenantReceiptVoucherDetails(voucherId);
      if (voucherDetails == null) {
        throw StateError('تعذر تحميل تخصيصات سند الفاتورة');
      }
      final installmentAllocations = voucherDetails['installments'] is List
          ? (voucherDetails['installments'] as List)
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];
      final invoiceAllocations = voucherDetails['invoices'] is List
          ? (voucherDetails['invoices'] as List)
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: voucherId,
        date: receiptDate,
        targetName: tenantName,
        amount: amountCents / 100,
        paymentMethod: null,
        accountName: accountName,
        description: _descriptionController.text.trim(),
        installmentAllocations: installmentAllocations,
        invoiceAllocations: invoiceAllocations,
      );
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: pdfBytes,
          fileName: 'سند_قبض_مستأجر_$voucherId',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'tenant_financial',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ السند رقم $voucherId، لكن تعذر تجهيز/طباعة المستند: $e',
            ),
          ),
        );
      }
    }

    try {
      await accountingProvider.loadAccounts();
      if (mounted && _selectedTenantId == receiptTenantId) {
        await _loadTenantReceivables(receiptTenantId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حُفظ السند، لكن تعذر تحديث البيانات: $e')),
        );
      }
    }
    if (mounted) {
      _amountController.clear();
      _descriptionController.clear();
      setState(() => _isProcessing = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProv, accProv, child) {
        if (leasingProv.isLoading || accProv.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        final cashAccounts = accProv.detailAccounts
            .where(
              (a) =>
                  a['account_type'] == 'Asset' &&
                  a['code'].toString().startsWith('11') &&
                  a['parent_id'] != null,
            )
            .toList();
        final propertyOptions = _propertyOptions(_allReceivables);
        final contractOptions = _contractOptions(
          _allReceivables,
          propertyId: _selectedPropertyId,
        );
        final visibleReceivables = _visibleReceivables;

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left Panel: Form
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  child: Form(
                    key: _formKey,
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'سند قبض مستأجر',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                      if (_legacyPaymentsError != null ||
                          _legacyPayments.isNotEmpty ||
                          _legacyInvoices.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: Colors.amber.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _legacyPaymentsError ??
                                  'مراجعة مطلوبة: ${_legacyPayments.length} سند صرف قديم و${_legacyInvoices.length} فاتورة تاريخية غير مرتبطة بقسط. استخدم شاشة الاسترداد أو مراجعة الفواتير قبل أي حركة.',
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      DropdownButtonFormField<int>(
                        initialValue: _selectedTenantId,
                        items: leasingProv.tenants
                            .map(
                              (t) => DropdownMenuItem<int>(
                                value: (t['id'] as num).toInt(),
                                child: Text(t['name'].toString()),
                              ),
                            )
                            .toList(),
                        onChanged: _isProcessing ? null : _onTenantChanged,
                        decoration: const InputDecoration(
                          labelText: 'المستأجر',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<bool>(
                        initialValue: _isInvoicePaymentMode,
                        items: const [
                          DropdownMenuItem<bool>(
                            value: false,
                            child: Text('تحصيل الأقساط'),
                          ),
                          DropdownMenuItem<bool>(
                            value: true,
                            child: Text('سداد فاتورة'),
                          ),
                        ],
                        onChanged: _isProcessing ? null : _onModeChanged,
                        decoration: const InputDecoration(
                          labelText: 'نوع العملية',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_selectedTenantId != null &&
                          !_isLoadingReceivables &&
                          _allReceivables.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          key: ValueKey('property-$_selectedPropertyId'),
                          initialValue: _selectedPropertyId,
                          items: propertyOptions.map((property) {
                            final id = _rowId(property, 'property_id')!;
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                property['property_name']?.toString() ??
                                    'العقار رقم $id',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing || propertyOptions.isEmpty
                              ? null
                              : _onPropertyChanged,
                          decoration: const InputDecoration(
                            labelText: 'العقار الذي سيتم التحصيل منه',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          key: ValueKey('contract-$_selectedContractId'),
                          initialValue: _selectedContractId,
                          items: contractOptions.map((contract) {
                            final id = _rowId(contract, 'contract_id')!;
                            final propertyName =
                                contract['property_name']?.toString() ??
                                'العقار';
                            final unitNumber =
                                contract['unit_number']?.toString() ??
                                'غير محدد';
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                '$propertyName — الوحدة $unitNumber — العقد #$id',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing ||
                                  contractOptions.isEmpty ||
                                  (_needsPropertySelection &&
                                      propertyOptions.length > 1)
                              ? null
                              : _onContractChanged,
                          decoration: const InputDecoration(
                            labelText: 'الوحدة / العقد',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _needsPropertySelection
                              ? 'اختر العقار أولاً لعرض وحداته وعقوده.'
                              : _needsContractSelection
                              ? 'اختر الوحدة أو العقد المطلوب؛ ستظهر أقساط هذا العقد فقط.'
                              : 'اختر العقار والوحدة/العقد الصحيحين قبل تحديد القسط.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (_isInvoicePaymentMode) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          key: ValueKey('invoice-$_selectedInvoiceId'),
                          initialValue: _selectedInvoiceId,
                          items: visibleReceivables.map((invoice) {
                            final id = (invoice['id'] as num).toInt();
                            final propertyName =
                                invoice['property_name']?.toString() ??
                                'العقار';
                            final unitNumber =
                                invoice['unit_number']?.toString() ??
                                'غير محدد';
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                'فاتورة #$id | $propertyName — الوحدة $unitNumber | المتبقي: ${_displayAmount(invoice['remaining_amount'])}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing ||
                                  _needsPropertySelection ||
                                  _needsContractSelection
                              ? null
                              : _onInvoiceChanged,
                          validator: (value) => value == null ? 'مطلوب' : null,
                          decoration: const InputDecoration(
                            labelText: 'الفاتورة المراد سدادها',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      if (!_isInvoicePaymentMode) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          key: ValueKey('installment-$_selectedInstallmentId'),
                          initialValue: _selectedInstallmentId,
                          items: visibleReceivables.map((installment) {
                            final id = (installment['id'] as num).toInt();
                            final total = (installment['amount'] as num)
                                .toDouble();
                            final paid =
                                ((installment['paid_amount'] as num?) ?? 0)
                                    .toDouble();
                            final isFuture = _isFutureDueDate(
                              installment['due_date'],
                            );
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                'الدفعة ${installment['installment_number'] ?? '—'}${isFuture ? ' (مستقبلية)' : ''} | ${installment['property_name'] ?? 'العقار'} - ${installment['unit_number'] ?? 'الوحدة'} | ${installment['due_date']} | المتبقي ${_displayAmount(total - paid)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing ||
                                  _isLoadingReceivables ||
                                  _needsPropertySelection ||
                                  _needsContractSelection
                              ? null
                              : _onInstallmentChanged,
                          validator: (value) =>
                              value == null ? 'اختر الدفعة' : null,
                          decoration: const InputDecoration(
                            labelText: 'الدفعة المراد تحصيلها',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (_selectedInstallment != null) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'يمكن تحصيل القسط قبل موعده. إذا كان القسط مرتبطًا بفاتورة، اختر «سداد فاتورة».',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            'الدفعة ${_selectedInstallment!['installment_number'] ?? '—'} — المبلغ: ${_displayAmount(_selectedInstallment!['amount'])} — الاستحقاق: ${_selectedInstallment!['due_date']}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      DropdownButtonFormField<int>(
                        initialValue: _selectedCashAccountId,
                        items: cashAccounts
                            .map(
                              (a) => DropdownMenuItem<int>(
                                value: (a['id'] as num).toInt(),
                                child: Text('${a['code']} - ${a['name']}'),
                              ),
                            )
                            .toList(),
                        onChanged: _isProcessing
                            ? null
                            : (val) =>
                                  setState(() => _selectedCashAccountId = val),
                        decoration: const InputDecoration(
                          labelText: 'يُقبض إلى حساب (الصندوق/البنك)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _dateController,
                        decoration: const InputDecoration(
                          labelText: 'تاريخ السند',
                          border: OutlineInputBorder(),
                        ),
                        readOnly: true,
                        onTap: _isProcessing ? null : _pickDate,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _amountController,
                        enabled: !_isProcessing,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: _isInvoicePaymentMode
                              ? 'المبلغ المسدد'
                              : 'المبلغ المستلم',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final amount = double.tryParse(value ?? '');
                          if (amount == null || !amount.isFinite) {
                            return 'أدخل مبلغاً صحيحاً';
                          }
                          if (amount <= 0) {
                            return 'المبلغ يجب أن يكون أكبر من صفر';
                          }
                          final invoice = _isInvoicePaymentMode
                              ? _selectedInvoice
                              : null;
                          if (invoice != null) {
                            final amountCents = (amount * 100).round();
                            final remainingCents =
                                (((invoice['remaining_amount'] as num)
                                            .toDouble()) *
                                        100)
                                    .round();
                            if (amountCents > remainingCents) {
                              return 'المبلغ يتجاوز المتبقي على الفاتورة';
                            }
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        enabled: !_isProcessing,
                        minLines: 1,
                        maxLines: 2,
                        maxLength: 240,
                        decoration: const InputDecoration(
                          labelText: 'البيان (اختياري)',
                          hintText: 'اكتب بيان السند يدويًا إن رغبت',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  _isProcessing ||
                                      _isLoadingReceivables ||
                                      _legacyPaymentsError != null ||
                                      _legacyPayments.isNotEmpty ||
                                      _legacyInvoices.isNotEmpty ||
                                      !PermissionRuntime.allows(
                                        'tenant_financial',
                                        AppPermissionAction.post,
                                      )
                                  ? null
                                  : () => _processReceipt(saveAsPdf: false),
                              icon: const Icon(Icons.print),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                padding: const EdgeInsets.all(16),
                              ),
                              label: Text(
                                PermissionRuntime.allows(
                                      'tenant_financial',
                                      AppPermissionAction.print,
                                    )
                                    ? 'حفظ وترحيل وطباعة'
                                    : 'حفظ وترحيل ومعاينة',
                              ),
                            ),
                          ),
                          if (PermissionRuntime.allows(
                            'tenant_financial',
                            AppPermissionAction.print,
                          )) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _isProcessing ||
                                        _isLoadingReceivables ||
                                        _legacyPaymentsError != null ||
                                        _legacyPayments.isNotEmpty ||
                                        _legacyInvoices.isNotEmpty ||
                                        !PermissionRuntime.allows(
                                          'tenant_financial',
                                          AppPermissionAction.post,
                                        )
                                    ? null
                                    : () => _processReceipt(saveAsPdf: true),
                                icon: const Icon(Icons.picture_as_pdf),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.all(16),
                                ),
                                label: const Text('حفظ السند PDF'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              ),
              const SizedBox(width: 24),
              // Right Panel: Receivables for the selected mode
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _isInvoicePaymentMode
                          ? 'الفواتير المفتوحة'
                          : 'الأقساط المستحقة غير المفوترة',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_selectedTenantId == null)
                      Center(
                        child: Text(
                          _isInvoicePaymentMode
                              ? 'الرجاء اختيار مستأجر لعرض الفواتير'
                              : 'الرجاء اختيار مستأجر لعرض الأقساط',
                        ),
                      )
                    else if (_isLoadingReceivables)
                      const Center(child: CircularProgressIndicator())
                    else if (_needsPropertySelection)
                      const Center(
                        child: Text('اختر العقار أولاً لعرض المستحقات التابعة له'),
                      )
                    else if (_needsContractSelection)
                      const Center(
                        child: Text('اختر الوحدة أو العقد لعرض أقساطه فقط'),
                      )
                    else if (_isInvoicePaymentMode && _openTaxInvoices.isEmpty)
                      const Center(
                        child: Text(
                          'لا توجد فواتير مفتوحة على هذا المستأجر',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    else if (!_isInvoicePaymentMode &&
                        _unpaidInstallments.isEmpty)
                      const Center(
                        child: Text(
                          'لا توجد مستحقات مالية على هذا المستأجر',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: _isInvoicePaymentMode
                            ? ListView.builder(
                                itemCount: visibleReceivables.length,
                                itemBuilder: (context, index) {
                                  final invoice = visibleReceivables[index];
                                  final id = (invoice['id'] as num).toInt();
                                  final isSelected = id == _selectedInvoiceId;
                                  return Card(
                                    color: isSelected
                                        ? const Color.fromRGBO(
                                            76,
                                            175,
                                            80,
                                            0.08,
                                          )
                                        : null,
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.receipt_long,
                                        color: Colors.deepOrange,
                                      ),
                                      title: Text(
                                        'فاتورة رقم $id | ${invoice['property_name'] ?? 'العقار'} — الوحدة ${invoice['unit_number'] ?? '—'}',
                                      ),
                                      subtitle: Text(
                                        'تاريخ الفاتورة: ${invoice['invoice_date']} | الاستحقاق: ${invoice['due_date']}\n'
                                        'العقد: ${invoice['contract_id']} | القسط: ${invoice['installment_id']}\n'
                                        'الصافي: ${_displayAmount(invoice['net_amount'])} | الضريبة: ${_displayAmount(invoice['tax_amount'])} | الإجمالي: ${_displayAmount(invoice['total_amount'])} | المدفوع: ${_displayAmount(invoice['paid_amount'])}',
                                      ),
                                      trailing: Text(
                                        'المتبقي: ${_displayAmount(invoice['remaining_amount'])}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              )
                            : ListView.builder(
                                itemCount: visibleReceivables.length,
                                itemBuilder: (context, index) {
                                  final installment = visibleReceivables[index];
                                  final total = (installment['amount'] as num)
                                      .toDouble();
                                  final paid =
                                      ((installment['paid_amount'] as num?) ??
                                              0)
                                          .toDouble();
                                  final remaining = total - paid;
                                  final isSelected =
                                      (installment['id'] as num).toInt() ==
                                      _selectedInstallmentId;
                                  return Card(
                                    color: isSelected
                                        ? Colors.green.withValues(alpha: 0.08)
                                        : null,
                                    child: ListTile(
                                      onTap: _isProcessing
                                          ? null
                                          : () => _onInstallmentChanged(
                                              (installment['id'] as num)
                                                  .toInt(),
                                            ),
                                      leading: const Icon(
                                        Icons.warning,
                                        color: Colors.orange,
                                      ),
                                      title: Text(
                                        'الدفعة ${installment['installment_number'] ?? '—'} | ${installment['property_name'] ?? 'العقار'} - ${installment['unit_number'] ?? 'الوحدة'} | الاستحقاق: ${installment['due_date']}',
                                      ),
                                      subtitle: Text(
                                        'الحالة: ${installment['status']} | المدفوع سابقاً: ${_displayAmount(paid)}',
                                      ),
                                      trailing: Text(
                                        'المتبقي: ${_displayAmount(remaining)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
