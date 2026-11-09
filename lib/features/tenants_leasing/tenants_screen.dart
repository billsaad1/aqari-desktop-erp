import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/leasing_provider.dart';

class TenantsScreen extends StatelessWidget {
  const TenantsScreen({super.key});

  void _showAddTenantDialog(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final mobileController = TextEditingController();
    final identityController = TextEditingController();
    int? selectedNationalityId;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إضافة مستأجر جديد'),
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
                    validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                  ),
                  TextFormField(
                    controller: identityController,
                    decoration: const InputDecoration(labelText: 'رقم الهوية'),
                  ),
                  Consumer<LeasingProvider>(
                    builder: (context, provider, child) {
                      return DropdownButtonFormField<int>(
                        value: selectedNationalityId,
                        items: provider.nationalities.map((n) => DropdownMenuItem<int>(
                          value: n['id'],
                          child: Text(n['name']),
                        )).toList(),
                        onChanged: (val) => selectedNationalityId = val,
                        decoration: const InputDecoration(labelText: 'الجنسية'),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('ملاحظة: سيتم إنشاء حساب فرعي للمستأجر تلقائياً تحت حساب ذمم المستأجرين.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  final provider = Provider.of<LeasingProvider>(context, listen: false);
                  try {
                    await provider.addTenant({
                      'name': nameController.text,
                      'mobile': mobileController.text,
                      'identity_number': identityController.text,
                      'nationality_id': selectedNationalityId,
                    });
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت إضافة المستأجر وإنشاء الحساب بنجاح')));
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
    return Consumer<LeasingProvider>(
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
                  const Text('إدارة المستأجرين', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: () => _showAddTenantDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة مستأجر جديد'),
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
                      DataColumn(label: Text('الهوية')),
                      DataColumn(label: Text('رقم الحساب المحاسبي')),
                    ],
                    rows: provider.tenants.map((tenant) {
                      return DataRow(cells: [
                        DataCell(Text(tenant['id'].toString())),
                        DataCell(Text(tenant['name'] ?? '')),
                        DataCell(Text(tenant['mobile'] ?? '')),
                        DataCell(Text(tenant['identity_number'] ?? '')),
                        DataCell(Text(tenant['account_id']?.toString() ?? '')),
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
