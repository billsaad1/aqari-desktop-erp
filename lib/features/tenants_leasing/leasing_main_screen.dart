import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/property_provider.dart';
import 'tenants_screen.dart';
import 'contracts_screen.dart';

class LeasingMainScreen extends StatefulWidget {
  const LeasingMainScreen({super.key});

  @override
  State<LeasingMainScreen> createState() => _LeasingMainScreenState();
}

class _LeasingMainScreenState extends State<LeasingMainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LeasingProvider>(context, listen: false).loadInitialData();
      Provider.of<PropertyProvider>(context, listen: false).loadInitialData();
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
            Tab(text: 'إدارة المستأجرين'),
            Tab(text: 'عقود الإيجار والتسكين'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              TenantsScreen(),
              ContractsScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
