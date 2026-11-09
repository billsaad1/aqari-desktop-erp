import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import 'package:intl/intl.dart';

class GeneralVoucherScreen extends StatefulWidget {
  final String voucherType; // 'قبض عام' or 'صرف عام'
  const GeneralVoucherScreen({super.key, required this.voucherType});

  @override
  State<GeneralVoucherScreen> createState() => _GeneralVoucherScreenState();
}

class _GeneralVoucherScreenState extends State<GeneralVoucherScreen> {
  final _formKey = GlobalKey<FormState>();
  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _amountController = TextEditingController();
  final _descController = TextEditingController();

  int? _cashAccountId;
  int? _oppositeAccountId;
  int? _costCenterId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
    });
  }

  void _saveVoucher() async {
    if (_formKey.currentState!.validate() && _cashAccountId != null && _oppositeAccountId != null) {
      final amount = double.tryParse(_amountController.text) ?? 0.0;
      if (amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')));
        return;
      }

      final voucher = {
        'voucher_type': widget.voucherType,
        'voucher_date': _dateController.text,
        'amount': amount,
      };

      try {
        await Provider.of<AccountingProvider>(context, listen: false).saveGeneralVoucher(
          voucher,
          _cashAccountId!,
          _oppositeAccountId!,
          _costCenterId,
          widget.voucherType
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ السند وتوليد القيد الآلي بنجاح')));
          _formKey.currentState!.reset();
          setState(() {
            _cashAccountId = null;
            _oppositeAccountId = null;
            _costCenterId = null;
            _amountController.clear();
            _descController.clear();
          });
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة واختيار الحسابات')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReceipt = widget.voucherType == 'قبض عام';
    final primaryColor = isReceipt ? Colors.green : Colors.red;

    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

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
                    Text('سند ${widget.voucherType}', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: primaryColor)),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _dateController,
                            decoration: const InputDecoration(labelText: 'التاريخ', border: OutlineInputBorder()),
                            readOnly: true,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _amountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'المبلغ', border: OutlineInputBorder()),
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
                            items: provider.accounts.where((a) => a['account_type'] == 'Asset').map((a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['''code''']} - ${a['''name''']}'),
                            )).toList(),
                            onChanged: (val) => setState(() => _cashAccountId = val),
                            decoration: InputDecoration(
                              labelText: isReceipt ? 'يُقبض إلى حساب (الصندوق/البنك)' : 'يُصرف من حساب (الصندوق/البنك)',
                              border: const OutlineInputBorder()
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _oppositeAccountId,
                            items: provider.accounts.map((a) => DropdownMenuItem<int>(
                              value: a['id'],
                              child: Text('${a['''code''']} - ${a['''name''']}'),
                            )).toList(),
                            onChanged: (val) => setState(() => _oppositeAccountId = val),
                            decoration: InputDecoration(
                              labelText: isReceipt ? 'حساب الإيراد / الحساب الدائن' : 'حساب المصروف / الحساب المدين',
                              border: const OutlineInputBorder()
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
                            decoration: const InputDecoration(labelText: 'البيان', border: OutlineInputBorder()),
                            validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 1,
                          child: DropdownButtonFormField<int>(
                            value: _costCenterId,
                            items: provider.costCenters.map((c) => DropdownMenuItem<int>(
                              value: c['id'],
                              child: Text(c['name']),
                            )).toList(),
                            onChanged: (val) => setState(() => _costCenterId = val),
                            decoration: const InputDecoration(
                              labelText: 'مركز التكلفة',
                              border: OutlineInputBorder()
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _saveVoucher,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: primaryColor,
                      ),
                      child: Text('حفظ ${widget.voucherType} وترحيل', style: const TextStyle(fontSize: 18)),
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
