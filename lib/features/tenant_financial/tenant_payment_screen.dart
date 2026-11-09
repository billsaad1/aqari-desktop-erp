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
  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));

  int? _selectedTenantId;
  int? _selectedCashAccountId;

  void _processPayment() async {
    if (_formKey.currentState!.validate() && _selectedTenantId != null && _selectedCashAccountId != null) {
      double amount = double.tryParse(_amountController.text) ?? 0.0;
      if (amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')));
        return;
      }

      try {
        final voucherId = await DatabaseHelper.instance.insertTenantPaymentVoucher(
          tenantId: _selectedTenantId!,
          amount: amount,
          voucherDate: _dateController.text,
          cashAccountId: _selectedCashAccountId!,
          description: _descController.text,
        );

        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الصرف بنجاح وتوليد القيد الآلي')));

           // Extract required info for printing
           final leasingProv = Provider.of<LeasingProvider>(context, listen: false);
           final accProv = Provider.of<AccountingProvider>(context, listen: false);

           final tenantName = leasingProv.tenants.firstWhere((t) => t['id'] == _selectedTenantId)['name'];
           final accountName = accProv.accounts.firstWhere((a) => a['id'] == _selectedCashAccountId)['name'];

           // Print Voucher
           await PrintUtils.printVoucher(
             voucherType: 'سند صرف',
             voucherNo: voucherId,
             date: _dateController.text,
             targetName: tenantName,
             amount: amount,
             paymentMethod: 'نقداً/بنكي',
             accountName: accountName,
           );

           // Refresh accounts to reflect new balances
           Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
           _amountController.clear();
           _descController.clear();
        }
      } catch (e) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }

    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProv, accProv, child) {
        if (leasingProv.isLoading || accProv.isLoading) return const Center(child: CircularProgressIndicator());

        final cashAccounts = accProv.accounts.where((a) => a['account_type'] == 'Asset').toList();

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
                    const Text('سند صرف مستأجر (رد مبالغ/تأمين)', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red)),
                    const SizedBox(height: 32),
                    DropdownButtonFormField<int>(
                      value: _selectedTenantId,
                      items: leasingProv.tenants.map((t) => DropdownMenuItem<int>(
                        value: t['id'],
                        child: Text(t['name']),
                      )).toList(),
                      onChanged: (val) => setState(() => _selectedTenantId = val),
                      decoration: const InputDecoration(labelText: 'المستأجر', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: _selectedCashAccountId,
                      items: cashAccounts.map((a) => DropdownMenuItem<int>(
                        value: a['id'],
                        child: Text('${a['code']} - ${a['name']}'),
                      )).toList(),
                      onChanged: (val) => setState(() => _selectedCashAccountId = val),
                      decoration: const InputDecoration(labelText: 'يُصرف من حساب (الصندوق/البنك)', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _dateController,
                            decoration: const InputDecoration(labelText: 'تاريخ السند', border: OutlineInputBorder()),
                            readOnly: true,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _amountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'المبلغ المصروف', border: OutlineInputBorder()),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _descController,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'بيان الصرف', border: OutlineInputBorder()),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _processPayment,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.all(16)),
                      child: const Text('حفظ السند والترحيل الآلي', style: TextStyle(fontSize: 18)),
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
