import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';
import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';

class TenantReceiptScreen extends StatefulWidget {
  const TenantReceiptScreen({super.key});

  @override
  State<TenantReceiptScreen> createState() => _TenantReceiptScreenState();
}

class _TenantReceiptScreenState extends State<TenantReceiptScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  int? _selectedTenantId;
  int? _selectedCashAccountId;
  int? _selectedInvoiceId;
  bool _isInvoicePaymentMode = false;

  List<Map<String, dynamic>> _unpaidInstallments = [];
  List<Map<String, dynamic>> _openTaxInvoices = [];
  bool _isLoadingReceivables = false;
  bool _isProcessing = false;
  int _receivablesRequestId = 0;

  Map<String, dynamic>? get _selectedInvoice {
    for (final invoice in _openTaxInvoices) {
      final id = invoice['id'];
      if (id is num && id.toInt() == _selectedInvoiceId) return invoice;
    }
    return null;
  }

  String _amountInput(dynamic value) =>
      ((value as num?) ?? 0).toDouble().toStringAsFixed(2);

  String _displayAmount(dynamic value) =>
      NumberFormat('#,##0.00').format(((value as num?) ?? 0).toDouble());

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
      _amountController.clear();
    });
    if (tenantId == null) return;

    try {
      if (invoiceMode) {
        final invoices = await DatabaseHelper.instance
            .getOpenTaxInvoicesForTenant(tenantId);
        if (!mounted ||
            requestId != _receivablesRequestId ||
            tenantId != _selectedTenantId ||
            invoiceMode != _isInvoicePaymentMode) {
          return;
        }
        setState(() {
          _openTaxInvoices = invoices;
          _isLoadingReceivables = false;
        });
      } else {
        final installments = await DatabaseHelper.instance
            .getUnbilledInstallmentsForTenant(tenantId);
        installments.sort(
          (a, b) =>
              a['due_date'].toString().compareTo(b['due_date'].toString()),
        );
        if (!mounted ||
            requestId != _receivablesRequestId ||
            tenantId != _selectedTenantId ||
            invoiceMode != _isInvoicePaymentMode) {
          return;
        }
        setState(() {
          _unpaidInstallments = installments;
          _isLoadingReceivables = false;
          if (_unpaidInstallments.isNotEmpty) {
            final first = _unpaidInstallments.first;
            final totalCents = ((first['amount'] as num).toDouble() * 100)
                .round();
            final paidCents =
                (((first['paid_amount'] as num?) ?? 0).toDouble() * 100)
                    .round();
            _amountController.text = _amountInput(
              ((totalCents - paidCents).clamp(0, totalCents)) / 100,
            );
          }
        });
      }
    } catch (e) {
      if (!mounted ||
          requestId != _receivablesRequestId ||
          tenantId != _selectedTenantId ||
          invoiceMode != _isInvoicePaymentMode) {
        return;
      }
      setState(() => _isLoadingReceivables = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            invoiceMode ? 'تعذر تحميل الفواتير: $e' : 'تعذر تحميل الأقساط: $e',
          ),
        ),
      );
    }
  }

  void _onTenantChanged(int? tenantId) {
    setState(() {
      _selectedTenantId = tenantId;
      _selectedInvoiceId = null;
      _unpaidInstallments = [];
      _openTaxInvoices = [];
      _amountController.clear();
    });
    _loadTenantReceivables(tenantId);
  }

  void _onModeChanged(bool? invoiceMode) {
    if (invoiceMode == null) return;
    setState(() {
      _isInvoicePaymentMode = invoiceMode;
      _selectedInvoiceId = null;
      _unpaidInstallments = [];
      _openTaxInvoices = [];
      _amountController.clear();
    });
    _loadTenantReceivables(_selectedTenantId);
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

  Future<void> _processReceipt({required bool saveAsPdf}) async {
    if (_isProcessing) return;
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
    }

    final receiptTenantId = _selectedTenantId!;
    final cashAccountId = _selectedCashAccountId!;
    final receiptDate = _dateController.text;
    final invoiceId = invoice == null ? null : (invoice['id'] as num).toInt();
    final invoiceMode = _isInvoicePaymentMode;
    final dueInstallments = List<Map<String, dynamic>>.from(_unpaidInstallments)
      ..sort(
        (a, b) => a['due_date'].toString().compareTo(b['due_date'].toString()),
      );
    var remainingCents = amountCents;
    final updates = <Map<String, dynamic>>[];
    if (!invoiceMode) {
      for (final installment in dueInstallments) {
        if (remainingCents <= 0) break;
        final totalCents = ((installment['amount'] as num).toDouble() * 100)
            .round();
        final paidCents =
            (((installment['paid_amount'] as num?) ?? 0).toDouble() * 100)
                .round();
        final dueCents = totalCents - paidCents;
        if (dueCents <= 0) continue;
        final allocationCents = remainingCents < dueCents
            ? remainingCents
            : dueCents;
        final newPaidCents = paidCents + allocationCents;
        updates.add({
          'id': installment['id'],
          'paid_amount': newPaidCents / 100,
          'status': newPaidCents >= totalCents ? 'Paid' : 'Partially Paid',
        });
        remainingCents -= allocationCents;
      }
      if (remainingCents > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('المبلغ أكبر من إجمالي الأقساط المتبقية'),
          ),
        );
        return;
      }
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
        );
      } else {
        voucherId = await DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: receiptTenantId,
          amount: amountCents / 100,
          voucherDate: receiptDate,
          cashAccountId: cashAccountId,
          installmentsToUpdate: updates,
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
      final voucherDetails = invoiceMode
          ? await DatabaseHelper.instance.getVoucherDetails(voucherId)
          : null;
      if (invoiceMode && voucherDetails == null) {
        throw StateError('تعذر تحميل تخصيصات سند الفاتورة');
      }
      final installmentAllocations = voucherDetails?['installments'] is List
          ? (voucherDetails!['installments'] as List)
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];
      final invoiceAllocations = voucherDetails?['invoices'] is List
          ? (voucherDetails!['invoices'] as List)
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
        description: invoiceMode
            ? 'سداد فاتورة داخلية رقم $invoiceId'
            : 'تحصيل دفعة إيجار',
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
      setState(() => _isProcessing = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
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

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left Panel: Form
              Expanded(
                flex: 1,
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
                      if (_isInvoicePaymentMode) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          initialValue: _selectedInvoiceId,
                          items: _openTaxInvoices.map((invoice) {
                            final id = (invoice['id'] as num).toInt();
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                'فاتورة #$id | المتبقي: ${_displayAmount(invoice['remaining_amount'])}',
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing ? null : _onInvoiceChanged,
                          validator: (value) => value == null ? 'مطلوب' : null,
                          decoration: const InputDecoration(
                            labelText: 'الفاتورة المراد سدادها',
                            border: OutlineInputBorder(),
                          ),
                        ),
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
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  _isProcessing ||
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
                                itemCount: _openTaxInvoices.length,
                                itemBuilder: (context, index) {
                                  final invoice = _openTaxInvoices[index];
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
                                      title: Text('فاتورة رقم $id'),
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
                                itemCount: _unpaidInstallments.length,
                                itemBuilder: (context, index) {
                                  final installment =
                                      _unpaidInstallments[index];
                                  final total = (installment['amount'] as num)
                                      .toDouble();
                                  final paid =
                                      ((installment['paid_amount'] as num?) ??
                                              0)
                                          .toDouble();
                                  final remaining = total - paid;
                                  return Card(
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.warning,
                                        color: Colors.orange,
                                      ),
                                      title: Text(
                                        'تاريخ الاستحقاق: ${installment['due_date']}',
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
