import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';

class TaxInvoiceScreen extends StatefulWidget {
  const TaxInvoiceScreen({super.key});

  @override
  State<TaxInvoiceScreen> createState() => _TaxInvoiceScreenState();
}

class _TaxInvoiceScreenState extends State<TaxInvoiceScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedContractId;
  int? _selectedTenantId;
  int? _revenueAccountId;
  int? _taxAccountId;

  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _netAmountController = TextEditingController();
  final _taxAmountController = TextEditingController();
  final _grossAmountController = TextEditingController();

  void _calculateGross() {
    double net = double.tryParse(_netAmountController.text) ?? 0.0;
    double tax = double.tryParse(_taxAmountController.text) ?? 0.0;
    _grossAmountController.text = (net + tax).toStringAsFixed(2);
  }

  void _processInvoice() async {
    if (_formKey.currentState!.validate() && _selectedContractId != null && _selectedTenantId != null && _revenueAccountId != null && _taxAccountId != null) {
      double net = double.tryParse(_netAmountController.text) ?? 0.0;
      double tax = double.tryParse(_taxAmountController.text) ?? 0.0;

      if (net <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ الصافي يجب أن يكون أكبر من صفر')));
        return;
      }

      try {
        await DatabaseHelper.instance.insertTaxInvoice(
          contractId: _selectedContractId!,
          tenantId: _selectedTenantId!,
          invoiceDate: _dateController.text,
          totalAmount: net,
          taxAmount: tax,
          revenueAccountId: _revenueAccountId!,
          taxAccountId: _taxAccountId!,
        );

        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إصدار الفاتورة وتوليد القيد الآلي')));
           Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
           _netAmountController.clear();
           _taxAmountController.clear();
           _grossAmountController.clear();
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
                    const Text('إصدار فاتورة ضريبية', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedContractId,
                            items: leasingProv.contracts.map((c) => DropdownMenuItem<int>(
                              value: c['id'],
                              child: Text('عقد رقم: ${c['id']}'),
                            )).toList(),
                            onChanged: (val) {
                              setState(() {
                                _selectedContractId = val;
                                // Auto select tenant
                                if (val != null) {
                                  final contract = leasingProv.contracts.firstWhere((c) => c['id'] == val);
                                  _selectedTenantId = contract['tenant_id'];
                                }
                              });
                            },
                            decoration: const InputDecoration(labelText: 'اختر العقد المرتبط', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedTenantId,
                            items: leasingProv.tenants.map((t) => DropdownMenuItem<int>(
                              value: t['id'],
                              child: Text(t['name']),
                            )).toList(),
                            onChanged: (val) => setState(() => _selectedTenantId = val),
                            decoration: const InputDecoration(labelText: 'المستأجر', border: OutlineInputBorder()),
                            // Disable if auto-selected via contract, but keep it readable
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _revenueAccountId,
                            items: accProv.accounts.where((a) => a['account_type'] == 'Revenue').map((a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['code']} - ${a['name']}'),
                            )).toList(),
                            onChanged: (val) => setState(() => _revenueAccountId = val),
                            decoration: const InputDecoration(labelText: 'حساب إيراد الإيجار (Credit)', border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _taxAccountId,
                            items: accProv.accounts.where((a) => a['account_type'] == 'Liability').map((a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['code']} - ${a['name']}'),
                            )).toList(),
                            onChanged: (val) => setState(() => _taxAccountId = val),
                            decoration: const InputDecoration(labelText: 'حساب ضريبة القيمة المضافة (Credit)', border: OutlineInputBorder()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _dateController,
                      decoration: const InputDecoration(labelText: 'تاريخ الفاتورة', border: OutlineInputBorder()),
                      readOnly: true,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _netAmountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'المبلغ الصافي', border: OutlineInputBorder()),
                            onChanged: (val) => _calculateGross(),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _taxAmountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'مبلغ الضريبة', border: OutlineInputBorder()),
                            onChanged: (val) => _calculateGross(),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _grossAmountController,
                            decoration: const InputDecoration(labelText: 'الإجمالي (مع الضريبة)', border: OutlineInputBorder()),
                            readOnly: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _processInvoice,
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                      child: const Text('إصدار الفاتورة والترحيل الآلي', style: TextStyle(fontSize: 18)),
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
