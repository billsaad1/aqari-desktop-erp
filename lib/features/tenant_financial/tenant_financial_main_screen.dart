import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'package:provider/provider.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import 'tenant_receipt_screen.dart';
import 'tenant_payment_screen.dart';
import 'tax_invoice_screen.dart';

class TenantFinancialMainScreen extends StatefulWidget {
  const TenantFinancialMainScreen({super.key});

  @override
  State<TenantFinancialMainScreen> createState() =>
      _TenantFinancialMainScreenState();
}

class _TenantFinancialMainScreenState extends State<TenantFinancialMainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LeasingProvider>(context, listen: false).loadInitialData();
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
    });
  }

  @override
  void dispose() {
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
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              TenantReceiptScreen(),
              TenantPaymentScreen(),
              TaxInvoiceScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
