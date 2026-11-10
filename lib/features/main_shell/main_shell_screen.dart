import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/company_logo_mark.dart';
import '../../providers/auth_provider.dart';
import '../../providers/navigation_provider.dart';
import '../auth/login_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../general_accounting/accounting_main_screen.dart';
import '../master_data/lookups_screen.dart';
import '../properties_owners/property_main_screen.dart';
import '../reports_inquiry/reports_main_screen.dart';
import '../sms_gateway/sms_main_screen.dart';
import '../system_services/system_services_screen.dart';
import '../system_settings/system_settings_screen.dart';
import '../tenant_financial/tenant_financial_main_screen.dart';
import '../tenant_financial/voucher_history_screen.dart';
import '../tenants_leasing/leasing_main_screen.dart';

class MainShellScreen extends StatelessWidget {
  const MainShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            const AppSidebar(),
            Expanded(
              child: Consumer<NavigationProvider>(
                builder: (context, nav, child) {
                  final user = context.watch<AuthProvider>().currentUser;
                  final role = user?.role ?? '';
                  final canAccess = _canAccessScreen(role, nav.currentIndex);
                  if (!canAccess) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) nav.reset();
                    });
                  }
                  final index = canAccess ? nav.currentIndex : 0;
                  return Column(
                    children: [
                      _DesktopTopBar(
                        title: _screenTitle(index),
                        userName: user?.fullName ?? '',
                        role: role,
                      ),
                      Expanded(child: _getScreenForIndex(index)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canAccessScreen(String role, int index) {
    final admin = role == 'SuperAdmin' || role == 'Admin';
    final accountant = role == 'Accountant';
    final dataEntry = role == 'DataEntry';
    switch (index) {
      case 0:
        return role.isNotEmpty;
      case 9:
        return admin;
      case 1:
        return role == 'SuperAdmin';
      case 2:
      case 3:
        return admin || dataEntry;
      case 4:
        return admin || accountant || dataEntry;
      case 5:
      case 6:
      case 7:
      case 8:
      case 10:
        return admin || accountant;
      default:
        return false;
    }
  }

  String _screenTitle(int index) {
    return switch (index) {
      0 => 'الرئيسية',
      1 => 'إعدادات النظام',
      2 => 'الإضافات والبيانات الأساسية',
      3 => 'العقارات والملاك',
      4 => 'المستأجرون وعقود الإيجار',
      5 => 'العمليات المالية للمستأجرين',
      6 => 'الحسابات العامة',
      7 => 'التقارير والاستعلامات',
      8 => 'الرسائل النصية',
      9 => 'خدمات البرنامج',
      10 => 'سجل السندات',
      _ => 'نظام إدارة العقارات',
    };
  }

  Widget _getScreenForIndex(int index) {
    return switch (index) {
      0 => const DashboardScreen(),
      1 => const SystemSettingsScreen(),
      2 => const LookupsScreen(),
      3 => const PropertyMainScreen(),
      4 => const LeasingMainScreen(),
      5 => const TenantFinancialMainScreen(),
      6 => const AccountingMainScreen(),
      7 => const ReportsMainScreen(),
      8 => const SmsMainScreen(),
      9 => const SystemServicesScreen(),
      10 => const VoucherHistoryScreen(),
      _ => const DashboardScreen(),
    };
  }
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({
    required this.title,
    required this.userName,
    required this.role,
  });

  final String title;
  final String userName;
  final String role;

  String _roleLabel(String value) => switch (value) {
    'SuperAdmin' => 'المشرف الأعلى',
    'Admin' => 'مدير النظام',
    'Accountant' => 'محاسب',
    'DataEntry' => 'مدخل بيانات',
    _ => 'مستخدم',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final avatarLetter = userName.trim().isEmpty
        ? 'م'
        : userName.trim().characters.first;

    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border(
          bottom: BorderSide(color: AppPalette.outline.withValues(alpha: 0.7)),
        ),
      ),
      padding: const EdgeInsetsDirectional.fromSTEB(28, 0, 28, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'نظام إدارة العقارات',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppPalette.mutedText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppPalette.navy,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: AppPalette.surfaceTint,
              border: Border.all(
                color: AppPalette.outline.withValues(alpha: 0.7),
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppPalette.emerald.withValues(alpha: 0.12),
                  child: Text(
                    avatarLetter,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppPalette.emeraldDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        userName.isEmpty ? 'مستخدم النظام' : userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _roleLabel(role),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppPalette.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final navProvider = Provider.of<NavigationProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    return Container(
      width: 270,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppPalette.deepNavy, AppPalette.navy],
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x1A10263D),
            blurRadius: 18,
            offset: Offset(-4, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(22, 25, 22, 20),
            child: Row(
              children: [
                CompanyLogoMark(
                  key: ValueKey(navProvider.currentIndex),
                  size: 48,
                  iconColor: Colors.white,
                  backgroundColor: AppPalette.emerald.withValues(alpha: 0.22),
                  radius: 15,
                  padding: 7,
                ),
                const SizedBox(width: 13),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'مؤسسة عبدالله النقيب',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'إدارة العقارات والمحاسبة',
                        style: TextStyle(
                          color: Color(0xFFC4D2DF),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
            child: Divider(color: Colors.white.withValues(alpha: 0.12)),
          ),
          Expanded(
            child: Consumer<AuthProvider>(
              builder: (context, auth, child) {
                final role = auth.currentUser?.role ?? '';
                final isSuperOrAdmin = role == 'SuperAdmin' || role == 'Admin';
                final isAccountant = role == 'Accountant';
                final isDataEntry = role == 'DataEntry';

                return ListView(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 14),
                  children: [
                    _sectionLabel(context, 'مساحة العمل'),
                    _buildNavItem(
                      context,
                      'الرئيسية',
                      Icons.grid_view_rounded,
                      0,
                      navProvider,
                    ),
                    if (role == 'SuperAdmin')
                      _buildNavItem(
                        context,
                        'إعدادات النظام',
                        Icons.settings_outlined,
                        1,
                        navProvider,
                      ),
                    if (isSuperOrAdmin || isDataEntry)
                      _buildNavItem(
                        context,
                        'البيانات الأساسية',
                        Icons.tune_rounded,
                        2,
                        navProvider,
                      ),
                    if (isSuperOrAdmin || isDataEntry)
                      _buildNavItem(
                        context,
                        'العقارات والملاك',
                        Icons.location_city_rounded,
                        3,
                        navProvider,
                      ),
                    if (isSuperOrAdmin || isAccountant || isDataEntry)
                      _buildNavItem(
                        context,
                        'المستأجرون والعقود',
                        Icons.people_alt_rounded,
                        4,
                        navProvider,
                      ),
                    if (isSuperOrAdmin || isAccountant) ...[
                      _buildNavItem(
                        context,
                        'العمليات المالية',
                        Icons.payments_outlined,
                        5,
                        navProvider,
                      ),
                      _buildNavItem(
                        context,
                        'سجل السندات',
                        Icons.receipt_long_rounded,
                        10,
                        navProvider,
                      ),
                      _buildNavItem(
                        context,
                        'الحسابات العامة',
                        Icons.account_balance_wallet_outlined,
                        6,
                        navProvider,
                      ),
                      _buildNavItem(
                        context,
                        'التقارير',
                        Icons.insert_chart_outlined_rounded,
                        7,
                        navProvider,
                      ),
                      _buildNavItem(
                        context,
                        'الرسائل النصية',
                        Icons.mark_chat_unread_outlined,
                        8,
                        navProvider,
                      ),
                    ],
                    if (isSuperOrAdmin) ...[
                      const SizedBox(height: 14),
                      _sectionLabel(context, 'إدارة النظام'),
                      _buildNavItem(
                        context,
                        'خدمات البرنامج',
                        Icons.build_circle_outlined,
                        9,
                        navProvider,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 14),
            child: Column(
              children: [
                Divider(color: Colors.white.withValues(alpha: 0.12)),
                ListTile(
                  mouseCursor: SystemMouseCursors.click,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  hoverColor: Colors.white.withValues(alpha: 0.08),
                  leading: Icon(
                    Icons.logout_rounded,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                  title: const Text(
                    'تسجيل الخروج',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () async {
                    await authProvider.logout();
                    navProvider.reset();
                    if (context.mounted) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 7),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF9FB3C8),
          letterSpacing: 0.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    String title,
    IconData icon,
    int index,
    NavigationProvider provider,
  ) {
    final isSelected = provider.currentIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        selected: isSelected,
        selectedTileColor: AppPalette.emerald.withValues(alpha: 0.25),
        hoverColor: Colors.white.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(
          icon,
          color: isSelected
              ? const Color(0xFF7BE0BF)
              : Colors.white.withValues(alpha: 0.78),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        trailing: isSelected
            ? Container(
                width: 3,
                height: 22,
                decoration: BoxDecoration(
                  color: const Color(0xFF7BE0BF),
                  borderRadius: BorderRadius.circular(3),
                ),
              )
            : null,
        onTap: () => provider.setIndex(index),
      ),
    );
  }
}
