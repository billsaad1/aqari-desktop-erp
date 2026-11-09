import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';

class ChartOfAccountsScreen extends StatefulWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  State<ChartOfAccountsScreen> createState() => _ChartOfAccountsScreenState();
}

class _ChartOfAccountsScreenState extends State<ChartOfAccountsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
    });
  }

  void _showAddAccountDialog(Map<String, dynamic>? parentAccount) async {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    String? accountType = parentAccount != null ? parentAccount['account_type'] : 'Asset';

    String newCode = '';
    if (parentAccount != null) {
      newCode = await DatabaseHelper.instance.generateAccountCode(parentAccount['id']);
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(parentAccount == null ? 'إضافة حساب رئيسي' : 'إضافة حساب فرعي تحت: ${parentAccount['''name''']}'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (parentAccount != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Text('رمز الحساب الجديد: $newCode', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'اسم الحساب'),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
                if (parentAccount == null)
                  DropdownButtonFormField<String>(
                    value: accountType,
                    items: const [
                      DropdownMenuItem(value: 'Asset', child: Text('أصول')),
                      DropdownMenuItem(value: 'Liability', child: Text('خصوم')),
                      DropdownMenuItem(value: 'Equity', child: Text('حقوق ملكية')),
                      DropdownMenuItem(value: 'Revenue', child: Text('إيرادات')),
                      DropdownMenuItem(value: 'Expense', child: Text('مصروفات')),
                    ],
                    onChanged: (val) {
                      accountType = val;
                    },
                    decoration: const InputDecoration(labelText: 'نوع الحساب'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  final newAccount = {
                    'code': parentAccount == null ? DateTime.now().millisecondsSinceEpoch.toString().substring(8) : newCode, // Simplistic root code fallback
                    'name': nameController.text,
                    'parent_id': parentAccount?['id'],
                    'account_type': accountType,
                    'balance': 0.0,
                  };
                  await Provider.of<AccountingProvider>(context, listen: false).addAccount(newAccount);
                  if (context.mounted) {
                    Navigator.pop(context);
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

  // A very basic tree representation for demonstration
  List<Widget> _buildAccountTree(List<Map<String, dynamic>> accounts, int? parentId, int depth) {
    List<Widget> children = [];
    var currentLevelAccounts = accounts.where((a) => a['parent_id'] == parentId).toList();

    for (var acc in currentLevelAccounts) {
      children.add(
        Padding(
          padding: EdgeInsets.only(right: depth * 24.0),
          child: Card(
            elevation: 1,
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: Text(acc['code'], style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
              title: Text(acc['name']),
              subtitle: Text('الرصيد: ${acc['''balance''']} | النوع: ${acc['''account_type''']}'),
              trailing: IconButton(
                icon: const Icon(Icons.add, color: Colors.green),
                tooltip: 'إضافة حساب فرعي',
                onPressed: () => _showAddAccountDialog(acc),
              ),
            ),
          ),
        ),
      );
      // Recursively build children
      children.addAll(_buildAccountTree(accounts, acc['id'], depth + 1));
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('دليل الحسابات', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ElevatedButton.icon(
                    onPressed: () => _showAddAccountDialog(null),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة حساب رئيسي'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: _buildAccountTree(provider.accounts, null, 0),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
