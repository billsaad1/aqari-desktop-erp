import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import 'package:intl/intl.dart';
import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';

class GeneralVoucherScreen extends StatefulWidget {
  final String voucherType; // 'قبض عام' or 'صرف عام'
  const GeneralVoucherScreen({super.key, required this.voucherType});

  @override
  State<GeneralVoucherScreen> createState() => _GeneralVoucherScreenState();
}

class _GeneralVoucherScreenState extends State<GeneralVoucherScreen> {
  final _formKey = GlobalKey<FormState>();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  final _periodFromController = TextEditingController();
  final _periodToController = TextEditingController();

  int? _cashAccountId;
  final List<_GeneralVoucherLine> _lines = [_GeneralVoucherLine()];
  bool _isProcessing = false;

  double get _totalAmount => _lines.fold<double>(
    0,
    (sum, line) => sum + (double.tryParse(line.amountController.text) ?? 0),
  );

  void _syncAmount() =>
      _amountController.text = _totalAmount.toStringAsFixed(2);

  void _addLine() => setState(() => _lines.add(_GeneralVoucherLine()));

  void _removeLine(int index) {
    if (_lines.length <= 1) return;
    setState(() {
      final line = _lines.removeAt(index);
      line.dispose();
      _syncAmount();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      Provider.of<AccountingProvider>(context, listen: false).loadCostCenters();
    });
  }

