import 'package:flutter/material.dart';
import '../../core/erp_data_table.dart';
import 'package:intl/intl.dart';

import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';
import '../../models/tenant_receipt_payment_method.dart';

class VoucherHistoryScreen extends StatefulWidget {
  const VoucherHistoryScreen({super.key});

  @override
  State<VoucherHistoryScreen> createState() => _VoucherHistoryScreenState();
}

class _VoucherHistoryScreenState extends State<VoucherHistoryScreen> {
  static const _types = [
    'الكل',
    'قبض عام',
    'صرف عام',
    'قبض مستأجر',
    'عكس قبض مستأجر',
    'صرف مستأجر',
    'صرف مستحقات مالك',
  ];

  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _vouchers = [];
  String _selectedType = 'الكل';
  String _currency = 'ريال يمني';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVouchers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadVouchers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await DatabaseHelper.instance.getVoucherHistory(
        voucherType: _selectedType == 'الكل' ? null : _selectedType,
      );
      if (!mounted) return;
      setState(() {
        _vouchers = results;
        _isLoading = false;
      });
      try {
        final company = await DatabaseHelper.instance.getCompanyInfo();
        if (!mounted) return;
        setState(
          () => _currency = PrintUtils.currencyInArabic(
            company?['default_currency'],
          ),
        );
      } catch (_) {
        // Keep the default display currency; the voucher records are loaded.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر تحميل سجل السندات: $e';
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredVouchers {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _vouchers;
    return _vouchers.where((voucher) {
      final searchable = [
        voucher['id'],
        voucher['voucher_type'],
        voucher['voucher_date'],
        voucher['party_name'],
        voucher['description'],
        voucher['amount'],
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Future<void> _openDetails(Map<String, dynamic> voucher) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _VoucherDetailsDialog(voucherId: (voucher['id'] as num).toInt()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vouchers = _filteredVouchers;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long, size: 30),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'سجل السندات',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'تحديث السجل',
                onPressed: _isLoading ? null : _loadVouchers,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'بحث برقم السند أو الطرف أو البيان أو التاريخ',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedType,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'نوع السند',
                    border: OutlineInputBorder(),
                  ),
                  items: _types
                      .map(
                        (type) => DropdownMenuItem(
                          value: type,
                          child: Text(
                            type == 'صرف مستحقات مالك' ? 'سداد المالك' : type,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (type) {
                    if (type == null) return;
                    setState(() => _selectedType = type);
                    _loadVouchers();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isLoading
                ? 'جارٍ تحميل السندات...'
                : 'عدد السندات المعروضة: ${vouchers.length}',
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _loadVouchers,
                          icon: const Icon(Icons.refresh),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  )
                : vouchers.isEmpty
                ? const Center(
                    child: Text(
                      'لا توجد سندات محفوظة مطابقة للبحث.',
                      style: TextStyle(fontSize: 16, color: Colors.black54),
                    ),
                  )
                : ListView.separated(
                    itemCount: vouchers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final voucher = vouchers[index];
                      final isCorrectionReversal =
                          voucher['voucher_type'] == 'عكس قبض مستأجر';
                      final isReceipt =
                          !isCorrectionReversal &&
                          (voucher['voucher_type'] as String).contains('قبض');
                      final amount = (voucher['amount'] as num).toDouble();
                      final party = (voucher['party_name'] as String?)?.trim();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isCorrectionReversal
                                ? Colors.amber.shade100
                                : isReceipt
                                ? Colors.green.shade100
                                : Colors.red.shade100,
                            child: Icon(
                              isCorrectionReversal
                                  ? Icons.sync_alt
                                  : isReceipt
                                  ? Icons.call_received
                                  : Icons.call_made,
                              color: isCorrectionReversal
                                  ? Colors.deepOrange
                                  : isReceipt
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                          title: Text(
                            'سند ${voucher['voucher_type']} رقم ${voucher['id']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            '${voucher['voucher_date']}  •  ${party?.isNotEmpty == true ? party : (voucher['description'] ?? '—')}  •  ${NumberFormat('#,##0.00').format(amount)} $_currency',
                          ),
                          trailing: IconButton(
                            tooltip: 'عرض التفاصيل',
                            onPressed: () => _openDetails(voucher),
                            icon: const Icon(Icons.visibility_outlined),
                          ),
                          onTap: () => _openDetails(voucher),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _VoucherDetailsDialog extends StatefulWidget {
  final int voucherId;

  const _VoucherDetailsDialog({required this.voucherId});

  @override
  State<_VoucherDetailsDialog> createState() => _VoucherDetailsDialogState();
}

class _VoucherDetailsDialogState extends State<_VoucherDetailsDialog> {
  Map<String, dynamic>? _data;
  String _currency = 'ريال يمني';
  bool _isLoading = true;
  bool _isWorking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final data = await DatabaseHelper.instance.getVoucherDetails(
        widget.voucherId,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = data == null
            ? 'لم يعد هذا السند موجودًا في قاعدة البيانات.'
            : null;
        _isLoading = false;
      });
      try {
        final company = await DatabaseHelper.instance.getCompanyInfo();
        if (!mounted) return;
        setState(
          () => _currency = PrintUtils.currencyInArabic(
            company?['default_currency'],
          ),
        );
      } catch (_) {
        // Keep the default display currency if settings cannot be read.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر قراءة تفاصيل السند: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _export({required bool saveAsPdf}) async {
    if (_isWorking || _data == null) return;
    setState(() => _isWorking = true);
    try {
      final voucher = Map<String, dynamic>.from(_data!['voucher'] as Map);
      final lines = List<Map<String, dynamic>>.from(
        (_data!['journal_lines'] as List).map(
          (line) => Map<String, dynamic>.from(line as Map),
        ),
      );
      final installments = List<Map<String, dynamic>>.from(
        (_data!['installments'] as List).map(
          (line) => Map<String, dynamic>.from(line as Map),
        ),
      );
      final invoices = List<Map<String, dynamic>>.from(
        (_data!['invoices'] as List).map(
          (invoice) => Map<String, dynamic>.from(invoice as Map),
        ),
      );
      final refunds = List<Map<String, dynamic>>.from(
        (_data!['refunds'] as List).map(
          (refund) => Map<String, dynamic>.from(refund as Map),
        ),
      );
      final voucherType = voucher['voucher_type']?.toString() ?? '';
      final isGeneralVoucher = voucherType.contains('عام');
      final partyName = voucher['party_name']?.toString().trim() ?? '';
      final currentTenantName =
          voucher['current_tenant_name']?.toString().trim() ?? '';
      final isTenantReceipt = voucherType == 'قبض مستأجر';
      final receiptTenantName = currentTenantName.isNotEmpty
          ? currentTenantName
          : partyName;
      final storedPaymentMethod = TenantReceiptPaymentMethod.displayLabel(
        method: voucher['payment_method'],
        reference: voucher['payment_reference'],
        bankName: voucher['payment_bank_name'],
      );
      final periodFrom = voucher['period_from_date']?.toString().trim();
      final periodTo = voucher['period_to_date']?.toString().trim();
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند $voucherType',
        voucherNo: widget.voucherId,
        date: voucher['voucher_date'].toString(),
        targetName: isTenantReceipt
            ? (receiptTenantName.isEmpty ? null : receiptTenantName)
            : isGeneralVoucher || partyName.isEmpty
            ? null
            : partyName,
        amount: (voucher['amount'] as num).toDouble(),
        paymentMethod: isTenantReceipt ? storedPaymentMethod : null,
        accountName: '',
        description: voucher['description']?.toString(),
        periodStartDate: periodFrom,
        periodEndDate: periodTo,
        journalLines: lines,
        installmentAllocations: installments,
        invoiceAllocations: invoices,
        refundAllocations: refunds,
      );
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: pdfBytes,
          fileName: 'سند_${voucher['voucher_type']}_${widget.voucherId}',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'voucher_history',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تجهيز السند للطباعة: $e')));
      }
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _correctReceiptDescription(String currentDescription) async {
    if (_isWorking) return;
    final descriptionController = TextEditingController(
      text: currentDescription,
    );
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تصحيح بيان سند القبض'),
        content: SizedBox(
          width: 480,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: descriptionController,
                  autofocus: true,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'البيان المصحح',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'أدخل البيان المصحح';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: reasonController,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'سبب التصحيح (مطلوب للتدقيق)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'اذكر سبب التصحيح';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'لن يتغير المبلغ أو القيد المالي. سيُحفظ البيان السابق والجديد وسبب التعديل في سجل التدقيق.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(true);
              }
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('حفظ التصحيح'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      descriptionController.dispose();
      reasonController.dispose();
      return;
    }

    setState(() => _isWorking = true);
    try {
      await DatabaseHelper.instance.correctTenantReceiptVoucherDescription(
        voucherId: widget.voucherId,
        newDescription: descriptionController.text,
        reason: reasonController.text,
      );
      await _loadDetails();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تصحيح البيان مع حفظ أثر التعديل في سجل التدقيق.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تصحيح البيان: $error')));
      }
    } finally {
      descriptionController.dispose();
      reasonController.dispose();
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _correctReceiptAmount(Map<String, dynamic> voucher) async {
    if (_isWorking) return;
    List<Map<String, dynamic>> candidates;
    setState(() => _isWorking = true);
    try {
      candidates = await DatabaseHelper.instance
          .getTenantReceiptCorrectionInstallments(widget.voucherId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('لا يمكن تصحيح هذا السند: $error')),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
    if (!mounted || candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد قسط متاح للتخصيص البديل.')),
        );
      }
      return;
    }

    final amountController = TextEditingController(
      text: ((voucher['amount'] as num).toDouble()).toStringAsFixed(2),
    );
    final descriptionController = TextEditingController(
      text: voucher['description']?.toString() ?? '',
    );
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final originalInstallments = _data?['installments'];
    final originalInstallmentId =
        originalInstallments is List &&
            originalInstallments.isNotEmpty &&
            originalInstallments.first is Map
        ? ((originalInstallments.first as Map)['installment_id'] as num?)
              ?.toInt()
        : null;
    var selectedInstallmentId =
        candidates.any(
          (row) =>
              (row['installment_id'] as num?)?.toInt() == originalInstallmentId,
        )
        ? originalInstallmentId
        : (candidates.first['installment_id'] as num).toInt();
    var confirmsActualAmount = false;
    final correctionDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تصحيح مبلغ أو تخصيص سند القبض'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'المبلغ الصحيح المقبوض فعليًا',
                        suffixText: _currency,
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final amount = double.tryParse(
                          value?.trim().replaceAll(',', '') ?? '',
                        );
                        if (amount == null || amount <= 0) {
                          return 'أدخل مبلغًا صحيحًا أكبر من صفر';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: selectedInstallmentId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'القسط / العقار / الوحدة الصحيح',
                        border: OutlineInputBorder(),
                      ),
                      items: candidates.map((row) {
                        final id = (row['installment_id'] as num).toInt();
                        final remaining =
                            (row['remaining_after_reversal'] as num?)
                                ?.toDouble() ??
                            0;
                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(
                            'العقار ${row['property_name']} — الوحدة ${row['unit_number']} — العقد ${row['contract_id']} — القسط $id (${row['due_date']}) — المتاح ${NumberFormat('#,##0.00').format(remaining)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (value) =>
                          setDialogState(() => selectedInstallmentId = value),
                      validator: (value) =>
                          value == null ? 'اختر القسط الصحيح' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: descriptionController,
                      maxLength: 500,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'بيان سند القبض البديل',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'أدخل بيان السند البديل'
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: reasonController,
                      maxLength: 500,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'سبب التصحيح (مطلوب للتدقيق)',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'اذكر سبب التصحيح'
                          : null,
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text('تاريخ القيدين: $correctionDate'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: confirmsActualAmount,
                      onChanged: (value) => setDialogState(
                        () => confirmsActualAmount = value ?? false,
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        'أؤكد أن المبلغ المدخل هو المبلغ المستلم فعليًا، وأن هذا تصحيح محاسبي وليس ردًا نقديًا.',
                      ),
                    ),
                    const Text(
                      'سيُبقى السند الأصلي دون تغيير، ويُنشأ قيد عكس مرتبط وسند قبض بديل داخل معاملة واحدة. لا يُنشأ سند صرف ولا حركة رد نقدي. يدعم هذا المسار القبض القياسي على الأقساط فقط؛ لا يدعم الفواتير/الضريبة أو السندات ذات الاسترداد السابق.',
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () {
                if (!confirmsActualAmount) return;
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              icon: const Icon(Icons.rule_folder_outlined),
              label: const Text('تنفيذ التصحيح'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      amountController.dispose();
      descriptionController.dispose();
      reasonController.dispose();
      return;
    }

    setState(() => _isWorking = true);
    try {
      final correctedAmount = double.parse(
        amountController.text.trim().replaceAll(',', ''),
      );
      final replacementVoucherId = await DatabaseHelper.instance
          .correctTenantReceiptVoucher(
            sourceVoucherId: widget.voucherId,
            replacementInstallmentId: selectedInstallmentId!,
            correctedAmount: correctedAmount,
            correctionDate: correctionDate,
            description: descriptionController.text,
            reason: reasonController.text,
          );
      await _loadDetails();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم التصحيح محاسبيًا؛ السند البديل رقم $replacementVoucherId مرتبط بالأصل. لا يوجد سند صرف أو استرداد نقدي.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تعذر تنفيذ التصحيح؛ لم يُحفظ جزء منه: $error'),
          ),
        );
      }
    } finally {
      amountController.dispose();
      descriptionController.dispose();
      reasonController.dispose();
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Widget _detailTile(String label, String value) => Container(
    constraints: const BoxConstraints(minWidth: 190, maxWidth: 320),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );

  String _formatInvoiceAmount(dynamic value) {
    final amount = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return amount == null
        ? '—'
        : '${NumberFormat('#,##0.00').format(amount)} $_currency';
  }

  Future<void> _openRelatedVoucher(int voucherId) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VoucherDetailsDialog(voucherId: voucherId),
    );
  }

  Widget _correctionVoucherLink({
    required String label,
    required dynamic rawId,
    required bool isCurrent,
  }) {
    final id = rawId is num ? rawId.toInt() : null;
    if (id == null) return Text('$label: —');
    return OutlinedButton.icon(
      onPressed: isCurrent ? null : () => _openRelatedVoucher(id),
      icon: Icon(isCurrent ? Icons.check_circle_outline : Icons.open_in_new),
      label: Text('$label #$id${isCurrent ? ' (الحالي)' : ''}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final rawVoucher = _data?['voucher'];
    final voucher = rawVoucher is Map
        ? Map<String, dynamic>.from(rawVoucher)
        : null;
    final rawCorrections = _data?['receipt_corrections'];
    final hasReceiptCorrection =
        rawCorrections is List && rawCorrections.isNotEmpty;
    final canCorrectDescription =
        voucher?['voucher_type'] == 'قبض مستأجر' &&
        !hasReceiptCorrection &&
        PermissionRuntime.allows('tenant_financial', AppPermissionAction.edit);
    final canCorrectAmount =
        canCorrectDescription &&
        PermissionRuntime.allows('tenant_financial', AppPermissionAction.post);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: screenSize.width < 1060 ? screenSize.width * 0.92 : 980,
        height: screenSize.height < 800 ? screenSize.height * 0.84 : 680,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تفاصيل السند رقم ${widget.voucherId}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text(_error!))
                  : _buildDetails(),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canCorrectAmount)
                    OutlinedButton.icon(
                      onPressed: _isWorking
                          ? null
                          : () => _correctReceiptAmount(voucher!),
                      icon: const Icon(Icons.currency_exchange),
                      label: const Text('تصحيح المبلغ / القسط'),
                    ),
                  if (canCorrectDescription)
                    OutlinedButton.icon(
                      onPressed: _isWorking
                          ? null
                          : () => _correctReceiptDescription(
                              voucher?['description']?.toString() ?? '',
                            ),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('تعديل البيان'),
                    ),
                  OutlinedButton.icon(
                    onPressed:
                        _isWorking ||
                            !PermissionRuntime.allows(
                              'voucher_history',
                              AppPermissionAction.print,
                            )
                        ? null
                        : () => _export(saveAsPdf: false),
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        _isWorking ||
                            !PermissionRuntime.allows(
                              'voucher_history',
                              AppPermissionAction.print,
                            )
                        ? null
                        : () => _export(saveAsPdf: true),
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails() {
    final voucher = Map<String, dynamic>.from(_data!['voucher'] as Map);
    final lines = List<Map<String, dynamic>>.from(
      (_data!['journal_lines'] as List).map(
        (line) => Map<String, dynamic>.from(line as Map),
      ),
    );
    final installments = List<Map<String, dynamic>>.from(
      (_data!['installments'] as List).map(
        (line) => Map<String, dynamic>.from(line as Map),
      ),
    );
    final rawInvoices = _data!['invoices'];
    final invoices = rawInvoices is List
        ? rawInvoices
              .whereType<Map>()
              .map((invoice) => Map<String, dynamic>.from(invoice))
              .toList()
        : <Map<String, dynamic>>[];
    final rawRefunds = _data!['refunds'];
    final refunds = rawRefunds is List
        ? rawRefunds
              .whereType<Map>()
              .map((refund) => Map<String, dynamic>.from(refund))
              .toList()
        : <Map<String, dynamic>>[];
    final rawReceiptCorrections = _data!['receipt_corrections'];
    final receiptCorrections = rawReceiptCorrections is List
        ? rawReceiptCorrections
              .whereType<Map>()
              .map((correction) => Map<String, dynamic>.from(correction))
              .toList()
        : <Map<String, dynamic>>[];
    final rawOwnerSettlement = _data!['owner_settlement'];
    final ownerSettlement = rawOwnerSettlement is Map
        ? Map<String, dynamic>.from(rawOwnerSettlement)
        : null;
    final invoicedInstallmentIds = invoices
        .map((invoice) => invoice['installment_id'])
        .whereType<num>()
        .map((id) => id.toInt())
        .toSet();
    final standaloneInstallments = installments.where((installment) {
      final id = installment['installment_id'];
      return id is! num || !invoicedInstallmentIds.contains(id.toInt());
    }).toList();
    final isReceipt = voucher['voucher_type'] == 'قبض مستأجر';
    final amount = (voucher['amount'] as num).toDouble();
    final receiptPaymentLabel = TenantReceiptPaymentMethod.displayLabel(
      method: voucher['payment_method'],
      reference: voucher['payment_reference'],
      bankName: voucher['payment_bank_name'],
    );
    final paymentReference = voucher['payment_reference']?.toString().trim();
    final paymentBankName = voucher['payment_bank_name']?.toString().trim();
    final detailTiles = <Widget>[
      _detailTile('نوع السند', 'سند ${voucher['voucher_type']}'),
      _detailTile('التاريخ', voucher['voucher_date'].toString()),
      _detailTile('الطرف / المستأجر', voucher['party_name']?.toString() ?? '—'),
      _detailTile(
        'المبلغ',
        '${NumberFormat('#,##0.00').format(amount)} $_currency',
      ),
      if (isReceipt)
        _detailTile('طريقة القبض', receiptPaymentLabel ?? 'غير مسجلة في هذا السند'),
      if (isReceipt && (paymentReference?.isNotEmpty ?? false))
        _detailTile('رقم الشيك / مرجع الحوالة', paymentReference!),
      if (isReceipt && (paymentBankName?.isNotEmpty ?? false))
        _detailTile('البنك', paymentBankName!),
      _detailTile(
        'رقم القيد المحاسبي',
        voucher['journal_entry_id']?.toString() ?? '—',
      ),
      _detailTile('البيان', voucher['description']?.toString() ?? '—'),
      if (ownerSettlement != null) ...[
        _detailTile(
          'رقم سجل سداد المالك',
          ownerSettlement['settlement_id']?.toString() ?? '—',
        ),
        _detailTile(
          'حساب التزامات المالك',
          '${ownerSettlement['owner_account_code'] ?? '—'} — ${ownerSettlement['owner_account_name'] ?? '—'}',
        ),
        _detailTile(
          'حساب الصندوق / البنك',
          '${ownerSettlement['cash_account_code'] ?? '—'} — ${ownerSettlement['cash_account_name'] ?? '—'}',
        ),
      ],
      if ((voucher['period_from_date']?.toString().trim().isNotEmpty ??
              false) ||
          (voucher['period_to_date']?.toString().trim().isNotEmpty ?? false))
        _detailTile(
          'الفترة',
          'من ${voucher['period_from_date']?.toString() ?? '—'} إلى ${voucher['period_to_date']?.toString() ?? '—'}',
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: 10, runSpacing: 10, children: detailTiles),
          if (receiptCorrections.isNotEmpty) ...[
            const SizedBox(height: 18),
            Card(
              color: Colors.amber.shade50,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'مجموعة تصحيح محاسبي — ليست استردادًا نقديًا',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text('السبب: ${receiptCorrections.first['reason'] ?? '—'}'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _correctionVoucherLink(
                          label: 'السند الأصلي',
                          rawId: receiptCorrections.first['source_voucher_id'],
                          isCurrent:
                              voucher['id'] ==
                              receiptCorrections.first['source_voucher_id'],
                        ),
                        _correctionVoucherLink(
                          label: 'عكس التصحيح',
                          rawId:
                              receiptCorrections.first['reversal_voucher_id'],
                          isCurrent:
                              voucher['id'] ==
                              receiptCorrections.first['reversal_voucher_id'],
                        ),
                        _correctionVoucherLink(
                          label: 'السند البديل',
                          rawId: receiptCorrections
                              .first['replacement_voucher_id'],
                          isCurrent:
                              voucher['id'] ==
                              receiptCorrections
                                  .first['replacement_voucher_id'],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 22),
          const Text(
            'الحسابات والحركة المحاسبية',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            const Text('لا توجد أسطر قيد مرتبطة بهذا السند.')
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ErpDataTable(
                columns: const [
                  DataColumn(label: Text('رمز الحساب')),
                  DataColumn(label: Text('الحساب')),
                  DataColumn(label: Text('مدين')),
                  DataColumn(label: Text('دائن')),
                  DataColumn(label: Text('مركز التكلفة')),
                ],
                rows: lines.map((line) {
                  final debit = (line['debit'] as num? ?? 0).toDouble();
                  final credit = (line['credit'] as num? ?? 0).toDouble();
                  return DataRow(
                    cells: [
                      DataCell(Text(line['account_code']?.toString() ?? '—')),
                      DataCell(Text(line['account_name']?.toString() ?? '—')),
                      DataCell(Text(debit.toStringAsFixed(2))),
                      DataCell(Text(credit.toStringAsFixed(2))),
                      DataCell(
                        Text(line['cost_center_name']?.toString() ?? '—'),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          if (standaloneInstallments.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'الأقساط التي سددها هذا السند',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...standaloneInstallments.map((installment) {
              final allocated = (installment['allocated_amount'] as num)
                  .toDouble();
              return Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.event_available,
                    color: Colors.green,
                  ),
                  title: Text(
                    'العقار ${installment['property_name']} — الوحدة ${installment['unit_number']} — تاريخ الاستحقاق ${installment['due_date']}',
                  ),
                  subtitle: Text(
                    'رقم العقد ${installment['contract_id']} | مبلغ القسط ${(installment['installment_amount'] as num).toDouble().toStringAsFixed(2)} | المسدد بعد السند ${(installment['paid_amount'] as num).toDouble().toStringAsFixed(2)} | الحالة: ${installment['status']}',
                  ),
                  trailing: Text(
                    NumberFormat('#,##0.00').format(allocated),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            }),
          ],
          if (isReceipt && invoices.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'الفواتير المرتبطة بهذا السند',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...invoices.map((invoice) {
              final invoiceDate = invoice['invoice_date']?.toString() ?? '—';
              final rawInstallmentId = invoice['installment_id'];
              final installmentId = rawInstallmentId is num
                  ? rawInstallmentId.toInt()
                  : null;
              final rentAllocated = installmentId == null
                  ? 0.0
                  : installments
                        .where(
                          (item) =>
                              (item['installment_id'] as num?)?.toInt() ==
                              installmentId,
                        )
                        .fold<double>(
                          0,
                          (sum, item) =>
                              sum +
                              ((item['allocated_amount'] as num?)?.toDouble() ??
                                  0),
                        );
              final invoiceAllocated =
                  (invoice['allocated_amount'] as num?)?.toDouble() ?? 0.0;
              final taxAllocated = (invoiceAllocated - rentAllocated)
                  .clamp(0.0, invoiceAllocated)
                  .toDouble();
              final invoiceDetails = [
                'التاريخ: $invoiceDate',
                'القسط: ${installmentId?.toString() ?? '—'}',
                if (invoice['due_date'] != null)
                  'الاستحقاق: ${invoice['due_date']}',
                'إجمالي الفاتورة: ${_formatInvoiceAmount(invoice['total_amount'])}',
                if (invoice['net_amount'] != null)
                  'الصافي: ${_formatInvoiceAmount(invoice['net_amount'])}',
                if (invoice['tax_amount'] != null)
                  'الضريبة: ${_formatInvoiceAmount(invoice['tax_amount'])}',
                'من هذا السند للإيجار: ${_formatInvoiceAmount(rentAllocated)}',
                'من هذا السند للضريبة: ${_formatInvoiceAmount(taxAllocated)}',
              ];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.receipt, color: Colors.blueGrey),
                  title: Text('الفاتورة رقم ${invoice['invoice_id'] ?? '—'}'),
                  subtitle: Text(invoiceDetails.join(' • ')),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('المبلغ المخصص'),
                      Text(
                        _formatInvoiceAmount(invoice['allocated_amount']),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
          if (voucher['voucher_type']?.toString().contains('صرف') == true &&
              refunds.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'مصدر الاسترداد',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...refunds.map((refund) {
              final invoice = refund['invoice_id'];
              final installment = refund['installment_id'];
              return Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.assignment_return,
                    color: Colors.deepOrange,
                  ),
                  title: Text(
                    'رد من سند القبض رقم ${refund['source_receipt_voucher_id'] ?? '—'}',
                  ),
                  subtitle: Text(
                    'تاريخ الأصل: ${refund['source_receipt_date'] ?? '—'}'
                    '${invoice == null ? '' : ' • الفاتورة: $invoice'}'
                    '${installment == null ? '' : ' • القسط: $installment'}'
                    ' • للإيجار: ${_formatInvoiceAmount(refund['rent_refund_amount'])}'
                    ' • للضريبة: ${_formatInvoiceAmount(refund['tax_refund_amount'])}',
                  ),
                  trailing: Text(
                    _formatInvoiceAmount(refund['allocated_amount']),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            }),
          ],
          if (voucher['voucher_type'] == 'قبض مستأجر' &&
              installments.isEmpty &&
              invoices.isEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'هذا السند محفوظ، لكن تفاصيل توزيعه على الأقساط لم تكن تُسجل في الإصدارات السابقة من النظام.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}
