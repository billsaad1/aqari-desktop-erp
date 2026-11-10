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
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  int? _selectedTenantId;
  int? _selectedCashAccountId;

  List<Map<String, dynamic>> _unpaidInstallments = [];
  bool _isLoadingInstallments = false;
  bool _isProcessing = false;

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

  Future<void> _loadUnpaidInstallments(int tenantId) async {
    setState(() => _isLoadingInstallments = true);

    // Find all active contracts for this tenant
    final contracts = Provider.of<LeasingProvider>(context, listen: false)
        .contracts
        .where((c) => c['tenant_id'] == tenantId && c['status'] == 'Active')
        .toList();

    List<Map<String, dynamic>> installments = [];
    try {
      for (var contract in contracts) {
        final insts = await DatabaseHelper.instance.getInstallmentsForContract(
          contract['id'],
        );
        installments.addAll(insts.where((i) => i['status'] != 'Paid'));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تحميل الأقساط: $e')));
    }

    // Sort by due date
    installments.sort((a, b) => a['due_date'].compareTo(b['due_date']));

    if (!mounted) return;
    setState(() {
      _unpaidInstallments = installments;
      _isLoadingInstallments = false;
      // Auto-fill amount based on first unpaid installment if available
      if (_unpaidInstallments.isNotEmpty) {
        double remaining =
            (_unpaidInstallments.first['amount'] as num).toDouble() -
            (_unpaidInstallments.first['paid_amount'] as num).toDouble();
        _amountController.text = remaining.toString();
      }
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
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    final amountCents = (amount * 100).round();
    if (amountCents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المبلغ يجب أن يكون أكبر من صفر')),
      );
      return;
    }

    final dueInstallments = List<Map<String, dynamic>>.from(_unpaidInstallments)
      ..sort(
        (a, b) => a['due_date'].toString().compareTo(b['due_date'].toString()),
      );
    var remainingCents = amountCents;
    final updates = <Map<String, dynamic>>[];
    for (final installment in dueInstallments) {
      if (remainingCents <= 0) break;
      final totalCents = ((installment['amount'] as num).toDouble() * 100)
          .round();
      final paidCents =
          ((installment['paid_amount'] as num? ?? 0).toDouble() * 100).round();
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
        const SnackBar(content: Text('المبلغ أكبر من إجمالي الأقساط المتبقية')),
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
      voucherId = await DatabaseHelper.instance.insertTenantReceiptVoucher(
        tenantId: _selectedTenantId!,
        amount: amountCents / 100,
        voucherDate: _dateController.text,
        cashAccountId: _selectedCashAccountId!,
        installmentsToUpdate: updates,
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ سند القبض: $e')));
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم حفظ سند القبض رقم $voucherId وترحيل القيد')),
    );
    try {
      final tenantName = leasingProvider.tenants
          .firstWhere((t) => t['id'] == _selectedTenantId)['name']
          .toString();
      final accountName = accountingProvider.accounts
          .firstWhere((a) => a['id'] == _selectedCashAccountId)['name']
          .toString();
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: voucherId,
        date: _dateController.text,
        targetName: tenantName,
        amount: amountCents / 100,
        paymentMethod: null,
        accountName: accountName,
        description: 'تحصيل دفعة إيجار',
      );
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(
          pdfBytes,
          'سند_قبض_مستأجر_$voucherId',
        );
        if (mounted && saved)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
      } else {
        await PrintUtils.printPdf(pdfBytes, 'سند_قبض_مستأجر_$voucherId');
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
    await _loadUnpaidInstallments(_selectedTenantId!);
    if (mounted) {
      _amountController.clear();
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
                        value: _selectedTenantId,
                        items: leasingProv.tenants
                            .map(
                              (t) => DropdownMenuItem<int>(
                                value: t['id'],
                                child: Text(t['name']),
                              ),
                            )
                            .toList(),
                        onChanged: (val) {
                          setState(() => _selectedTenantId = val);
                          if (val != null) _loadUnpaidInstallments(val);
                        },
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
                        onTap: _pickDate,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'المبلغ المستلم',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isProcessing
                                  ? null
                                  : () => _processReceipt(saveAsPdf: false),
                              icon: const Icon(Icons.print),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
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
                                  : () => _processReceipt(saveAsPdf: true),
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
              const SizedBox(width: 24),
              // Right Panel: Unpaid Installments
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'الأقساط المستحقة',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_selectedTenantId == null)
                      const Center(
                        child: Text('الرجاء اختيار مستأجر لعرض الأقساط'),
                      )
                    else if (_isLoadingInstallments)
                      const Center(child: CircularProgressIndicator())
                    else if (_unpaidInstallments.isEmpty)
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
                        child: ListView.builder(
                          itemCount: _unpaidInstallments.length,
                          itemBuilder: (context, index) {
                            final inst = _unpaidInstallments[index];
                            double total = (inst['amount'] as num).toDouble();
                            double paid = (inst['paid_amount'] as num)
                                .toDouble();
                            double remaining = total - paid;
                            return Card(
                              child: ListTile(
                                leading: const Icon(
                                  Icons.warning,
                                  color: Colors.orange,
                                ),
                                title: Text(
                                  'تاريخ الاستحقاق: ${inst['due_date']}',
                                ),
                                subtitle: Text(
                                  'الحالة: ${inst['status']} | المدفوع سابقاً: $paid',
                                ),
                                trailing: Text(
                                  'المتبقي: $remaining',
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
