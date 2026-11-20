import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/permission_policy.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import 'tenant_receipt_screen.dart';
import 'tenant_payment_screen.dart';
import 'tax_invoice_screen.dart';
import 'credit_note_screen.dart';

class TenantFinancialMainScreen extends StatefulWidget {
  const TenantFinancialMainScreen({super.key});

  @override
  State<TenantFinancialMainScreen> createState() =>
      _TenantFinancialMainScreenState();
}

class _TenantFinancialMainScreenState extends State<TenantFinancialMainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late AuthProvider _authProvider;
  String _permissionFingerprint = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _authProvider = Provider.of<AuthProvider>(context, listen: false);
    _permissionFingerprint = _currentPermissionFingerprint();
    _authProvider.addListener(_onAuthPermissionsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reloadFinancialData();
    });
  }

  String _currentPermissionFingerprint() {
    final user = _authProvider.currentUser;
    final permissions = [
      for (final module in AppPermissionCatalog.modules)
        for (final action in AppPermissionAction.values)
          '${module.code}:${action.name}:${PermissionRuntime.allows(module.code, action)}',
    ];
    return '${user?.id}:${user?.role}:${permissions.join('|')}';
  }

  void _onAuthPermissionsChanged() {
    if (!mounted) return;
    final nextFingerprint = _currentPermissionFingerprint();
    if (nextFingerprint == _permissionFingerprint) return;
    _permissionFingerprint = nextFingerprint;
    _reloadFinancialData();
  }

  void _reloadFinancialData() {
    Provider.of<LeasingProvider>(context, listen: false).loadInitialData();
    Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
  }

  @override
  void dispose() {
    _authProvider.removeListener(_onAuthPermissionsChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: AppPalette.navy,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'قبض مستأجر (تحصيل)'),
            Tab(text: 'صرف مستأجر (رد مبالغ)'),
            Tab(text: 'إصدار فاتورة ضريبية'),
            Tab(text: 'إشعار دائن'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              TenantReceiptScreen(),
              TenantPaymentScreen(),
              TaxInvoiceScreen(),
              CreditNoteScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
