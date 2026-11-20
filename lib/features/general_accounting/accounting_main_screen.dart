import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'chart_of_accounts_screen.dart';
import 'journal_entry_screen.dart';
import 'general_voucher_screen.dart';
import 'owner_settlement_screen.dart';

class AccountingMainScreen extends StatefulWidget {
  const AccountingMainScreen({super.key});

  @override
  State<AccountingMainScreen> createState() => _AccountingMainScreenState();
}

class _AccountingMainScreenState extends State<AccountingMainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
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
            Tab(text: 'دليل الحسابات'),
            Tab(text: 'قيد يومية يدوي'),
            Tab(text: 'سند قبض عام'),
            Tab(text: 'سند صرف عام'),
            Tab(text: 'سداد مستحقات المالك'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              ChartOfAccountsScreen(),
              JournalEntryScreen(),
              GeneralVoucherScreen(voucherType: 'قبض عام'),
              GeneralVoucherScreen(voucherType: 'صرف عام'),
              OwnerSettlementScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
