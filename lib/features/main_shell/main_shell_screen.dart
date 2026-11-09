import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/auth_provider.dart';
import '../auth/login_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../system_settings/system_settings_screen.dart';
import '../master_data/lookups_screen.dart';
import '../general_accounting/accounting_main_screen.dart';
import '../properties_owners/property_main_screen.dart';
import '../tenants_leasing/leasing_main_screen.dart';
import '../tenant_financial/tenant_financial_main_screen.dart';
import '../reports_inquiry/reports_main_screen.dart';
import '../system_services/system_services_screen.dart';
import '../sms_gateway/sms_main_screen.dart';

class MainShellScreen extends StatelessWidget {
  const MainShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          const AppSidebar(),
          // Main Content
          Expanded(
            child: Consumer<NavigationProvider>(
              builder: (context, nav, child) {
                return _getScreenForIndex(nav.currentIndex);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _getScreenForIndex(int index) {
    switch (index) {
      case 0:
        return const DashboardScreen();
      case 1:
        return const SystemSettingsScreen();
      case 2:
        return const LookupsScreen();
      case 3:
        return const PropertyMainScreen();
      case 4:
        return const LeasingMainScreen();
      case 5:
        return const TenantFinancialMainScreen();
      case 6:
        return const AccountingMainScreen();
      case 7:
        return const ReportsMainScreen();
      case 8:
        return const SmsMainScreen();
      case 9:
        return const SystemServicesScreen();
      default:
        return const DashboardScreen();
    }
  }
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final navProvider = Provider.of<NavigationProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    return Container(
      width: 250,
      color: Colors.blue.shade900,
      child: Column(
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.business, size: 64, color: Colors.white),
          const SizedBox(height: 16),
          const Text(
            'مؤسسة عبدالله النقيب',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: Consumer<AuthProvider>(
              builder: (context, auth, _) {
                final role = auth.currentUser?.role ?? '';
                final isSuperOrAdmin = role == 'SuperAdmin' || role == 'Admin';
                final isAccountant = role == 'Accountant';
                final isDataEntry = role == 'DataEntry';

                return ListView(
                  children: [
                    _buildNavItem(context, 'الرئيسية', Icons.dashboard, 0, navProvider),
                    if (isSuperOrAdmin)
                      _buildNavItem(context, 'إعدادات النظام', Icons.settings, 1, navProvider),
                    if (isSuperOrAdmin || isDataEntry)
                      _buildNavItem(context, 'الإضافات', Icons.list_alt, 2, navProvider),
                    if (isSuperOrAdmin || isDataEntry)
                      _buildNavItem(context, 'العقار والملاك', Icons.location_city, 3, navProvider),
                    if (isSuperOrAdmin || isAccountant || isDataEntry)
                      _buildNavItem(context, 'المستأجرين', Icons.people, 4, navProvider), // All can see, functionality depends on screen inner RBAC, but DataEntry & Accountant need it
                    if (isSuperOrAdmin || isAccountant)
                      _buildNavItem(context, 'عمليات المستأجرين', Icons.monetization_on, 5, navProvider),
                    if (isSuperOrAdmin || isAccountant)
                      _buildNavItem(context, 'الحسابات', Icons.account_balance_wallet, 6, navProvider),
                    if (isSuperOrAdmin || isAccountant)
                      _buildNavItem(context, 'التقارير', Icons.bar_chart, 7, navProvider),
                    if (isSuperOrAdmin || isAccountant)
                      _buildNavItem(context, 'الرسائل النصية', Icons.message, 8, navProvider),
                    if (isSuperOrAdmin)
                      _buildNavItem(context, 'خدمات البرنامج', Icons.build, 9, navProvider),
                  ],
                );
              },
            ),
          ),
          const Divider(color: Colors.white54),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.white),
            title: const Text('تسجيل الخروج', style: TextStyle(color: Colors.white)),
            onTap: () async {
              await authProvider.logout();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              }
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, String title, IconData icon, int index, NavigationProvider provider) {
    final isSelected = provider.currentIndex == index;
    return Container(
      color: isSelected ? Colors.blue.shade700 : Colors.transparent,
      child: ListTile(
        leading: Icon(icon, color: Colors.white),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        onTap: () {
          provider.setIndex(index);
        },
      ),
    );
  }
}
