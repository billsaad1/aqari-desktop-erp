import 'package:flutter/foundation.dart';

enum AppPermissionAction { view, add, edit, delete, print, post, reviewApprove }

extension AppPermissionActionDetails on AppPermissionAction {
  String get databaseColumn => switch (this) {
    AppPermissionAction.view => 'can_view',
    AppPermissionAction.add => 'can_add',
    AppPermissionAction.edit => 'can_edit',
    AppPermissionAction.delete => 'can_delete',
    AppPermissionAction.print => 'can_print',
    AppPermissionAction.post => 'can_post',
    AppPermissionAction.reviewApprove => 'can_review_approve',
  };

  String get arabicLabel => switch (this) {
    AppPermissionAction.view => 'العرض',
    AppPermissionAction.add => 'الإضافة',
    AppPermissionAction.edit => 'التعديل',
    AppPermissionAction.delete => 'الحذف',
    AppPermissionAction.print => 'الطباعة',
    AppPermissionAction.post => 'الترحيل',
    AppPermissionAction.reviewApprove => 'مراجعة واعتماد طلب البيع',
  };
}

class AppPermissionModule {
  const AppPermissionModule(this.code, this.label);

  final String code;
  final String label;
}

class AppPermissionCatalog {
  AppPermissionCatalog._();

  static const modules = <AppPermissionModule>[
    AppPermissionModule('dashboard', 'الرئيسية'),
    AppPermissionModule('system_settings', 'إعدادات النظام والمستخدمون'),
    AppPermissionModule('lookups', 'البيانات الأساسية'),
    AppPermissionModule('properties', 'العقارات والملاك والوحدات'),
    AppPermissionModule('property_sales', 'مراجعة بيع العقار والوحدة'),
    AppPermissionModule('leasing', 'المستأجرون وعقود الإيجار'),
    AppPermissionModule('notices', 'إشعارات المستأجرين'),
    AppPermissionModule('tenant_financial', 'العمليات المالية للمستأجرين'),
    AppPermissionModule('accounting', 'الحسابات العامة والقيود'),
    AppPermissionModule('reports', 'التقارير والاستعلامات'),
    AppPermissionModule('sms', 'الرسائل النصية'),
    AppPermissionModule('system_services', 'خدمات البرنامج'),
    AppPermissionModule('voucher_history', 'سجل السندات'),
  ];

  static final Map<String, AppPermissionModule> _byCode = {
    for (final module in modules) module.code: module,
  };

  static AppPermissionModule? module(String code) => _byCode[code];

  static String? codeForNavigationIndex(int index) => switch (index) {
    0 => 'dashboard',
    1 => 'system_settings',
    2 => 'lookups',
    3 => 'properties',
    4 => 'leasing',
    5 => 'tenant_financial',
    6 => 'accounting',
    7 => 'reports',
    8 => 'sms',
    9 => 'system_services',
    10 => 'voucher_history',
    11 => 'notices',
    12 => 'property_sales',
    _ => null,
  };

  static bool roleAllows(
    String role,
    String module,
    AppPermissionAction action,
  ) {
    if (role == 'SuperAdmin') return true;
    if (!_roleAllowsView(role, module)) return false;
    if (action == AppPermissionAction.view) return true;
    if (action == AppPermissionAction.reviewApprove) {
      return role == 'Accountant' && module == 'property_sales';
    }

    if (role == 'Admin') return true;
    if (role == 'DataEntry') {
      return switch (action) {
        AppPermissionAction.add || AppPermissionAction.edit => const {
          'lookups',
          'properties',
          'property_sales',
          'leasing',
        }.contains(module),
        AppPermissionAction.print => module == 'leasing',
        AppPermissionAction.view ||
        AppPermissionAction.delete ||
        AppPermissionAction.post ||
        AppPermissionAction.reviewApprove => false,
      };
    }
    if (role == 'Accountant') {
      return switch (module) {
        'leasing' => const {
          AppPermissionAction.add,
          AppPermissionAction.edit,
          AppPermissionAction.print,
        }.contains(action),
        'property_sales' => const {
          AppPermissionAction.add,
          AppPermissionAction.edit,
          AppPermissionAction.print,
        }.contains(action),
        'tenant_financial' || 'accounting' => const {
          AppPermissionAction.add,
          AppPermissionAction.edit,
          AppPermissionAction.print,
          AppPermissionAction.post,
        }.contains(action),
        'reports' || 'voucher_history' => action == AppPermissionAction.print,
        'sms' => action == AppPermissionAction.add,
        'notices' => const {
          AppPermissionAction.add,
          AppPermissionAction.edit,
          AppPermissionAction.print,
          AppPermissionAction.post,
        }.contains(action),
        _ => false,
      };
    }
    return false;
  }

