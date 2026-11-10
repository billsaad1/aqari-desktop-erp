import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/erp_data_table.dart';
import 'package:provider/provider.dart';

import '../../providers/leasing_provider.dart';

class TenantsScreen extends StatefulWidget {
  const TenantsScreen({super.key});

  @override
  State<TenantsScreen> createState() => _TenantsScreenState();
}

class _TenantsScreenState extends State<TenantsScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _visibleTenants(
    List<Map<String, dynamic>> tenants,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return tenants;
    return tenants.where((tenant) {
      final searchable = [
        tenant['id'],
        tenant['name'],
        tenant['mobile'],
        tenant['identity_number'],
        tenant['account_id'],
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Future<void> _showTenantDialog(
    BuildContext parentContext, {
    Map<String, dynamic>? tenant,
  }) async {
    final isEditing = tenant != null;
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: tenant?['name']?.toString() ?? '',
    );
    final mobileController = TextEditingController(
      text: tenant?['mobile']?.toString() ?? '',
    );
    final identityController = TextEditingController(
      text: tenant?['identity_number']?.toString() ?? '',
    );
    final identityIssueDateController = TextEditingController(
      text: tenant?['identity_issue_date']?.toString() ?? '',
    );
    final identitySourceController = TextEditingController(
      text: tenant?['identity_source']?.toString() ?? '',
    );
    final professionController = TextEditingController(
      text: tenant?['profession']?.toString() ?? '',
    );
    final initialNationality = tenant?['nationality_id'];
    int? selectedNationalityId = initialNationality is num
        ? initialNationality.toInt()
        : null;
    bool isSaving = false;

    try {
      await showDialog<void>(
        context: parentContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final availableWidth = MediaQuery.sizeOf(context).width;
            return AlertDialog(
              title: Text(
                isEditing ? 'تعديل بيانات المستأجر' : 'إضافة مستأجر جديد',
              ),
              content: SizedBox(
                width: math.min(520, availableWidth * 0.82),
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: nameController,
                          autofocus: !isEditing,
                          decoration: const InputDecoration(
                            labelText: 'الاسم الكامل',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          textInputAction: TextInputAction.next,
                          validator: (value) => value?.trim().isEmpty ?? true
                              ? 'الاسم مطلوب'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: mobileController,
                          decoration: const InputDecoration(
                            labelText: 'رقم الجوال',
                            prefixIcon: Icon(Icons.phone_outlined),
                          ),
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          validator: (value) => value?.trim().isEmpty ?? true
                              ? 'رقم الجوال مطلوب'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: identityController,
                          decoration: const InputDecoration(
                            labelText: 'رقم الهوية',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: identityIssueDateController,
                          decoration: const InputDecoration(
                            labelText: 'تاريخ إصدار الهوية',
                            hintText: 'مثال: 2026-01-31',
                            prefixIcon: Icon(Icons.event_outlined),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: identitySourceController,
                          decoration: const InputDecoration(
                            labelText: 'مصدر الهوية',
                            prefixIcon: Icon(Icons.location_on_outlined),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: professionController,
                          decoration: const InputDecoration(
                            labelText: 'المهنة',
                            prefixIcon: Icon(Icons.work_outline),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        Consumer<LeasingProvider>(
                          builder: (context, provider, _) =>
                              DropdownButtonFormField<int>(
                                initialValue:
                                    provider.nationalities.any(
                                      (item) =>
                                          item['id'] == selectedNationalityId,
                                    )
                                    ? selectedNationalityId
                                    : null,
                                items: provider.nationalities
                                    .map(
                                      (nationality) => DropdownMenuItem<int>(
                                        value: nationality['id'] as int,
                                        child: Text(
                                          nationality['name'].toString(),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: isSaving
                                    ? null
                                    : (value) => setDialogState(
                                        () => selectedNationalityId = value,
                                      ),
                                decoration: const InputDecoration(
                                  labelText: 'الجنسية',
                                  prefixIcon: Icon(Icons.flag_outlined),
                                ),
                              ),
                        ),
                        const SizedBox(height: 12),
                        if (isEditing)
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'رقم الحساب المحاسبي: ${tenant['account_id'] ?? 'غير مرتبط'} — لن يتغير عند تعديل البيانات.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                        else
                          const Text(
                            'سيُنشأ حساب فرعي للمستأجر تلقائيًا عند الحفظ.',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (!(formKey.currentState?.validate() ?? false)) {
                            return;
                          }
                          setDialogState(() => isSaving = true);
                          final values = <String, dynamic>{
                            if (isEditing) 'id': tenant['id'],
                            'name': nameController.text.trim(),
                            'mobile': mobileController.text.trim(),
                            'identity_number': identityController.text.trim(),
                            'identity_issue_date': identityIssueDateController
                                .text
                                .trim(),
                            'identity_source': identitySourceController.text
                                .trim(),
                            'profession': professionController.text.trim(),
                            'nationality_id': selectedNationalityId,
                          };
                          try {
                            final provider = Provider.of<LeasingProvider>(
                              parentContext,
                              listen: false,
                            );
                            if (isEditing) {
                              await provider.updateTenant(values);
                            } else {
                              await provider.addTenant(values);
                            }
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            if (parentContext.mounted) {
                              ScaffoldMessenger.of(parentContext).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isEditing
                                        ? 'تم تحديث بيانات المستأجر مع الحفاظ على حسابه المحاسبي.'
                                        : 'تمت إضافة المستأجر وإنشاء حسابه المحاسبي.',
                                  ),
                                ),
                              );
                            }
                          } catch (error) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => isSaving = false);
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(
                                content: Text('تعذر حفظ البيانات: $error'),
                              ),
                            );
                          }
                        },
                  icon: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(isEditing ? Icons.save_outlined : Icons.add),
                  label: Text(
                    isSaving
                        ? 'جارٍ الحفظ...'
                        : isEditing
                        ? 'حفظ التعديلات'
                        : 'إضافة المستأجر',
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      nameController.dispose();
      mobileController.dispose();
      identityController.dispose();
      identityIssueDateController.dispose();
      identitySourceController.dispose();
      professionController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LeasingProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading && provider.tenants.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final tenants = _visibleTenants(provider.tenants);
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.people_alt_outlined, size: 28),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'إدارة المستأجرين',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: provider.isLoading
                        ? null
                        : provider.loadInitialData,
                    icon: const Icon(Icons.refresh),
                    label: const Text('تحديث'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: provider.isLoading
                        ? null
                        : () => _showTenantDialog(context),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('إضافة مستأجر'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'ابحث بالاسم أو الجوال أو الهوية أو الرقم',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'مسح البحث',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    'المعروض ${tenants.length} من ${provider.tenants.length}',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: tenants.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _searchController.text.isEmpty
                                    ? Icons.people_outline
                                    : Icons.search_off,
                                size: 48,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _searchController.text.isEmpty
                                    ? 'لا توجد سجلات مستأجرين بعد.'
                                    : 'لا توجد نتائج مطابقة للبحث.',
                              ),
                              if (_searchController.text.isEmpty) ...[
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: () => _showTenantDialog(context),
                                  icon: const Icon(Icons.add),
                                  label: const Text('إضافة أول مستأجر'),
                                ),
                              ],
                            ],
                          ),
                        )
                      : Scrollbar(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(
                              child: ErpDataTable(
                                headingRowHeight: 52,
                                dataRowMinHeight: 52,
                                dataRowMaxHeight: 64,
                                columns: const [
                                  DataColumn(label: Text('المعرف')),
                                  DataColumn(label: Text('الاسم')),
                                  DataColumn(label: Text('الجوال')),
                                  DataColumn(label: Text('الهوية')),
                                  DataColumn(label: Text('الحساب المحاسبي')),
                                  DataColumn(label: Text('إجراءات')),
                                ],
                                rows: tenants.map((tenant) {
                                  final id = tenant['id'] as int;
                                  return DataRow(
                                    cells: [
                                      DataCell(Text(id.toString())),
                                      DataCell(
                                        Text(
                                          tenant['name']?.toString() ?? '',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: AppPalette.navy,
                                          ),
                                        ),
                                        onTap: () => _showTenantDialog(
                                          context,
                                          tenant: tenant,
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          tenant['mobile']?.toString() ?? '',
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          tenant['identity_number']
                                                  ?.toString() ??
                                              '—',
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          tenant['account_id']?.toString() ??
                                              '—',
                                        ),
                                      ),
                                      DataCell(
                                        IconButton(
                                          tooltip: 'تعديل بيانات المستأجر',
                                          onPressed: () => _showTenantDialog(
                                            context,
                                            tenant: tenant,
                                          ),
                                          icon: const Icon(Icons.edit_outlined),
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'للتعديل، اضغط على اسم المستأجر أو زر القلم في نهاية الصف. لا يُحذف السجل المالي المرتبط من هذه الشاشة.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
