import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import 'package:intl/intl.dart';
import '../../core/print_utils.dart';

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

  int? _cashAccountId;
  int? _oppositeAccountId;
  int? _costCenterId;
  bool _isProcessing = false;

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

  Future<void> _saveVoucher({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    if (!_formKey.currentState!.validate() ||
        _cashAccountId == null ||
        _oppositeAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء تعبئة جميع الحقول المطلوبة واختيار الحسابات'),
        ),
      );
      return;
    }
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0 || DateTime.tryParse(_dateController.text) == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تحقق من المبلغ والتاريخ')));
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
    };
    setState(() => _isProcessing = true);
    late final int voucherId;
    try {
      voucherId = await accountingProvider.saveGeneralVoucher(
        voucher,
        _cashAccountId!,
        _oppositeAccountId!,
        _costCenterId,
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
      final counterpart = accounts.firstWhere(
        (a) => a['id'] == _oppositeAccountId,
      );
      final isReceipt = widget.voucherType == 'قبض عام';
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: isReceipt ? 'سند قبض عام' : 'سند صرف عام',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: null,
        amount: amount,
        paymentMethod: null,
        accountName: '${cashAccount['name']} / ${counterpart['name']}',
        description: _descController.text.trim(),
      );
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(
          pdfBytes,
          '${widget.voucherType}_$voucherId',
        );
        if (mounted && saved)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
      } else {
        await PrintUtils.printPdf(pdfBytes, '${widget.voucherType}_$voucherId');
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ السند رقم $voucherId، لكن تعذر تجهيز/حفظ المستند: $e',
            ),
          ),
        );
    }

    if (mounted) {
      _formKey.currentState!.reset();
      setState(() {
        _cashAccountId = null;
        _oppositeAccountId = null;
        _costCenterId = null;
        _amountController.clear();
        _descController.clear();
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
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'المبلغ',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _cashAccountId,
                            items: provider.accounts
                                .where(
                                  (a) =>
                                      a['account_type'] == 'Asset' &&
                                      a['code'].toString().startsWith('11') &&
                                      a['parent_id'] != null,
                                )
                                .map(
                                  (a) => DropdownMenuItem<int>(
                                    value: a['id'],
                                    child: Text('${a['code']} - ${a['name']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _cashAccountId = val),
                            decoration: InputDecoration(
                              labelText: isReceipt
                                  ? 'يُقبض إلى حساب (الصندوق/البنك)'
                                  : 'يُصرف من حساب (الصندوق/البنك)',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _oppositeAccountId,
                            items: provider.accounts
                                .where(
                                  (a) =>
                                      a['parent_id'] != null &&
                                      (isReceipt
                                          ? [
                                              'Asset',
                                              'Liability',
                                              'Equity',
                                              'Revenue',
                                            ].contains(a['account_type'])
                                          : [
                                              'Asset',
                                              'Liability',
                                              'Equity',
                                              'Expense',
                                            ].contains(a['account_type'])),
                                )
                                .map(
                                  (a) => DropdownMenuItem<int>(
                                    value: a['id'],
                                    child: Text('${a['code']} - ${a['name']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _oppositeAccountId = val),
                            decoration: InputDecoration(
                              labelText: isReceipt
                                  ? 'حساب الإيراد / الحساب الدائن'
                                  : 'حساب المصروف / الحساب المدين',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: _descController,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              labelText: 'البيان',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 1,
                          child: DropdownButtonFormField<int>(
                            value: _costCenterId,
                            items: provider.costCenters
                                .map(
                                  (c) => DropdownMenuItem<int>(
                                    value: c['id'],
                                    child: Text(c['name']),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _costCenterId = val),
                            decoration: const InputDecoration(
                              labelText: 'مركز التكلفة',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _saveVoucher(saveAsPdf: false),
                            icon: const Icon(Icons.print),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                              backgroundColor: primaryColor,
                            ),
                            label: const Text('حفظ وترحيل وطباعة'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isProcessing
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
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
