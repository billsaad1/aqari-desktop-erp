import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/property_provider.dart';

class OwnersScreen extends StatefulWidget {
  const OwnersScreen({super.key});

  @override
  State<OwnersScreen> createState() => _OwnersScreenState();
}

class _OwnersScreenState extends State<OwnersScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _visibleOwners(List<Map<String, dynamic>> owners) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return owners;
    return owners.where((owner) {
      final searchable = [
        owner['id'],
        owner['name'],
        owner['mobile'],
        owner['identity_number'],
        owner['iban'],
        owner['account_id'],
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Future<void> _showOwnerDialog(
    BuildContext parentContext,
    PropertyProvider provider, {
    Map<String, dynamic>? owner,
  }) async {
    final editing = owner != null;
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: owner?['name']?.toString() ?? '');
    final mobile = TextEditingController(
      text: owner?['mobile']?.toString() ?? '',
    );
    final identity = TextEditingController(
      text: owner?['identity_number']?.toString() ?? '',
    );
    final identityDate = TextEditingController(
      text: owner?['identity_issue_date']?.toString() ?? '',
    );
    final identitySource = TextEditingController(
      text: owner?['identity_source']?.toString() ?? '',
    );
    final iban = TextEditingController(text: owner?['iban']?.toString() ?? '');
    final commission = TextEditingController(
      text: owner?['commission_rate']?.toString() ?? '0',
    );
    var saving = false;

    try {
      await showDialog<void>(
        context: parentContext,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(editing ? 'تعديل بيانات المالك' : 'إضافة مالك جديد'),
            content: SizedBox(
              width: math.min(520, MediaQuery.sizeOf(context).width * 0.82),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'الاسم الكامل',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) => value?.trim().isEmpty ?? true
                            ? 'الاسم مطلوب'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mobile,
                        decoration: const InputDecoration(
                          labelText: 'رقم الجوال',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: identity,
                        decoration: const InputDecoration(
                          labelText: 'رقم الهوية أو السجل',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: identityDate,
                        decoration: const InputDecoration(
                          labelText: 'تاريخ إصدار الهوية',
                          hintText: 'مثال: 2026-01-31',
                          prefixIcon: Icon(Icons.event_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: identitySource,
                        decoration: const InputDecoration(
                          labelText: 'مصدر الهوية',
                          prefixIcon: Icon(Icons.location_on_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: iban,
                        decoration: const InputDecoration(
                          labelText: 'رقم الآيبان',
                          prefixIcon: Icon(Icons.account_balance_outlined),
                        ),
                        keyboardType: TextInputType.text,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: commission,
                        decoration: const InputDecoration(
                          labelText: 'نسبة العمولة (%)',
                          prefixIcon: Icon(Icons.percent),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (value) {
                          final rate = double.tryParse(value?.trim() ?? '');
                          if (rate == null || rate < 0 || rate > 100) {
                            return 'أدخل نسبة من 0 إلى 100';
                          }
                          return null;
                        },
                      ),
                      if (editing) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            'الحساب المحاسبي ${owner['account_id'] ?? 'غير مرتبط'} سيبقى كما هو.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setDialogState(() => saving = true);
                        final values = <String, dynamic>{
                          if (editing) 'id': owner['id'],
                          'name': name.text.trim(),
                          'mobile': mobile.text.trim(),
                          'identity_number': identity.text.trim(),
                          'identity_issue_date': identityDate.text.trim(),
                          'identity_source': identitySource.text.trim(),
                          'iban': iban.text.trim(),
                          'commission_rate': double.parse(commission.text),
                        };
                        try {
                          if (editing) {
                            await provider.updateOwner(values);
                          } else {
                            await provider.addOwner(values);
                          }
                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          if (parentContext.mounted) {
                            ScaffoldMessenger.of(parentContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  editing
                                      ? 'تم تحديث بيانات المالك مع الحفاظ على حسابه.'
                                      : 'تمت إضافة المالك وإنشاء حسابه المحاسبي.',
                                ),
                              ),
                            );
                          }
                        } catch (error) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() => saving = false);
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                              content: Text('تعذر حفظ البيانات: $error'),
                            ),
                          );
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(editing ? Icons.save_outlined : Icons.add),
                label: Text(
                  saving
                      ? 'جارٍ الحفظ...'
                      : editing
                      ? 'حفظ التعديلات'
                      : 'إضافة المالك',
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      name.dispose();
      mobile.dispose();
      identity.dispose();
      identityDate.dispose();
      identitySource.dispose();
      iban.dispose();
      commission.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PropertyProvider>(
      builder: (context, provider, _) {
        if (provider.isLoading && provider.owners.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final owners = _visibleOwners(provider.owners);
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.badge_outlined, size: 28),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'إدارة الملاك',
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
                        : () => _showOwnerDialog(context, provider),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('إضافة مالك'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'ابحث بالاسم أو الجوال أو الهوية أو الآيبان',
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
                  Text('المعروض ${owners.length} من ${provider.owners.length}'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: owners.isEmpty
                      ? Center(
                          child: Text(
                            _searchController.text.isEmpty
                                ? 'لا توجد سجلات ملاك بعد.'
                                : 'لا توجد نتائج مطابقة للبحث.',
                          ),
                        )
                      : Scrollbar(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(
                              child: DataTable(
                                headingRowHeight: 52,
                                dataRowMinHeight: 52,
                                dataRowMaxHeight: 64,
                                columns: const [
                                  DataColumn(label: Text('المعرف')),
                                  DataColumn(label: Text('الاسم')),
                                  DataColumn(label: Text('الجوال')),
                                  DataColumn(label: Text('الحساب المحاسبي')),
                                  DataColumn(label: Text('نسبة العمولة')),
                                  DataColumn(label: Text('إجراءات')),
                                ],
                                rows: owners.map((owner) {
                                  return DataRow(
                                    cells: [
                                      DataCell(Text(owner['id'].toString())),
                                      DataCell(
                                        Text(
                                          owner['name']?.toString() ?? '',
                                          style: const TextStyle(
                                            color: Colors.blue,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        onTap: () => _showOwnerDialog(
                                          context,
                                          provider,
                                          owner: owner,
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          owner['mobile']?.toString() ?? '—',
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          owner['account_id']?.toString() ??
                                              '—',
                                        ),
                                      ),
                                      DataCell(
                                        Text(
                                          '${owner['commission_rate'] ?? 0} %',
                                        ),
                                      ),
                                      DataCell(
                                        IconButton(
                                          tooltip: 'تعديل بيانات المالك',
                                          onPressed: () => _showOwnerDialog(
                                            context,
                                            provider,
                                            owner: owner,
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
                'اضغط على اسم المالك أو زر القلم لتعديل بياناته. لا يمكن حذف الملاك المرتبطين بعقارات من هذه الشاشة.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
