import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'smart_inquiry_screen.dart';
import 'occupancy_report_screen.dart';
import 'account_statement_screen.dart';
import 'property_unit_inquiry_screen.dart';
import 'owner_statement_screen.dart';
import 'tenant_statement_screen.dart';
import 'trial_balance_screen.dart';
import 'income_expense_report_screen.dart';
import 'tenant_collection_report_screen.dart';
import 'invoice_ledger_reconciliation_screen.dart';

class ReportsMainScreen extends StatefulWidget {
  const ReportsMainScreen({super.key});

  @override
  State<ReportsMainScreen> createState() => _ReportsMainScreenState();
}

class _ReportsMainScreenState extends State<ReportsMainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 10, vsync: this);
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
          isScrollable: true,
          labelColor: AppPalette.navy,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'الاستعلام السريع'),
            Tab(text: 'تقرير الإشغال والشواغر'),
            Tab(text: 'استعلام العقار والوحدات'),
            Tab(text: 'التقارير المحاسبية (كشف الحساب)'),
            Tab(text: 'كشف حساب المستأجر'),
            Tab(text: 'كشف حساب المالك'),
            Tab(text: 'ميزان المراجعة'),
            Tab(text: 'حركة الإيرادات والمصروفات'),
            Tab(text: 'تحصيل المستأجرين'),
            Tab(text: 'مطابقة الفواتير والقيود'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              SmartInquiryScreen(),
              OccupancyReportScreen(),
              PropertyUnitInquiryScreen(),
              AccountStatementScreen(),
              TenantStatementScreen(),
              OwnerStatementScreen(),
              TrialBalanceScreen(),
              IncomeExpenseReportScreen(),
              TenantCollectionReportScreen(),
              InvoiceLedgerReconciliationScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
