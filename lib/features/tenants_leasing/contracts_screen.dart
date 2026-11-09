import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/property_provider.dart';

class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key});

  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedTenantId;
  int? _selectedUnitId;

  final _startDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _endDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 365))));
  final _totalRentController = TextEditingController();

  String _paymentMethod = 'شهري';
  List<Map<String, dynamic>> _generatedInstallments = [];

  void _generateInstallments() {
    if (_totalRentController.text.isEmpty) return;

    double totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
    if (totalRent <= 0) return;

    DateTime startDate = DateFormat('yyyy-MM-dd').parse(_startDateController.text);
    DateTime endDate = DateFormat('yyyy-MM-dd').parse(_endDateController.text);

    int monthsDifference = (endDate.year - startDate.year) * 12 + endDate.month - startDate.month;
    if (monthsDifference <= 0) monthsDifference = 12; // fallback

    int numInstallments = 1;
    int monthsPerInstallment = 12;

    switch (_paymentMethod) {
      case 'شهري':
        numInstallments = monthsDifference;
        monthsPerInstallment = 1;
        break;
      case 'ربع سنوي':
        numInstallments = (monthsDifference / 3).ceil();
        monthsPerInstallment = 3;
        break;
      case 'نصف سنوي':
        numInstallments = (monthsDifference / 6).ceil();
        monthsPerInstallment = 6;
        break;
      case 'سنوي':
        numInstallments = (monthsDifference / 12).ceil();
        if (numInstallments == 0) numInstallments = 1;
        monthsPerInstallment = 12;
        break;
    }

    double amountPerInstallment = totalRent / numInstallments;
    List<Map<String, dynamic>> newInstallments = [];

    for (int i = 0; i < numInstallments; i++) {
      DateTime dueDate = DateTime(startDate.year, startDate.month + (i * monthsPerInstallment), startDate.day);
      newInstallments.add({
        'amount': amountPerInstallment,
        'paid_amount': 0.0,
        'due_date': DateFormat('yyyy-MM-dd').format(dueDate),
        'status': 'Unpaid',
      });
    }

    setState(() {
      _generatedInstallments = newInstallments;
    });
  }

  void _saveContract() async {
    if (_formKey.currentState!.validate() && _selectedTenantId != null && _selectedUnitId != null) {
      if (_generatedInstallments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء توليد الأقساط أولاً')));
        return;
      }

      final contract = {
        'tenant_id': _selectedTenantId,
        'unit_id': _selectedUnitId,
        'start_date': _startDateController.text,
        'end_date': _endDateController.text,
        'rent_amount': double.tryParse(_totalRentController.text) ?? 0.0,
        'payment_method': _paymentMethod,
        'status': 'Active',
      };

      try {
        await Provider.of<LeasingProvider>(context, listen: false).addContract(contract, _generatedInstallments);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ العقد وتحديث حالة الوحدة بنجاح')));
          // Reset form
          setState(() {
            _selectedTenantId = null;
            _selectedUnitId = null;
            _totalRentController.clear();
            _generatedInstallments.clear();
          });
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, PropertyProvider>(
      builder: (context, leasingProv, propProv, child) {
        if (leasingProv.isLoading || propProv.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left side: Contract Form
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('إنشاء عقد جديد', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
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
                          value: _selectedUnitId,
                          items: leasingProv.vacantUnits.map((u) {
                            final propName = propProv.properties.firstWhere((p) => p['id'] == u['property_id'], orElse: () => {'name': ''})['name'];
                            return DropdownMenuItem<int>(
                              value: u['id'],
                              child: Text('عقار: $propName - وحدة: ${u['unit_number']}'),
                            );
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _selectedUnitId = val;
                              // Auto-fill rent if a unit is selected
                              final unit = leasingProv.vacantUnits.firstWhere((u) => u['id'] == val);
                              if (unit['default_rent'] != null) {
                                _totalRentController.text = unit['default_rent'].toString();
                              }
                            });
                          },
                          decoration: const InputDecoration(labelText: 'الوحدة الشاغرة', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _startDateController,
                                decoration: const InputDecoration(labelText: 'بداية العقد', border: OutlineInputBorder()),
                                readOnly: true,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _endDateController,
                                decoration: const InputDecoration(labelText: 'نهاية العقد', border: OutlineInputBorder()),
                                readOnly: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _totalRentController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'القيمة الإجمالية للعقد', border: OutlineInputBorder()),
                          validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _paymentMethod,
                          items: ['شهري', 'ربع سنوي', 'نصف سنوي', 'سنوي'].map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m),
                          )).toList(),
                          onChanged: (val) => setState(() => _paymentMethod = val!),
                          decoration: const InputDecoration(labelText: 'طريقة الدفع', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _generateInstallments,
                          child: const Text('توليد جدول الأقساط'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right side: Generated Installments & Save
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('جدول الدفعات (الأقساط)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)),
                        child: _generatedInstallments.isEmpty
                            ? const Center(child: Text('لم يتم توليد الأقساط بعد'))
                            : ListView.builder(
                                itemCount: _generatedInstallments.length,
                                itemBuilder: (context, index) {
                                  final inst = _generatedInstallments[index];
                                  return ListTile(
                                    leading: CircleAvatar(child: Text('${index + 1}')),
                                    title: Text('تاريخ الاستحقاق: ${inst['due_date']}'),
                                    trailing: Text('${inst['amount'].toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _generatedInstallments.isNotEmpty ? _saveContract : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.green,
                      ),
                      child: const Text('حفظ العقد واعتماد الأقساط', style: TextStyle(fontSize: 18)),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const Text('إدارة العقود الحالية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: leasingProv.contracts.length,
                        itemBuilder: (context, index) {
                          final contract = leasingProv.contracts[index];
                          final tenantName = leasingProv.tenants.firstWhere((t) => t['id'] == contract['tenant_id'], orElse: () => {'name': 'غير معروف'})['name'];
                          return ListTile(
                            title: Text('عقد رقم: ${contract['id']} - المستأجر: $tenantName'),
                            subtitle: Text('الحالة: ${contract['status']} | الإجمالي: ${contract['rent_amount']}'),
                            trailing: contract['status'] == 'Active' ? IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.red),
                              tooltip: 'إلغاء العقد',
                              onPressed: () => _cancelContract(contract['id']),
                            ) : null,
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

  void _cancelContract(int contractId) async {
    bool confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الإلغاء'),
        content: const Text('هل أنت متأكد من إلغاء هذا العقد؟ إذا كان هناك دفعات مسددة سيرفض النظام الإلغاء.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('تراجع')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('نعم، إلغاء'),
          ),
        ],
      )
    ) ?? false;

    if (confirm) {
      try {
        await Provider.of<LeasingProvider>(context, listen: false).cancelContract(contractId);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إلغاء العقد بنجاح')));
      } catch (e) {
        if (mounted) {
           showDialog(
             context: context,
             builder: (context) => AlertDialog(
               title: const Text('لا يمكن الإلغاء'),
               content: Text(e.toString()),
               actions: [
                 TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسناً'))
               ]
             )
           );
        }
      }
    }
  }
}