  static bool _roleAllowsView(String role, String module) {
    if (role == 'SuperAdmin') return true;
    return switch (role) {
      'Admin' => module != 'system_settings',
      'Accountant' => const {
        'dashboard',
        'leasing',
        'notices',
        'property_sales',
        'tenant_financial',
        'accounting',
        'reports',
        'sms',
        'voucher_history',
      }.contains(module),
      'DataEntry' => const {
        'dashboard',
        'lookups',
        'properties',
        'property_sales',
        'leasing',
      }.contains(module),
      _ => false,
    };
  }
}

/// Current-session authorization. A module-specific database row overrides
/// that module's role defaults; absent rows retain backward-compatible defaults.
class PermissionRuntime {
  PermissionRuntime._();

  /// Changes when the active user or effective permission map changes.
  /// Long-lived previews listen to this to redact stale data immediately.
  static final ValueNotifier<int> authorizationRevision = ValueNotifier(0);

  static int? _userId;
  static String? _role;
  static Map<String, Map<AppPermissionAction, bool>> _overrides = {};

  static int? get userId => _userId;
  static String? get role => _role;
  static bool get hasSession => _role != null;

  static void activate({
    required int? userId,
    required String role,
    required Iterable<Map<String, dynamic>> permissionRows,
  }) {
    final previousUserId = _userId;
    final previousRole = _role;
    final previousOverrides = _overrides;
    _userId = userId;
    _role = role;
    final overrides = <String, Map<AppPermissionAction, bool>>{};
    for (final row in permissionRows) {
      final code = row['screen_name']?.toString();
      if (code == null || AppPermissionCatalog.module(code) == null) continue;
      final rowPermissions = {
        for (final action in AppPermissionAction.values)
          action: _asBool(row[action.databaseColumn]),
      };
      final previous = overrides[code];
      overrides[code] = previous == null
          ? rowPermissions
          : {
              for (final action in AppPermissionAction.values)
                action:
                    previous[action] == true && rowPermissions[action] == true,
            };
    }
    _overrides = overrides;
    if (previousUserId != _userId ||
        previousRole != _role ||
        !_sameOverrides(previousOverrides, _overrides)) {
      authorizationRevision.value++;
    }
  }

  static void clear() {
    final changed = _userId != null || _role != null || _overrides.isNotEmpty;
    _userId = null;
    _role = null;
    _overrides = {};
    if (changed) authorizationRevision.value++;
  }

  static bool allows(String module, AppPermissionAction action) {
    final role = _role;
    if (role == null || AppPermissionCatalog.module(module) == null) {
      return false;
    }
    if (role == 'SuperAdmin') return true;
    final custom = _overrides[module];
    if (custom != null) {
      if (action != AppPermissionAction.view &&
          custom[AppPermissionAction.view] != true) {
        return false;
      }
      return custom[action] ?? false;
    }
    return AppPermissionCatalog.roleAllows(role, module, action);
  }

  static void require(String module, AppPermissionAction action) {
    if (!allows(module, action)) {
      final moduleName = AppPermissionCatalog.module(module)?.label ?? module;
      throw StateError('لا تملك صلاحية ${action.arabicLabel} في $moduleName');
    }
  }

  static bool _sameOverrides(
    Map<String, Map<AppPermissionAction, bool>> left,
    Map<String, Map<AppPermissionAction, bool>> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      final other = right[entry.key];
      if (other == null || entry.value.length != other.length) return false;
      for (final action in AppPermissionAction.values) {
        if (entry.value[action] != other[action]) return false;
      }
    }
    return true;
  }

  static bool _asBool(Object? value) =>
      value == true || (value is num && value.toInt() == 1);
}