  @override
  void dispose() {
    _dateController.dispose();
    _amountController.dispose();
    _descController.dispose();
    _periodFromController.dispose();
    _periodToController.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
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

  Future<void> _pickPeriodDate(
    TextEditingController controller, {
    required bool isStart,
  }) async {
    final from = DateTime.tryParse(_periodFromController.text);
    final to = DateTime.tryParse(_periodToController.text);
    final firstDate = isStart ? DateTime(2000) : (from ?? DateTime(2000));
    final lastDate = isStart ? (to ?? DateTime(2100)) : DateTime(2100);
    var initialDate = DateTime.tryParse(controller.text) ?? DateTime.now();
    if (initialDate.isBefore(firstDate)) initialDate = firstDate;
    if (initialDate.isAfter(lastDate)) initialDate = lastDate;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (date != null && mounted) {
      setState(() => controller.text = DateFormat('yyyy-MM-dd').format(date));
    }
  }

  String? _validateVoucherPeriod() {
    final fromText = _periodFromController.text.trim();
    final toText = _periodToController.text.trim();
    if (fromText.isEmpty && toText.isEmpty) return null;
    if (fromText.isEmpty || toText.isEmpty) {
      return 'أدخل تاريخ البداية والنهاية معاً أو اتركهما فارغين';
    }
    final from = DateTime.tryParse(fromText);
    final to = DateTime.tryParse(toText);
    if (from == null || to == null) return 'تاريخ الفترة غير صحيح';
    if (from.isAfter(to)) return 'تاريخ البداية يجب ألا يتجاوز تاريخ النهاية';
    return null;
  }

  Future<void> _saveVoucher({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    if (!_formKey.currentState!.validate() || _cashAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر حساب الصندوق/البنك وأكمل البيانات')),
      );
      return;
    }
    if (_lines.isEmpty || _lines.any((line) => line.accountId == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر حسابًا لكل بند من بنود السند')),
      );
      return;
    }
    if (_lines.any((line) => line.descriptionController.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل بيانًا مستقلًا لكل بند')),
      );
      return;
    }
    final lineAmounts = <double>[];
    for (final line in _lines) {
      final value = double.tryParse(line.amountController.text);
      if (value == null ||
          !value.isFinite ||
          value <= 0 ||
          (value * 100 - (value * 100).round()).abs() > 0.000001) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('أدخل مبلغًا موجبًا بدقة منزلتين لكل بند'),
          ),
        );
        return;
      }
      lineAmounts.add(value);
    }
    final amount = _totalAmount;
    if (!amount.isFinite ||
        amount <= 0 ||
        DateTime.tryParse(_dateController.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من مجموع المبالغ والتاريخ')),
      );
      return;
    }

    final accountingProvider = Provider.of<AccountingProvider>(
      context,
      listen: false,
    );
    final voucher = {
      'voucher_type': widget.voucherType,
      'voucher_date': _dateController.text,
      'amount': amount,
      'party_name': _descController.text.trim(),
      'description': _descController.text.trim(),
      'period_from_date': _periodFromController.text.trim().isEmpty
          ? null
          : _periodFromController.text.trim(),
      'period_to_date': _periodToController.text.trim().isEmpty
          ? null
          : _periodToController.text.trim(),
    };
    final counterpartLines = [
      for (var index = 0; index < _lines.length; index++)
        {
          'account_id': _lines[index].accountId,
          'amount': lineAmounts[index],
          'cost_center_id': _lines[index].costCenterId,
          'description': _lines[index].descriptionController.text.trim(),
        },
    ];
    setState(() => _isProcessing = true);
    late final int voucherId;
    try {
      voucherId = await accountingProvider.saveGeneralVoucherWithLines(
        voucher,
        _cashAccountId!,
        counterpartLines,
        widget.voucherType,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('لم يتم حفظ السند: $e')));
        setState(() => _isProcessing = false);
      }
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم حفظ السند رقم $voucherId وترحيل القيد')),
    );
    try {
      final accounts = accountingProvider.accounts;
      final cashAccount = accounts.firstWhere((a) => a['id'] == _cashAccountId);
      final isReceipt = widget.voucherType == 'قبض عام';
      final journalLines = <Map<String, dynamic>>[
        {
          'account_name': '${cashAccount['code']} ${cashAccount['name']}',
          'description': _descController.text.trim(),
          'debit': isReceipt ? amount : 0.0,
          'credit': isReceipt ? 0.0 : amount,
        },
        for (var index = 0; index < _lines.length; index++)
          () {
            final line = _lines[index];
            final account = accounts.firstWhere(
              (a) => a['id'] == line.accountId,
            );
            return <String, dynamic>{
              'account_name': '${account['code']} ${account['name']}',
              'description': line.descriptionController.text.trim(),
              'debit': isReceipt ? 0.0 : lineAmounts[index],
              'credit': isReceipt ? lineAmounts[index] : 0.0,
            };
          }(),
      ];
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: isReceipt ? 'سند قبض عام' : 'سند صرف عام',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: null,
        amount: amount,
        paymentMethod: null,
        accountName: '${cashAccount['name']}',
        description: _descController.text.trim(),
        periodStartDate: _periodFromController.text.trim().isEmpty
            ? null
            : _periodFromController.text.trim(),
        periodEndDate: _periodToController.text.trim().isEmpty
            ? null
            : _periodToController.text.trim(),
        journalLines: journalLines,
      );
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: pdfBytes,
          fileName: '${widget.voucherType}_$voucherId',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'accounting',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ السند رقم $voucherId، لكن تعذر تجهيز/حفظ المستند: $e',
            ),
          ),
        );
      }
    }

    if (mounted) {
      for (final line in _lines) {
        line.dispose();
      }
      _formKey.currentState!.reset();
      setState(() {
        _cashAccountId = null;
        _amountController.clear();
        _descController.clear();
        _periodFromController.clear();
        _periodToController.clear();
        _lines
          ..clear()
          ..add(_GeneralVoucherLine());
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReceipt = widget.voucherType == 'قبض عام';
    final primaryColor = isReceipt ? Colors.green : Colors.red;

    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 800),
              child: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'سند ${widget.voucherType}',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: primaryColor,
                        ),
                      ),
                      if (!isReceipt) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'لسداد التزامات الملاك استخدم تبويب «سداد مستحقات المالك»؛ لا تسجلها كسند صرف عام.',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ],
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _dateController,
                              decoration: const InputDecoration(
                                labelText: 'التاريخ',
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
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'إجمالي المبلغ',
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) =>
                                  v!.trim().isEmpty ? 'مطلوب' : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _periodFromController,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'من تاريخ (اختياري)',
                                border: OutlineInputBorder(),
                                suffixIcon: Icon(Icons.calendar_today),
                              ),
                              onTap: () => _pickPeriodDate(
                                _periodFromController,
                                isStart: true,
                              ),
                              validator: (_) => _validateVoucherPeriod(),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: _periodToController,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'إلى تاريخ (اختياري)',
                                border: OutlineInputBorder(),
                                suffixIcon: Icon(Icons.calendar_today),
                              ),
                              onTap: () => _pickPeriodDate(
                                _periodToController,
                                isStart: false,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<int>(
                        value: _cashAccountId,
                        items: provider.detailAccounts
                            .where(
                              (account) =>
                                  account['account_type'] == 'Asset' &&
                                  account['code'].toString().startsWith('11') &&
                                  account['parent_id'] != null,
                            )
                            .map(
                              (account) => DropdownMenuItem<int>(
                                value: (account['id'] as num).toInt(),
                                child: Text(
                                  '${account['code']} - ${account['name']}',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => _cashAccountId = value),
                        decoration: InputDecoration(
                          labelText: isReceipt
                              ? 'يُقبض إلى حساب (الصندوق/البنك)'
                              : 'يُصرف من حساب (الصندوق/البنك)',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'بنود السند',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 17,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _isProcessing ? null : _addLine,
                            icon: const Icon(Icons.add),
                            label: const Text('إضافة بند'),
                          ),
                        ],
                      ),
                      ..._lines.asMap().entries.map((entry) {
                        final index = entry.key;
                        final line = entry.value;
                        final allowedTypes = isReceipt
                            ? ['Asset', 'Liability', 'Equity', 'Revenue']
                            : ['Asset', 'Liability', 'Equity', 'Expense'];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 4,
                                      child: DropdownButtonFormField<int>(
                                        value: line.accountId,
                                        items: provider.detailAccounts
                                            .where(
                                              (account) =>
                                                  allowedTypes.contains(
                                                    account['account_type'],
                                                  ),
                                            )
                                            .map(
                                              (
                                                account,
                                              ) => DropdownMenuItem<int>(
                                                value: (account['id'] as num)
                                                    .toInt(),
                                                child: Text(
                                                  '${account['code']} - ${account['name']}',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (value) => setState(
                                          () => line.accountId = value,
                                        ),
                                        decoration: InputDecoration(
                                          labelText: isReceipt
                                              ? 'الحساب المقابل الدائن'
                                              : 'الحساب المقابل المدين',
                                          border: const OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 2,
                                      child: TextFormField(
                                        controller: line.amountController,
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        onChanged: (_) => setState(_syncAmount),
                                        decoration: const InputDecoration(
                                          labelText: 'مبلغ البند',
                                          border: OutlineInputBorder(),
                                        ),
                                        validator: (value) {
                                          final parsed = double.tryParse(
                                            value ?? '',
                                          );
                                          return parsed == null ||
                                                  !parsed.isFinite ||
                                                  parsed <= 0
                                              ? 'مبلغ موجب مطلوب'
                                              : null;
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'حذف البند',
                                      onPressed:
                                          _isProcessing || _lines.length == 1
                                          ? null
                                          : () => _removeLine(index),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.red,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<int>(
                                        value: line.costCenterId,
                                        items: provider.costCenters
                                            .map(
                                              (center) => DropdownMenuItem<int>(
                                                value: (center['id'] as num)
                                                    .toInt(),
                                                child: Text(
                                                  center['name'].toString(),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (value) => setState(
                                          () => line.costCenterId = value,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'مركز التكلفة (اختياري)',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 2,
                                      child: TextFormField(
                                        controller: line.descriptionController,
                                        maxLines: 1,
                                        decoration: const InputDecoration(
                                          labelText: 'بيان هذا البند',
                                          border: OutlineInputBorder(),
                                        ),
                                        validator: (value) =>
                                            value?.trim().isEmpty ?? true
                                            ? 'البيان مطلوب'
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _descController,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'بيان رأس السند (إجمالي)',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value?.trim().isEmpty ?? true
                            ? 'البيان العام مطلوب'
                            : null,
                      ),
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  _isProcessing ||
                                      !PermissionRuntime.allows(
                                        'accounting',
                                        AppPermissionAction.post,
                                      )
                                  ? null
                                  : () => _saveVoucher(saveAsPdf: false),
                              icon: const Icon(Icons.print),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.all(16),
                                backgroundColor: primaryColor,
                              ),
                              label: Text(
                                PermissionRuntime.allows(
                                      'accounting',
                                      AppPermissionAction.print,
                                    )
                                    ? 'حفظ وترحيل وطباعة'
                                    : 'حفظ وترحيل ومعاينة',
                              ),
                            ),
                          ),
                          if (PermissionRuntime.allows(
                            'accounting',
                            AppPermissionAction.print,
                          )) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _isProcessing ||
                                        !PermissionRuntime.allows(
                                          'accounting',
                                          AppPermissionAction.post,
                                        )
                                    ? null
                                    : () => _saveVoucher(saveAsPdf: true),
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
          ),
        );
      },
    );
  }
}

class _GeneralVoucherLine {
  int? accountId;
  int? costCenterId;
  final TextEditingController amountController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();

  void dispose() {
    amountController.dispose();
    descriptionController.dispose();
  }
}
