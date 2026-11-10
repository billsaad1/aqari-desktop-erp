import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'smart_inquiry_screen.dart';
import 'occupancy_report_screen.dart';
import 'account_statement_screen.dart';

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
    _tabController = TabController(length: 3, vsync: this);
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
            Tab(text: 'الاستعلام السريع'),
            Tab(text: 'تقرير الإشغال والشواغر'),
            Tab(text: 'التقارير المحاسبية (كشف الحساب)'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              SmartInquiryScreen(),
              OccupancyReportScreen(),
              AccountStatementScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
