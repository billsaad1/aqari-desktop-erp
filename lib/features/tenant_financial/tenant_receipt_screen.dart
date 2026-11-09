import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';
import '../../core/print_utils.dart';

class TenantReceiptScreen extends StatefulWidget {
  const TenantReceiptScreen({super.key});

  @override
  State<TenantReceiptScreen> createState() => _TenantReceiptScreenState();
}

class _TenantReceiptScreenState extends State<TenantReceiptScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));

  int? _selectedTenantId;
  int? _selectedCashAccountId;

  List<Map<String, dynamic>> _unpaidInstallments = [];
  bool _isLoadingInstallments = false;

  void _loadUnpaidInstallments(int tenantId) async {
    setState(() => _isLoadingInstallments = true);

    // Find all active contracts for this tenant
    final contracts = Provider.of<LeasingProvider>(context, listen: false)
        .contracts.where((c) => c['tenant_id'] == tenantId && c['status'] == 'Active').toList();

    List<Map<String, dynamic>> installments = [];
    for (var contract in contracts) {
      final insts = await DatabaseHelper.instance.getInstallmentsForContract(contract['id']);
      installments.addAll(insts.where((i) => i['status'] != 'Paid'));
    }

    // Sort by due date
    installments.sort((a, b) => a['due_date'].compareTo(b['due_date']));

    setState(() {
      _unpaidInstallments = installments;
      _isLoadingInstallments = false;
      // Auto-fill amount based on first unpaid installment if available
      if (_unpaidInstallments.isNotEmpty) {
         double remaining = (_unpaidInstallments.first['amount'] as num).toDouble() - (_unpaidInstallments.first['paid_amount'] as num).toDouble();
         _amountController.text = remaining.toString();
      }
    });
  }

  void _processReceipt() async {
    if (_formKey.currentState!.validate() && _selectedTenantId != null && _selectedCashAccountId != null) {
      double amountToPay = double.tryParse(_amountController.text) ?? 0.0;
      if (amountToPay <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')));
        return;
      }

      double totalRemainingUnpaid = _unpaidInstallments.fold(0.0, (sum, inst) => sum + ((inst['amount'] as num) - (inst['paid_amount'] as num)));

      if (amountToPay > totalRemainingUnpaid) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ المدخل أكبر من إجمالي المستحقات')));
        return;
      }

      // Distribute amount over installments
      double remainingAmountToDistribute = amountToPay;
      List<Map<String, dynamic>> updatedInstallments = [];

      for (var inst in _unpaidInstallments) {
        if (remainingAmountToDistribute <= 0) break;

        double instTotal = (inst['amount'] as num).toDouble();
        double instPaid = (inst['paid_amount'] as num).toDouble();
        double instRemaining = instTotal - instPaid;

        if (instRemaining > 0) {
          double allocation = remainingAmountToDistribute >= instRemaining ? instRemaining : remainingAmountToDistribute;
          double newPaidAmount = instPaid + allocation;

          updatedInstallments.add({
            'id': inst['id'],
            'paid_amount': newPaidAmount,
            'status': newPaidAmount >= instTotal ? 'Paid' : 'Partially Paid',
          });

          remainingAmountToDistribute -= allocation;
        }
      }

      try {
        final voucherId = await DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: _selectedTenantId!,
          amount: amountToPay,
          voucherDate: _dateController.text,
          cashAccountId: _selectedCashAccountId!,
          installmentsToUpdate: updatedInstallments,
        );

        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم التحصيل بنجاح وتوليد القيد الآلي')));

           // Extract required info for printing
           final leasingProv = Provider.of<LeasingProvider>(context, listen: false);
           final accProv = Provider.of<AccountingProvider>(context, listen: false);

           final tenantName = leasingProv.tenants.firstWhere((t) => t['id'] == _selectedTenantId)['name'];
           final accountName = accProv.accounts.firstWhere((a) => a['id'] == _selectedCashAccountId)['name'];

           // Print Voucher
           await PrintUtils.printVoucher(
             voucherType: 'سند قبض',
             voucherNo: voucherId,
             date: _dateController.text,
             targetName: tenantName,
             amount: amountToPay,
             paymentMethod: 'نقداً/بنكي',
             accountName: accountName,
           );

           // Refresh accounts to reflect new balances
           Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
           // Refresh installments list
           _loadUnpaidInstallments(_selectedTenantId!);
           _amountController.clear();
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
                      const Text('سند قبض مستأجر', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green)),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<int>(
                        value: _selectedTenantId,
                        items: leasingProv.tenants.map((t) => DropdownMenuItem<int>(
                          value: t['id'],
                          child: Text(t['name']),
                        )).toList(),
                        onChanged: (val) {
                          setState(() => _selectedTenantId = val);
                          if (val != null) _loadUnpaidInstallments(val);
                        },
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
                        decoration: const InputDecoration(labelText: 'يُقبض إلى حساب (الصندوق/البنك)', border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _dateController,
                        decoration: const InputDecoration(labelText: 'تاريخ السند', border: OutlineInputBorder()),
                        readOnly: true,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'المبلغ المستلم', border: OutlineInputBorder()),
                        validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _processReceipt,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.all(16)),
                        child: const Text('حفظ السند والترحيل الآلي', style: TextStyle(fontSize: 18)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right Panel: Unpaid Installments
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('الأقساط المستحقة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    if (_selectedTenantId == null)
                      const Center(child: Text('الرجاء اختيار مستأجر لعرض الأقساط'))
                    else if (_isLoadingInstallments)
                      const Center(child: CircularProgressIndicator())
                    else if (_unpaidInstallments.isEmpty)
                      const Center(child: Text('لا توجد مستحقات مالية على هذا المستأجر', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)))
                    else
                      Expanded(
                        child: ListView.builder(
                          itemCount: _unpaidInstallments.length,
                          itemBuilder: (context, index) {
                            final inst = _unpaidInstallments[index];
                            double total = (inst['amount'] as num).toDouble();
                            double paid = (inst['paid_amount'] as num).toDouble();
                            double remaining = total - paid;
                            return Card(
                              child: ListTile(
                                leading: const Icon(Icons.warning, color: Colors.orange),
                                title: Text('تاريخ الاستحقاق: ${inst['due_date']}'),
                                subtitle: Text('الحالة: ${inst['status']} | المدفوع سابقاً: $paid'),
                                trailing: Text('المتبقي: $remaining', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              ),
                            );
                          },
                        ),
                      )
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
