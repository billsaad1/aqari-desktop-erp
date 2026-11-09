import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/property_provider.dart';
import 'owners_screen.dart';
import 'properties_screen.dart';

class PropertyMainScreen extends StatefulWidget {
  const PropertyMainScreen({super.key});

  @override
  State<PropertyMainScreen> createState() => _PropertyMainScreenState();
}

class _PropertyMainScreenState extends State<PropertyMainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
            Tab(text: 'العقارات والوحدات'),
            Tab(text: 'الملاك'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              PropertiesScreen(),
              OwnersScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
