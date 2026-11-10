import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../database/database_helper.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic> _summary = {};
  String _currency = 'ريال يمني (YER)';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final summary = await DatabaseHelper.instance.getDashboardSummary();
      final company = await DatabaseHelper.instance.getCompanyInfo();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _currency = company?['default_currency']?.toString() ?? _currency;
        _error = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر تحميل مؤشرات لوحة المعلومات: $e';
        _isLoading = false;
      });
    }
  }

  int _count(String key) => (_summary[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadStats,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    final outstanding =
        (_summary['outstanding_amount'] as num?)?.toDouble() ?? 0;
    final money = NumberFormat('#,##0.00', 'en_US').format(outstanding);
    final items = <({String title, String value, IconData icon, Color color})>[
      (
        title: 'العقارات',
        value: '${_count('properties_count')}',
        icon: Icons.apartment,
        color: Colors.blue,
      ),
      (
        title: 'إجمالي الوحدات',
        value: '${_count('units_count')}',
        icon: Icons.home_work,
        color: Colors.indigo,
      ),
      (
        title: 'الوحدات المؤجرة',
        value: '${_count('rented_units_count')}',
        icon: Icons.key,
        color: Colors.green,
      ),
      (
        title: 'الوحدات الشاغرة',
        value: '${_count('vacant_units_count')}',
        icon: Icons.meeting_room,
        color: Colors.orange,
      ),
      (
        title: 'المستأجرون',
        value: '${_count('tenants_count')}',
        icon: Icons.people,
        color: Colors.teal,
      ),
      (
        title: 'العقود النشطة',
        value: '${_count('active_contracts_count')}',
        icon: Icons.description,
        color: Colors.purple,
      ),
      (
        title: 'المبالغ المستحقة',
        value: '$money\n$_currency',
        icon: Icons.account_balance_wallet,
        color: Colors.red,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'لوحة المعلومات',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: _loadStats,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1100
                    ? 3
                    : constraints.maxWidth >= 700
                    ? 2
                    : 1;
                return GridView.builder(
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: columns == 1 ? 3.2 : 2.2,
                  ),
                  itemBuilder: (context, index) => _buildStatCard(items[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    ({String title, String value, IconData icon, Color color}) item,
  ) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(item.icon, size: 28, color: item.color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(fontSize: 15, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.value,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
