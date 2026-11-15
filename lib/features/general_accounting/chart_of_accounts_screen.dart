import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';
import '../../providers/accounting_provider.dart';

class ChartOfAccountsScreen extends StatefulWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  State<ChartOfAccountsScreen> createState() => _ChartOfAccountsScreenState();
}

class _ChartOfAccountsScreenState extends State<ChartOfAccountsScreen> {
  static const Map<String, String> _accountTypeLabels = {
    'Asset': 'أصول',
    'Liability': 'خصوم',
    'Equity': 'حقوق ملكية',
    'Revenue': 'إيرادات',
    'Expense': 'مصروفات',
  };
  static const Map<String, String> _rootCodes = {
    'Asset': '1',
    'Liability': '2',
    'Equity': '3',
    'Revenue': '4',
    'Expense': '5',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      }
    });
  }

  String _typeLabel(Object? type) =>
      _accountTypeLabels[type?.toString()] ?? 'نوع غير معروف';

  List<String> _availableRootTypes(List<Map<String, dynamic>> accounts) {
    final existing = accounts
        .where((account) => account['parent_id'] == null)
        .map((account) => account['account_type']?.toString())
        .toSet();
    return _rootCodes.keys.where((type) => !existing.contains(type)).toList();
  }

  Future<void> _showAccountDialog({
    Map<String, dynamic>? parentAccount,
    Map<String, dynamic>? existingAccount,
  }) async {
    final canAdd = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.add,
    );
    final canEdit = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.edit,
    );
    final isEditing = existingAccount != null;
    if ((!isEditing && !canAdd) || (isEditing && !canEdit)) return;

    final provider = Provider.of<AccountingProvider>(context, listen: false);
    final availableTypes = _availableRootTypes(provider.accounts);
    if (!isEditing && parentAccount == null && availableTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الحسابات الرئيسية للأنواع الخمسة موجودة'),
        ),
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: existingAccount?['name']?.toString() ?? '',
    );
    String? accountType = isEditing
        ? existingAccount['account_type']?.toString()
        : parentAccount?['account_type']?.toString() ?? availableTypes.first;
    String codePreview = existingAccount?['code']?.toString() ?? '';

    if (!isEditing && parentAccount != null) {
      try {
        codePreview = await DatabaseHelper.instance.generateAccountCode(
          parentAccount['id'] as int,
        );
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تعذر تجهيز رمز الحساب: $error')),
          );
        }
        nameController.dispose();
        return;
      }
    } else if (!isEditing && accountType != null) {
      codePreview = _rootCodes[accountType] ?? '';
    }

    if (!mounted) {
      nameController.dispose();
      return;
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            scrollable: true,
            title: Text(
              isEditing
                  ? 'تعديل اسم الحساب'
                  : parentAccount == null
                  ? 'إضافة حساب رئيسي'
                  : 'إضافة حساب فرعي تحت: ${parentAccount['name']}',
            ),
            content: Form(
              key: formKey,
              child: SizedBox(
                width: 430,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isEditing) ...[
                      Text('رمز الحساب: $codePreview'),
                      Text(
                        'النوع: ${_typeLabel(existingAccount['account_type'])} — لا يتغير بعد إنشاء الحساب.',
                      ),
                      const SizedBox(height: 12),
                    ] else if (parentAccount != null) ...[
                      Text('الحساب الأعلى: ${parentAccount['name']}'),
                      Text('النوع الموروث: ${_typeLabel(accountType)}'),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: codePreview,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'رمز الحساب المقترح',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else ...[
                      DropdownButtonFormField<String>(
                        value: accountType,
                        items: availableTypes
                            .map(
                              (type) => DropdownMenuItem(
                                value: type,
                                child: Text(_typeLabel(type)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setDialogState(() {
                            accountType = value;
                            codePreview = _rootCodes[value] ?? '';
                          });
                        },
                        decoration: const InputDecoration(
                          labelText: 'طبيعة الحساب الرئيسي',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null ? 'اختر طبيعة الحساب' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: ValueKey(codePreview),
                        initialValue: codePreview,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'رمز الحساب الرئيسي',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: nameController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'اسم الحساب',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value?.trim().isEmpty ?? true
                          ? 'اسم الحساب مطلوب'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  if (formKey.currentState?.validate() != true) return;
                  try {
                    var savedCode = codePreview;
                    if (isEditing) {
                      await provider.updateAccount(
                        existingAccount['id'] as int,
                        nameController.text,
                      );
                    } else {
                      final newAccountId = await provider.addAccount({
                        'name': nameController.text.trim(),
                        'parent_id': parentAccount?['id'],
                        if (parentAccount == null) 'account_type': accountType,
                      });
                      savedCode = provider.accounts
                          .firstWhere(
                            (account) => account['id'] == newAccountId,
                          )['code']
                          .toString();
                    }
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            isEditing
                                ? 'تم تحديث اسم الحساب'
                                : 'تم إنشاء الحساب برمز $savedCode',
                          ),
                        ),
                      );
                    }
                  } catch (error) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text('تعذر حفظ الحساب: $error')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.save_outlined),
                label: Text(isEditing ? 'حفظ التعديل' : 'إنشاء الحساب'),
              ),
            ],
          ),
        ),
      );
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      nameController.dispose();
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> account) async {
    if (!PermissionRuntime.allows('accounting', AppPermissionAction.delete)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تأكيد حذف الحساب'),
        content: Text(
          'سيُرفض الحذف تلقائيًا إذا كان للحساب رصيد أو حركات أو حسابات فرعية أو ارتباطات أخرى.\n\n${account['code']} — ${account['name']}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف الحساب'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await Provider.of<AccountingProvider>(
        context,
        listen: false,
      ).deleteAccount(account['id'] as int);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حذف الحساب غير المستخدم')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حذف الحساب: $error')));
      }
    }
  }

  List<Widget> _buildAccountTree(
    List<Map<String, dynamic>> accounts,
    int? parentId,
    int depth,
  ) {
    final currentLevel =
        accounts.where((account) => account['parent_id'] == parentId).toList()
          ..sort((first, second) {
            final firstCode = first['code']?.toString() ?? '';
            final secondCode = second['code']?.toString() ?? '';
            return firstCode.compareTo(secondCode);
          });

    return currentLevel.expand<Widget>((account) {
      final id = account['id'] as int;
      final hasChildren = accounts.any((child) => child['parent_id'] == id);
      final balance = (account['balance'] as num?)?.toDouble() ?? 0.0;
      final numberFormat = NumberFormat('#,##0.00');
      final actions = <Widget>[
        if (PermissionRuntime.allows('accounting', AppPermissionAction.add))
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'إضافة حساب فرعي',
            onPressed: () => _showAccountDialog(parentAccount: account),
          ),
        if (PermissionRuntime.allows('accounting', AppPermissionAction.edit))
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'تعديل اسم الحساب',
            onPressed: () => _showAccountDialog(existingAccount: account),
          ),
        if (PermissionRuntime.allows('accounting', AppPermissionAction.delete))
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'حذف الحساب إذا لم يكن مستخدمًا',
            onPressed: () => _confirmDelete(account),
          ),
      ];

      return <Widget>[
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: depth * 22.0,
            top: 4,
            bottom: 4,
          ),
          child: Card(
            elevation: 1,
            child: ListTile(
              leading: Container(
                constraints: const BoxConstraints(minWidth: 54),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppPalette.navy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  account['code']?.toString() ?? '-',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppPalette.navy,
                  ),
                ),
              ),
              title: Text(
                account['name']?.toString() ?? '',
                style: TextStyle(
                  fontWeight: hasChildren ? FontWeight.bold : FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${_typeLabel(account['account_type'])} • ${hasChildren ? 'تجميعي' : 'تفصيلي'} • الرصيد: ${numberFormat.format(balance)}',
              ),
              trailing: actions.isEmpty
                  ? null
                  : Wrap(spacing: 0, children: actions),
              dense: true,
            ),
          ),
        ),
        ..._buildAccountTree(accounts, id, depth + 1),
      ];
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading && provider.accounts.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final canAdd = PermissionRuntime.allows(
          'accounting',
          AppPermissionAction.add,
        );
        final rootTypesAvailable = _availableRootTypes(provider.accounts);

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'دليل الحسابات',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'تحديث دليل الحسابات',
                    onPressed: provider.isLoading
                        ? null
                        : provider.loadAccounts,
                    icon: const Icon(Icons.refresh),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: canAdd && rootTypesAvailable.isNotEmpty
                        ? () => _showAccountDialog()
                        : null,
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة حساب رئيسي'),
                  ),
                ],
              ),
              if (provider.errorMessage != null) ...[
                const SizedBox(height: 12),
                Material(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(provider.errorMessage!),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: provider.accounts.isEmpty
                    ? const Center(child: Text('لا توجد حسابات لعرضها'))
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 16),
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
