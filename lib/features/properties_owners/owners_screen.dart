import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/property_provider.dart';

class OwnersScreen extends StatelessWidget {
  const OwnersScreen({super.key});

  void _showAddOwnerDialog(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final mobileController = TextEditingController();
    final identityController = TextEditingController();
    final ibanController = TextEditingController();
    final commissionController = TextEditingController(text: '0.0');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إضافة مالك جديد'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'الاسم'),
                    validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                  ),
                  TextFormField(
                    controller: mobileController,
                    decoration: const InputDecoration(labelText: 'الجوال'),
                    keyboardType: TextInputType.phone,
                  ),
                  TextFormField(
                    controller: identityController,
                    decoration: const InputDecoration(labelText: 'رقم الهوية/السجل'),
                  ),
                  TextFormField(
                    controller: ibanController,
                    decoration: const InputDecoration(labelText: 'رقم الآيبان (IBAN)'),
                  ),
                  TextFormField(
                    controller: commissionController,
                    decoration: const InputDecoration(labelText: 'نسبة العمولة (%)'),
                    keyboardType: TextInputType.number,
                    validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                  ),
                  const SizedBox(height: 16),
                  const Text('ملاحظة: سيتم إنشاء حساب فرعي للمالك تلقائياً في دليل الحسابات.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  final provider = Provider.of<PropertyProvider>(context, listen: false);
                  try {
                    await provider.addOwner({
                      'name': nameController.text,
                      'mobile': mobileController.text,
                      'identity_number': identityController.text,
                      'iban': ibanController.text,
                      'commission_rate': double.tryParse(commissionController.text) ?? 0.0,
                    });
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت إضافة المالك وإنشاء الحساب بنجاح')));
                    }
                  } catch (e) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
                  }
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PropertyProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('إدارة الملاك', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: () => _showAddOwnerDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة مالك جديد'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('المعرف')),
                      DataColumn(label: Text('الاسم')),
                      DataColumn(label: Text('الجوال')),
                      DataColumn(label: Text('رقم الحساب المحاسبي')),
                      DataColumn(label: Text('نسبة العمولة')),
                    ],
                    rows: provider.owners.map((owner) {
                      return DataRow(cells: [
                        DataCell(Text(owner['id'].toString())),
                        DataCell(Text(owner['name'] ?? '')),
                        DataCell(Text(owner['mobile'] ?? '')),
                        DataCell(Text(owner['account_id']?.toString() ?? '')),
                        DataCell(Text('${owner['commission_rate']} %')),
                      ]);
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
