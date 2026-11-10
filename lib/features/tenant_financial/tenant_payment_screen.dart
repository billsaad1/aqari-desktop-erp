import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';
import '../../core/print_utils.dart';

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
  int? _selectedOffsetAccountId;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted)
      setState(
        () => _dateController.text = DateFormat('yyyy-MM-dd').format(date),
      );
  }

  Future<void> _processPayment({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    if (!_formKey.currentState!.validate() ||
        _selectedTenantId == null ||
        _selectedCashAccountId == null ||
        _selectedOffsetAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة')),
      );
      return;
    }
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')),
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
      voucherId = await DatabaseHelper.instance.insertTenantPaymentVoucher(
        tenantId: _selectedTenantId!,
        amount: amount,
        voucherDate: _dateController.text,
        cashAccountId: _selectedCashAccountId!,
        offsetAccountId: _selectedOffsetAccountId!,
        description: _descController.text.trim(),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ سند الصرف: $e')));
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم حفظ سند الصرف رقم $voucherId وترحيل القيد')),
    );
    try {
      final tenantName = leasingProvider.tenants
          .firstWhere((t) => t['id'] == _selectedTenantId)['name']
          .toString();
      final accountName = accountingProvider.accounts
          .firstWhere((a) => a['id'] == _selectedCashAccountId)['name']
          .toString();
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند صرف مستأجر',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: tenantName,
        amount: amount,
        paymentMethod: 'نقداً/بنكي',
        accountName: accountName,
        description: _descController.text.trim(),
      );
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(
          pdfBytes,
          'سند_صرف_مستأجر_$voucherId',
        );
        if (mounted && saved)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
      } else {
        await PrintUtils.printPdf(pdfBytes, 'سند_صرف_مستأجر_$voucherId');
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'حُفظ السند رقم $voucherId، لكن تعذر تجهيز/طباعة المستند: $e',
            ),
          ),
        );
    }

    await accountingProvider.loadAccounts();
    if (mounted) {
      _amountController.clear();
      _descController.clear();
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProv, accProv, child) {
        if (leasingProv.isLoading || accProv.isLoading)
          return const Center(child: CircularProgressIndicator());

        final cashAccounts = accProv.accounts
            .where(
              (a) =>
                  a['account_type'] == 'Asset' &&
                  a['code'].toString().startsWith('11') &&
                  a['parent_id'] != null,
            )
            .toList();
        final offsetAccounts = accProv.accounts
            .where(
              (a) =>
                  [
                    'Liability',
                    'Expense',
                    'Revenue',
                  ].contains(a['account_type']) &&
                  a['parent_id'] != null,
            )
            .toList();

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
                    const Text(
                      'سند صرف مستأجر (رد مبالغ/تأمين)',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(height: 32),
                    DropdownButtonFormField<int>(
                      value: _selectedTenantId,
                      items: leasingProv.tenants
                          .map(
                            (t) => DropdownMenuItem<int>(
                              value: t['id'],
                              child: Text(t['name']),
                            ),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedTenantId = val),
                      decoration: const InputDecoration(
                        labelText: 'المستأجر',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: _selectedCashAccountId,
                      items: cashAccounts
                          .map(
                            (a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['code']} - ${a['name']}'),
                            ),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedCashAccountId = val),
                      decoration: const InputDecoration(
                        labelText: 'يُصرف من حساب (الصندوق/البنك)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: _selectedOffsetAccountId,
                      items: offsetAccounts
                          .map(
                            (a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['code']} - ${a['name']}'),
                            ),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedOffsetAccountId = val),
                      decoration: const InputDecoration(
                        labelText: 'الحساب المقابل (مثال: تأمينات المستأجرين)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _dateController,
                            decoration: const InputDecoration(
                              labelText: 'تاريخ السند',
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
                              labelText: 'المبلغ المصروف',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _descController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'بيان الصرف',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _processPayment(saveAsPdf: false),
                            icon: const Icon(Icons.print),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              padding: const EdgeInsets.all(16),
                            ),
                            label: const Text('حفظ وترحيل وطباعة'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _processPayment(saveAsPdf: true),
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
