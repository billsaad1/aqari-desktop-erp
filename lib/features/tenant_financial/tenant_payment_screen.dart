import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/internal_tax.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../providers/accounting_provider.dart';
import '../../providers/leasing_provider.dart';

class TenantPaymentScreen extends StatefulWidget {
  const TenantPaymentScreen({super.key});

  @override
  State<TenantPaymentScreen> createState() => _TenantPaymentScreenState();
}

class _TenantPaymentScreenState extends State<TenantPaymentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  int? _selectedTenantId;
  int? _selectedCashAccountId;
  int? _selectedCollectionAllocationId;
  int? _selectedCreditNoteId;
  List<Map<String, dynamic>> _refundSources = [];
  List<Map<String, dynamic>> _creditNotes = [];
  List<Map<String, dynamic>> _legacyPayments = [];
  bool _isLoadingSources = false;
  bool _isLoadingCreditNotes = false;
  bool _isProcessing = false;
  int _sourcesRequestId = 0;

  Map<String, dynamic>? get _selectedSource {
    for (final source in _refundSources) {
      final id = (source['collection_allocation_id'] as num?)?.toInt();
      if (id == _selectedCollectionAllocationId) return source;
    }
    return null;
  }

  Map<String, dynamic>? get _selectedCreditNote {
    for (final note in _creditNotes) {
      if ((note['id'] as num?)?.toInt() == _selectedCreditNoteId) return note;
    }
    return null;
  }

  int get _selectedRefundMaximumMinor {
    final sourceMinor = InternalTax.toMinorUnits(
      (_selectedSource?['remaining_amount'] as num?)?.toDouble() ?? 0,
    );
    final note = _selectedCreditNote;
    if (note == null) return sourceMinor;
    final noteMinor = (note['refundable_minor'] as num?)?.toInt() ?? 0;
    return sourceMinor < noteMinor ? sourceMinor : noteMinor;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      Provider.of<LeasingProvider>(context, listen: false).loadInitialData();
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  String _formatAmount(dynamic value) =>
      NumberFormat('#,##0.00').format(((value as num?) ?? 0).toDouble());

  String _inputAmount(dynamic value) =>
      ((value as num?) ?? 0).toDouble().toStringAsFixed(2);

  Future<void> _loadRefundSources(int? tenantId) async {
    final requestId = ++_sourcesRequestId;
    if (mounted) {
      setState(() {
        _selectedCollectionAllocationId = null;
        _selectedCreditNoteId = null;
        _refundSources = [];
        _creditNotes = [];
        _legacyPayments = [];
        _amountController.clear();
        _isLoadingSources = tenantId != null;
      });
    }
    if (tenantId == null) return;

    try {
      final results = await Future.wait([
        DatabaseHelper.instance.getRefundableCollectionAllocations(tenantId),
        DatabaseHelper.instance.getPendingLegacyTenantPayments(tenantId),
      ]);
      if (!mounted ||
          requestId != _sourcesRequestId ||
          tenantId != _selectedTenantId) {
        return;
      }
      final sources = results[0];
      final legacyPayments = results[1];
      setState(() {
        _refundSources = sources;
        _legacyPayments = legacyPayments;
        _isLoadingSources = false;
        if (_legacyPayments.isEmpty && _refundSources.isNotEmpty) {
          final first = _refundSources.first;
          _selectedCollectionAllocationId =
              (first['collection_allocation_id'] as num).toInt();
          _amountController.text = _inputAmount(first['remaining_amount']);
        }
      });
      await _loadCreditNotesForSource(_selectedSource);
    } catch (error) {
      if (!mounted || requestId != _sourcesRequestId) return;
      setState(() => _isLoadingSources = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل مصادر الاسترداد: $error')),
      );
    }
  }

  void _selectRefundSource(int? id) {
    setState(() {
      _selectedCollectionAllocationId = id;
      final source = _selectedSource;
      _amountController.text = source == null
          ? ''
          : _inputAmount(source['remaining_amount']);
    });
    _loadCreditNotesForSource(_selectedSource);
  }

  Future<void> _loadCreditNotesForSource(
    Map<String, dynamic>? source,
  ) async {
    final sourceAllocationId =
        (source?['collection_allocation_id'] as num?)?.toInt();
    final invoiceId = (source?['invoice_id'] as num?)?.toInt();
    if (sourceAllocationId == null || invoiceId == null) {
      if (mounted) {
        setState(() {
          _creditNotes = [];
          _selectedCreditNoteId = null;
          _isLoadingCreditNotes = false;
        });
      }
      return;
    }
    setState(() {
      _creditNotes = [];
      _selectedCreditNoteId = null;
      _isLoadingCreditNotes = true;
    });
    try {
      final notes = (await DatabaseHelper.instance.getCreditNotesForInvoice(
        invoiceId,
      )).where((note) {
        return ((note['refundable_minor'] as num?)?.toInt() ?? 0) > 0;
      }).toList();
      if (!mounted ||
          _selectedCollectionAllocationId != sourceAllocationId) {
        return;
      }
      setState(() {
        _creditNotes = notes;
        _selectedCreditNoteId = notes.length == 1
            ? (notes.first['id'] as num).toInt()
            : null;
        _isLoadingCreditNotes = false;
      });
    } catch (error) {
      if (!mounted ||
          _selectedCollectionAllocationId != sourceAllocationId) {
        return;
      }
      setState(() {
        _creditNotes = [];
        _selectedCreditNoteId = null;
        _isLoadingCreditNotes = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل الإشعارات الدائنة: $error')),
      );
    }
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

  Future<void> _processRefund({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    final source = _selectedSource;
    if (!_formKey.currentState!.validate() ||
        _selectedTenantId == null ||
        _selectedCashAccountId == null ||
        source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر المستأجر ومصدر القبض وحساب الصرف')),
      );
      return;
    }
    if (_legacyPayments.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('طابق سندات الصرف التاريخية أولًا قبل إنشاء رد جديد'),
        ),
      );
      return;
    }
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || !amount.isFinite || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغ استرداد صحيحًا أكبر من صفر')),
      );
      return;
    }
    final maximumMinor = _selectedRefundMaximumMinor;
    if (InternalTax.toMinorUnits(amount) > maximumMinor) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('مبلغ الاسترداد يتجاوز الجزء غير المسترد من المصدر أو الإشعار'),
        ),
      );
      return;
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
      voucherId = await DatabaseHelper.instance.insertTenantRefundVoucher(
        tenantId: _selectedTenantId!,
        amount: amount,
        voucherDate: _dateController.text,
        cashAccountId: _selectedCashAccountId!,
        collectionAllocationId: _selectedCollectionAllocationId!,
        description: _descController.text.trim(),
        creditNoteId: _selectedCreditNoteId,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر ترحيل الاسترداد: $error')));
      }
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم ترحيل سند الرد رقم $voucherId')));
    try {
      final tenantName = leasingProvider.tenants
          .firstWhere((tenant) => tenant['id'] == _selectedTenantId)['name']
          .toString();
      final cashAccountName = accountingProvider.accounts
          .firstWhere(
            (account) => account['id'] == _selectedCashAccountId,
          )['name']
          .toString();
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند رد مستأجر',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: tenantName,
        amount: amount,
        paymentMethod: null,
        accountName: cashAccountName,
        description: _descController.text.trim(),
      );
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: pdfBytes,
          fileName: 'سند_رد_مستأجر_$voucherId',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'tenant_financial',
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ الاسترداد رقم $voucherId، لكن تعذر تجهيز/طباعة المستند: $error',
            ),
          ),
        );
      }
    }

    await accountingProvider.loadAccounts();
    if (mounted) {
      _descController.clear();
      await _loadRefundSources(_selectedTenantId);
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _markLegacyPaymentUnrelated(Map<String, dynamic> legacy) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('تصنيف سند الصرف رقم ${legacy['voucher_id']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'اختر هذا فقط بعد التأكد من أن العملية ليست ردًا لمبلغ قبض مسجل. اكتب سبب التصنيف لإضافته إلى سجل التدقيق.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'سبب التصنيف',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final text = reasonController.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(dialogContext, text);
            },
            child: const Text('تأكيد التصنيف'),
          ),
        ],
      ),
    );
    reasonController.dispose();
    if (reason == null || !mounted) return;
    try {
      await DatabaseHelper.instance.resolveLegacyTenantPaymentAsUnrelated(
        voucherId: (legacy['voucher_id'] as num).toInt(),
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تسجيل التصنيف في سجل التدقيق')),
      );
      await _loadRefundSources(_selectedTenantId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تصنيف السند: $error')));
    }
  }

  Future<void> _matchLegacyPaymentAsRefund(Map<String, dynamic> legacy) async {
    final legacyAmount = (legacy['amount'] as num).toDouble();
    final requiredMinor = InternalTax.toMinorUnits(legacyAmount);
    final selectedIds = <int>{};
    final allocationControllers = <int, TextEditingController>{};
    final reasonController = TextEditingController();
    if (_refundSources.length == 1) {
      final source = _refundSources.single;
      final sourceRemaining = (source['remaining_amount'] as num).toDouble();
      if (InternalTax.toMinorUnits(sourceRemaining) >= requiredMinor) {
        final id = (source['collection_allocation_id'] as num).toInt();
        selectedIds.add(id);
        allocationControllers[id] = TextEditingController(
          text: legacyAmount.toStringAsFixed(2),
        );
      }
    }

    final matches = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final selectedSources = _refundSources.where((source) {
            final id = (source['collection_allocation_id'] as num).toInt();
            return selectedIds.contains(id);
          }).toList();
          final allocatedMinor = selectedSources.fold<int>(0, (sum, source) {
            final id = (source['collection_allocation_id'] as num).toInt();
            final parsed = double.tryParse(
              allocationControllers[id]?.text.trim() ?? '',
            );
            return sum +
                (parsed != null && parsed.isFinite && parsed > 0
                    ? InternalTax.toMinorUnits(parsed)
                    : 0);
          });
          return AlertDialog(
            title: Text('مطابقة سند الصرف رقم ${legacy['voucher_id']}'),
            content: SizedBox(
              width: 620,
              height: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'مبلغ السند التاريخي: ${_formatAmount(legacyAmount)}. '
                    'وزّعه كاملًا على مصادر قبض المستأجر؛ لن يُنشأ قيد أو سند جديد.',
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _refundSources.isEmpty
                        ? const Center(
                            child: Text('لا توجد مصادر قبض متاحة للمطابقة.'),
                          )
                        : ListView(
                            children: _refundSources.map((source) {
                              final id =
                                  (source['collection_allocation_id'] as num)
                                      .toInt();
                              final selected = selectedIds.contains(id);
                              final ref = source['invoice_id'] != null
                                  ? 'فاتورة ${source['invoice_id']}'
                                  : 'قسط ${source['installment_id']}';
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  CheckboxListTile(
                                    value: selected,
                                    onChanged: (value) {
                                      setDialogState(() {
                                        if (value == true) {
                                          selectedIds.add(id);
                                          allocationControllers.putIfAbsent(
                                            id,
                                            TextEditingController.new,
                                          );
                                        } else {
                                          selectedIds.remove(id);
                                        }
                                      });
                                    },
                                    title: Text(
                                      'سند قبض ${source['receipt_voucher_id']} — $ref',
                                    ),
                                    subtitle: Text(
                                      'التاريخ ${source['receipt_date']} | المتبقي ${_formatAmount(source['remaining_amount'])}',
                                    ),
                                  ),
                                  if (selected)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        12,
                                      ),
                                      child: TextField(
                                        controller: allocationControllers[id],
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        decoration: const InputDecoration(
                                          labelText:
                                              'المبلغ المطابق لهذا المصدر',
                                          border: OutlineInputBorder(),
                                        ),
                                        onChanged: (_) => setDialogState(() {}),
                                      ),
                                    ),
                                ],
                              );
                            }).toList(),
                          ),
                  ),
                  TextField(
                    controller: reasonController,
                    decoration: const InputDecoration(
                      labelText: 'سبب المطابقة',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'المطابق ${_formatAmount(allocatedMinor / 100.0)} من ${_formatAmount(legacyAmount)}',
                    style: TextStyle(
                      color: allocatedMinor == requiredMinor
                          ? Colors.green.shade700
                          : Colors.deepOrange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed:
                    allocatedMinor == requiredMinor &&
                        reasonController.text.trim().isNotEmpty
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: const Text('مطابقة وترحيل التصحيح'),
              ),
            ],
          );
        },
      ),
    );
    if (matches != true || !mounted) {
      for (final controller in allocationControllers.values) {
        controller.dispose();
      }
      reasonController.dispose();
      return;
    }

    final allocations = <Map<String, int>>[];
    for (final id in selectedIds) {
      final amount = double.tryParse(
        allocationControllers[id]?.text.trim() ?? '',
      );
      if (amount == null || !amount.isFinite || amount <= 0) continue;
      allocations.add({
        'collection_allocation_id': id,
        'amount_minor': InternalTax.toMinorUnits(amount),
      });
    }
    final reason = reasonController.text.trim();
    for (final controller in allocationControllers.values) {
      controller.dispose();
    }
    reasonController.dispose();
    try {
      await DatabaseHelper.instance.resolveLegacyTenantPaymentAsRefund(
        voucherId: (legacy['voucher_id'] as num).toInt(),
        allocations: allocations,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تمت مطابقة الرد التاريخي وإضافة قيد إعادة التصنيف عند الحاجة',
          ),
        ),
      );
      await _loadRefundSources(_selectedTenantId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذرت مطابقة سند الصرف: $error')));
    }
  }

  Widget _legacyPaymentCard(Map<String, dynamic> legacy) {
    final amount = (legacy['amount'] as num).toDouble();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.history, color: Colors.deepOrange),
        title: Text(
          'سند صرف قديم رقم ${legacy['voucher_id']} — ${_formatAmount(amount)}',
        ),
        subtitle: Text(
          'التاريخ: ${legacy['voucher_date'] ?? '—'}'
          ' • الحساب المقابل: ${legacy['offset_account_name'] ?? '—'}'
          ' • ${legacy['description'] ?? ''}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed:
                  _isProcessing ||
                      !PermissionRuntime.allows(
                        'tenant_financial',
                        AppPermissionAction.post,
                      )
                  ? null
                  : () => _matchLegacyPaymentAsRefund(legacy),
              child: const Text('مطابقة كردّ'),
            ),
            TextButton(
              onPressed:
                  _isProcessing ||
                      !PermissionRuntime.allows(
                        'tenant_financial',
                        AppPermissionAction.post,
                      )
                  ? null
                  : () => _markLegacyPaymentUnrelated(legacy),
              child: const Text('صرف غير مرتبط'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProvider, accountingProvider, child) {
        if (leasingProvider.isLoading || accountingProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final cashAccounts = accountingProvider.detailAccounts
            .where(
              (account) =>
                  account['account_type'] == 'Asset' &&
                  account['code'].toString().startsWith('11') &&
                  account['parent_id'] != null,
            )
            .toList();
        final selectedSource = _selectedSource;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'استرداد مستأجر مرتبط بمصدر قبض',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepOrange,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'الإشعار الدائن يخفض الذمم ولا يرد النقد تلقائيًا. عند رد مبلغ ناتج عن إشعار، اربط الرد بالإشعار وبسند القبض الأصلي؛ أما الصرف غير المرتبط بمقبوض فيسجل كسند صرف عام.',
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<int>(
                        value: _selectedTenantId,
                        items: leasingProvider.tenants
                            .map(
                              (tenant) => DropdownMenuItem<int>(
                                value: (tenant['id'] as num).toInt(),
                                child: Text(tenant['name'].toString()),
                              ),
                            )
                            .toList(),
                        onChanged: _isProcessing
                            ? null
                            : (value) {
                                setState(() => _selectedTenantId = value);
                                _loadRefundSources(value);
                              },
                        decoration: const InputDecoration(
                          labelText: 'المستأجر',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value == null ? 'مطلوب' : null,
                      ),
                      const SizedBox(height: 16),
                      if (_isLoadingSources)
                        const LinearProgressIndicator()
                      else if (_legacyPayments.isNotEmpty) ...[
                        Card(
                          color: Colors.amber.shade50,
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text(
                              'توجد سندات صرف قديمة غير مرتبطة بمصدر. لحماية الدفاتر، أُوقف إصدار قبض/فاتورة/استرداد لهذا المستأجر حتى تُراجع هذه السندات وتُصنّف يدويًا.',
                            ),
                          ),
                        ),
                        ..._legacyPayments.map(_legacyPaymentCard),
                      ] else ...[
                        DropdownButtonFormField<int>(
                          value: _selectedCollectionAllocationId,
                          items: _refundSources.map((source) {
                            final id =
                                (source['collection_allocation_id'] as num)
                                    .toInt();
                            final reference = source['invoice_id'] != null
                                ? 'فاتورة ${source['invoice_id']}'
                                : 'قسط ${source['installment_id']}';
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                'قبض #${source['receipt_voucher_id']} — $reference — '
                                'متبقي ${_formatAmount(source['remaining_amount'])}',
                              ),
                            );
                          }).toList(),
                          onChanged: _isProcessing || _refundSources.isEmpty
                              ? null
                              : _selectRefundSource,
                          decoration: const InputDecoration(
                            labelText: 'مصدر القبض الأصلي',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) => value == null
                              ? 'اختر سند قبض أصليًا قابلًا للاسترداد'
                              : null,
                        ),
                        if (_refundSources.isEmpty) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'لا توجد مصادر قبض غير مستردة لهذا المستأجر. لأي صرف غير مرتبط، استخدم شاشة سند الصرف العام.',
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                        if (selectedSource != null) ...[
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Wrap(
                                spacing: 20,
                                runSpacing: 8,
                                children: [
                                  Text(
                                    'المقبوض الأصلي: ${_formatAmount(selectedSource['collected_amount'])}',
                                  ),
                                  Text(
                                    'المسترد سابقًا: ${_formatAmount(selectedSource['refunded_amount'])}',
                                  ),
                                  Text(
                                    'المتاح الآن: ${_formatAmount(selectedSource['remaining_amount'])}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (selectedSource['invoice_id'] != null)
                                    Text(
                                      'الفاتورة: ${selectedSource['invoice_id']}',
                                    ),
                                  Text(
                                    'القسط: ${selectedSource['installment_id']}',
                                  ),
                                  Text(
                                    'تاريخ القبض: ${selectedSource['receipt_date']}',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        if (selectedSource?['invoice_id'] != null &&
                            _isLoadingCreditNotes)
                          const LinearProgressIndicator(),
                        if (selectedSource?['invoice_id'] != null &&
                            !_isLoadingCreditNotes &&
                            _creditNotes.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<int?>(
                            value: _selectedCreditNoteId,
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('صرف عام غير مرتبط بإشعار دائن'),
                              ),
                              ..._creditNotes.map((note) {
                              final id = (note['id'] as num).toInt();
                              return DropdownMenuItem<int?>(
                                value: id,
                                child: Text(
                                  'إشعار دائن #$id — المتبقي ${_formatAmount((note['refundable_minor'] as num).toInt() / 100.0)}',
                                ),
                              );
                            }),
                            ],
                            onChanged: _isProcessing
                                ? null
                                : (value) => setState(() {
                                    _selectedCreditNoteId = value;
                                  }),
                            decoration: const InputDecoration(
                              labelText: 'الإشعار الدائن المرتبط برد النقد',
                              helperText:
                                  'اختر الإشعار عند ارتباط الرد به؛ الصرف العام يظل غير مرتبط بالإشعار. كل رد محدود بمصدر القبض الأصلي.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      DropdownButtonFormField<int>(
                        value: _selectedCashAccountId,
                        items: cashAccounts
                            .map(
                              (account) => DropdownMenuItem<int>(
                                value: (account['id'] as num).toInt(),
                                child: Text(
                                  '${account['code']} - ${account['name']}',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: _isProcessing
                            ? null
                            : (value) => setState(
                                () => _selectedCashAccountId = value,
                              ),
                        decoration: const InputDecoration(
                          labelText: 'يُصرف من حساب (الصندوق/البنك)',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value == null ? 'مطلوب' : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _dateController,
                              decoration: const InputDecoration(
                                labelText: 'تاريخ سند الاسترداد',
                                border: OutlineInputBorder(),
                              ),
                              readOnly: true,
                              onTap: _pickDate,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: _amountController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'المبلغ المرتد',
                                helperText: selectedSource == null
                                    ? null
                                    : 'الحد الأقصى ${_formatAmount(_selectedRefundMaximumMinor / 100.0)}',
                                border: const OutlineInputBorder(),
                              ),
                              validator: (value) {
                                final amount = double.tryParse(
                                  value?.trim() ?? '',
                                );
                                if (amount == null ||
                                    !amount.isFinite ||
                                    amount <= 0) {
                                  return 'أدخل مبلغًا صحيحًا أكبر من صفر';
                                }
                                if (selectedSource != null &&
                                    InternalTax.toMinorUnits(amount) >
                                        _selectedRefundMaximumMinor) {
                                  return 'يتجاوز المتاح من هذا المصدر أو الإشعار';
                                }
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'سبب/بيان الاسترداد',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'مطلوب لتوثيق سبب الاسترداد'
                            : null,
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
                                  : () => _processRefund(saveAsPdf: false),
                              icon: const Icon(Icons.assignment_return),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.deepOrange,
                                padding: const EdgeInsets.all(16),
                              ),
                              label: const Text('ترحيل ومعاينة سند الرد'),
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
                                    : () => _processRefund(saveAsPdf: true),
                                icon: const Icon(Icons.picture_as_pdf),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.all(16),
                                ),
                                label: const Text('ترحيل وحفظ PDF'),
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
          ),
        );
      },
    );
  }
}
