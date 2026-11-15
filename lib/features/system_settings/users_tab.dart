import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/crypto_utils.dart';
import '../../core/erp_data_table.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';
import '../../providers/auth_provider.dart';

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = true;

  static const _roleLabels = {
    'SuperAdmin': 'مدير النظام الأعلى',
    'Admin': 'مدير',
    'Accountant': 'محاسب',
    'DataEntry': 'مدخل بيانات',
  };

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await DatabaseHelper.instance.getAllUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تحميل المستخدمين: $error')));
    }
  }

  Future<void> _showAddUserDialog() async {
    final formKey = GlobalKey<FormState>();
    final fullNameController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final auth = context.read<AuthProvider>();
    final currentRole = auth.currentUser?.role ?? '';
    var selectedRole = 'DataEntry';
    final roles = [
      if (currentRole == 'SuperAdmin') 'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    ];

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('إضافة مستخدم جديد'),
            content: SizedBox(
              width: 520,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: fullNameController,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الكامل',
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : 'الاسم الكامل مطلوب',
                    ),
                    TextFormField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : 'اسم المستخدم مطلوب',
                    ),
                    TextFormField(
                      controller: passwordController,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور الأولية',
                        helperText: '12 حرفًا على الأقل',
                      ),
                      obscureText: true,
                      validator: (value) => (value?.length ?? 0) >= 12
                          ? null
                          : 'كلمة المرور يجب ألا تقل عن 12 حرفًا',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      decoration: const InputDecoration(
                        labelText: 'الدور الافتراضي',
                      ),
                      items: roles
                          .map(
                            (role) => DropdownMenuItem(
                              value: role,
                              child: Text('${_roleLabels[role]} ($role)'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedRole = value);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'يمكن تخصيص صلاحيات كل شاشة وإجراء من زر الدرع بعد إنشاء الحساب.',
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
                  if (!formKey.currentState!.validate()) return;
                  try {
                    await DatabaseHelper.instance.insertUser({
                      'full_name': fullNameController.text.trim(),
                      'username': usernameController.text.trim(),
                      'password_hash': CryptoUtils.hashPassword(
                        passwordController.text,
                      ),
                      'role': selectedRole,
                    });
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _loadUsers();
                  } catch (error) {
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('تعذر إنشاء المستخدم: $error')),
                    );
                  }
                },
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('إنشاء الحساب'),
              ),
            ],
          ),
        ),
      );
    } finally {
      fullNameController.dispose();
      usernameController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> _showEditUserDialog(Map<String, dynamic> user) async {
    final id = (user['id'] as num).toInt();
    final formKey = GlobalKey<FormState>();
    final fullNameController = TextEditingController(
      text: user['full_name']?.toString() ?? '',
    );
    final usernameController = TextEditingController(
      text: user['username']?.toString() ?? '',
    );
    final auth = context.read<AuthProvider>();
    final currentUserId = auth.currentUser?.id;
    final currentRole = auth.currentUser?.role ?? '';
    final oldRole = user['role']?.toString() ?? 'DataEntry';
    final mayEditRole =
        id != currentUserId &&
        (currentRole == 'SuperAdmin' || oldRole != 'SuperAdmin');
    var selectedRole = oldRole;
    final roles = [
      if (currentRole == 'SuperAdmin') 'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    ];

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text('تعديل المستخدم: ${user['full_name']}'),
            content: SizedBox(
              width: 520,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: fullNameController,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الكامل',
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : 'الاسم الكامل مطلوب',
                    ),
                    TextFormField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : 'اسم المستخدم مطلوب',
                    ),
                    if (mayEditRole) ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selectedRole,
                        decoration: const InputDecoration(
                          labelText: 'الدور الافتراضي',
                        ),
                        items: roles
                            .map(
                              (role) => DropdownMenuItem(
                                value: role,
                                child: Text('${_roleLabels[role]} ($role)'),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedRole = value);
                          }
                        },
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          'الدور الحالي: ${_roleLabels[oldRole] ?? oldRole}',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  try {
                    await DatabaseHelper.instance.updateUser({
                      'id': id,
                      'full_name': fullNameController.text.trim(),
                      'username': usernameController.text.trim(),
                      if (mayEditRole) 'role': selectedRole,
                    });
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _loadUsers();
                  } catch (error) {
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('تعذر تعديل المستخدم: $error')),
                    );
                  }
                },
                child: const Text('حفظ التعديل'),
              ),
            ],
          ),
        ),
      );
    } finally {
      fullNameController.dispose();
      usernameController.dispose();
    }
  }

  Future<void> _setUserActive(
    Map<String, dynamic> user, {
    required bool isActive,
  }) async {
    final id = (user['id'] as num).toInt();
    final name = user['full_name']?.toString() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isActive ? 'تفعيل الحساب' : 'إيقاف الحساب'),
        content: Text(
          isActive
              ? 'سيتمكن $name من تسجيل الدخول واستخدام الصلاحيات الممنوحة له.'
              : 'لن يتمكن $name من تسجيل الدخول بعد الإيقاف. سيبقى سجل المستخدم والتدقيق محفوظًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isActive ? 'تفعيل الحساب' : 'إيقاف الحساب'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await DatabaseHelper.instance.setUserActive(id, isActive);
      if (!mounted) return;
      await _loadUsers();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isActive ? 'تم تفعيل الحساب.' : 'تم إيقاف الحساب.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تغيير حالة الحساب: $error')));
    }
  }

  Future<void> _showPermissionsDialog(Map<String, dynamic> user) async {
    final userId = (user['id'] as num).toInt();
    final role = user['role']?.toString() ?? '';
    final storedRows = await DatabaseHelper.instance.getUserPermissions(userId);
    if (!mounted) return;

    final existing = {
      for (final row in storedRows) row['screen_name'].toString(): row,
    };
    final values = <String, Map<AppPermissionAction, bool>>{};
    for (final module in AppPermissionCatalog.modules) {
      final row = existing[module.code];
      values[module.code] = {
        for (final action in AppPermissionAction.values)
          action: row == null
              ? AppPermissionCatalog.roleAllows(role, module.code, action)
              : _asBool(row[action.databaseColumn]),
      };
    }
    final touchedModules = existing.keys.toSet();
    var resetAll = false;
    var isSaving = false;
    final isSuperAdmin = role == 'SuperAdmin';

    void resetToRoleDefaults(StateSetter setDialogState) {
      setDialogState(() {
        resetAll = true;
        touchedModules.clear();
        for (final module in AppPermissionCatalog.modules) {
          for (final action in AppPermissionAction.values) {
            values[module.code]![action] = AppPermissionCatalog.roleAllows(
              role,
              module.code,
              action,
            );
          }
        }
      });
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('صلاحيات ${user['full_name']}'),
          content: SizedBox(
            width: 980,
            height: 650,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isSuperAdmin
                      ? 'هذا الحساب مدير نظام أعلى؛ جميع الصلاحيات مفتوحة دائمًا ولا يمكن تقليصها من هنا.'
                      : existing.isEmpty
                      ? 'يعرض الجدول افتراضيات الدور «${_roleLabels[role] ?? role}». أي تعديل سيحفظ تخصيصًا لهذا المستخدم فقط.'
                      : 'توجد تخصيصات محفوظة لهذا المستخدم؛ الأقسام التي لا يظهر لها سجل تبقى على افتراضيات الدور.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'الصلاحية الإجرائية تتطلب تفعيل صلاحية العرض للقسم نفسه.',
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: isSuperAdmin || isSaving
                        ? null
                        : () => resetToRoleDefaults(setDialogState),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text(
                      'إزالة كل التخصيصات والعودة لافتراضيات الدور',
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: AppPermissionCatalog.modules.length,
                    itemBuilder: (context, index) {
                      final module = AppPermissionCatalog.modules[index];
                      return ExpansionTile(
                        key: PageStorageKey<String>(
                          'permission-${module.code}',
                        ),
                        title: Text(module.label),
                        subtitle: Text(
                          values[module.code]![AppPermissionAction.view] == true
                              ? 'يمكن عرض هذا القسم'
                              : 'القسم مخفي عن المستخدم',
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(
                              12,
                              0,
                              12,
                              12,
                            ),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final action in AppPermissionAction.values)
                                  SizedBox(
                                    width: 145,
                                    child: CheckboxListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      title: Text(action.arabicLabel),
                                      value:
                                          values[module.code]![action] ?? false,
                                      onChanged: isSuperAdmin || isSaving
                                          ? null
                                          : (value) {
                                              setDialogState(() {
                                                resetAll = false;
                                                touchedModules.add(module.code);
                                                final enabled = value ?? false;
                                                values[module.code]![action] =
                                                    enabled;
                                                if (action ==
                                                        AppPermissionAction
                                                            .view &&
                                                    !enabled) {
                                                  for (final otherAction
                                                      in AppPermissionAction
                                                          .values) {
                                                    values[module
                                                            .code]![otherAction] =
                                                        false;
                                                  }
                                                } else if (action !=
                                                        AppPermissionAction
                                                            .view &&
                                                    enabled) {
                                                  values[module
                                                          .code]![AppPermissionAction
                                                          .view] =
                                                      true;
                                                }
                                              });
                                            },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
            FilledButton.icon(
              onPressed: isSuperAdmin || isSaving
                  ? null
                  : () async {
                      setDialogState(() => isSaving = true);
                      final payload = resetAll
                          ? <Map<String, dynamic>>[]
                          : [
                              for (final module in AppPermissionCatalog.modules)
                                if (touchedModules.contains(module.code))
                                  {
                                    'screen_name': module.code,
                                    for (final action
                                        in AppPermissionAction.values)
                                      action.databaseColumn:
                                          values[module.code]![action] ?? false,
                                  },
                            ];
                      try {
                        await DatabaseHelper.instance.replaceUserPermissions(
                          userId,
                          payload,
                        );
                        final auth = context.read<AuthProvider>();
                        if (auth.currentUser?.id == userId) {
                          await auth.refreshCurrentUserPermissions();
                        }
                        if (!dialogContext.mounted) return;
                        Navigator.pop(dialogContext);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('تم حفظ صلاحيات المستخدم.'),
                            ),
                          );
                        }
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() => isSaving = false);
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text('تعذر حفظ الصلاحيات: $error')),
                        );
                      }
                    },
              icon: const Icon(Icons.save_outlined),
              label: const Text('حفظ الصلاحيات'),
            ),
          ],
        ),
      ),
    );
  }

  bool _asBool(Object? value) =>
      value == true || (value is num && value.toInt() == 1);

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    final auth = context.watch<AuthProvider>();
    final canAdd = auth.canPerform('system_settings', AppPermissionAction.add);
    final canEdit = auth.canPerform(
      'system_settings',
      AppPermissionAction.edit,
    );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'إدارة المستخدمين والصلاحيات',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              FilledButton.icon(
                onPressed: canAdd ? _showAddUserDialog : null,
                icon: const Icon(Icons.add),
                label: const Text('إضافة مستخدم'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'الصلاحيات الفردية تتجاوز افتراضيات الدور للقسم المحدد فقط؛ وتُطبق أيضًا داخل عمليات قاعدة البيانات الأساسية.',
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: ErpDataTable(
                columns: const [
                  DataColumn(label: Text('المعرف')),
                  DataColumn(label: Text('الاسم الكامل')),
                  DataColumn(label: Text('اسم المستخدم')),
                  DataColumn(label: Text('الدور الافتراضي')),
                  DataColumn(label: Text('الحالة')),
                  DataColumn(label: Text('الإجراءات')),
                ],
                rows: _users.map((user) {
                  final role = user['role']?.toString() ?? '';
                  final userId = (user['id'] as num).toInt();
                  final currentUserId = auth.currentUser?.id;
                  final isActive = (user['is_active'] as num?)?.toInt() == 1;
                  final canChangeStatus =
                      canEdit &&
                      userId != currentUserId &&
                      (role != 'SuperAdmin' ||
                          auth.currentUser?.role == 'SuperAdmin');
                  return DataRow(
                    cells: [
                      DataCell(Text(userId.toString())),
                      DataCell(Text(user['full_name']?.toString() ?? '')),
                      DataCell(Text(user['username']?.toString() ?? '')),
                      DataCell(Text(_roleLabels[role] ?? role)),
                      DataCell(
                        Chip(
                          avatar: Icon(
                            isActive ? Icons.check_circle : Icons.pause_circle,
                            size: 18,
                            color: isActive ? Colors.green : Colors.orange,
                          ),
                          label: Text(isActive ? 'نشط' : 'موقوف'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'تعديل بيانات المستخدم',
                              onPressed: canEdit
                                  ? () => _showEditUserDialog(user)
                                  : null,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: userId == currentUserId
                                  ? 'لا يمكن تعديل صلاحيات الحساب الجاري'
                                  : 'إدارة الصلاحيات',
                              onPressed: canEdit && userId != currentUserId
                                  ? () => _showPermissionsDialog(user)
                                  : null,
                              icon: const Icon(Icons.security_outlined),
                            ),
                            IconButton(
                              tooltip: userId == currentUserId
                                  ? 'لا يمكن إيقاف الحساب المستخدم حاليًا'
                                  : isActive
                                  ? 'إيقاف الحساب'
                                  : 'تفعيل الحساب',
                              onPressed: canChangeStatus
                                  ? () => _setUserActive(
                                      user,
                                      isActive: !isActive,
                                    )
                                  : null,
                              icon: Icon(
                                isActive
                                    ? Icons.pause_circle_outline
                                    : Icons.check_circle_outline,
                                color: isActive ? Colors.orange : Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
