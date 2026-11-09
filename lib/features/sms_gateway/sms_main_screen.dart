import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/sms_provider.dart';
import 'sms_settings_screen.dart';
import 'sms_dashboard_screen.dart';

class SmsMainScreen extends StatefulWidget {
  const SmsMainScreen({super.key});

  @override
  State<SmsMainScreen> createState() => _SmsMainScreenState();
}

class _SmsMainScreenState extends State<SmsMainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<SmsProvider>(context, listen: false).loadSmsData();
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
          labelColor: Colors.blue,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'إرسال رسالة'),
            Tab(text: 'سجل الرسائل'),
            Tab(text: 'إعدادات وقوالب الـ SMS'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              SmsDashboardScreen(),
              SmsLogsScreen(),
              SmsSettingsScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
