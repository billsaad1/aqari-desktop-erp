import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/sms_provider.dart';
import 'sms_settings_screen.dart';
import 'sms_dashboard_screen.dart';

class SmsMainScreen extends StatefulWidget {
  const SmsMainScreen({super.key});

  @override
  State<SmsMainScreen> createState() => _SmsMainScreenState();
}

class _SmsMainScreenState extends State<SmsMainScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late final bool _canConfigure;

  @override
  void initState() {
    super.initState();
    final role = Provider.of<AuthProvider>(
      context,
      listen: false,
    ).currentUser?.role;
    _canConfigure = role == 'SuperAdmin' || role == 'Admin';
    _tabController = TabController(length: _canConfigure ? 3 : 2, vsync: this);
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
    final tabs = <Widget>[
      const Tab(text: 'إرسال رسالة'),
      const Tab(text: 'سجل الرسائل'),
      if (_canConfigure) const Tab(text: 'إعدادات وقوالب SMS'),
    ];
    final pages = <Widget>[
      const SmsDashboardScreen(),
      const SmsLogsScreen(),
      if (_canConfigure) const SmsSettingsScreen(),
    ];

    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Colors.blue,
          unselectedLabelColor: Colors.grey,
          tabs: tabs,
        ),
        Expanded(
          child: TabBarView(controller: _tabController, children: pages),
        ),
      ],
    );
  }
}
