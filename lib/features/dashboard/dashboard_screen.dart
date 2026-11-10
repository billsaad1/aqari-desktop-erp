import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/hover_card.dart';
import '../../database/database_helper.dart';
import '../../providers/navigation_provider.dart';

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
    setState(() => _isLoading = true);
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر تحميل مؤشرات لوحة المعلومات: $error';
        _isLoading = false;
      });
    }
  }

  int _count(String key) => (_summary[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    color: AppPalette.danger,
                    size: 38,
                  ),
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _loadStats,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final countFormat = NumberFormat.decimalPattern('ar_SA');
    final moneyFormat = NumberFormat('#,##0.00', 'ar_SA');
    final outstanding =
        (_summary['outstanding_amount'] as num?)?.toDouble() ?? 0;
    final items =
        <
          ({
            String title,
            String value,
            String? detail,
            IconData icon,
            Color color,
            int destination,
          })
        >[
          (
            title: 'العقارات',
            value: countFormat.format(_count('properties_count')),
            detail: 'إجمالي العقارات المسجلة',
            icon: Icons.apartment_rounded,
            color: AppPalette.navy,
            destination: 3,
          ),
          (
            title: 'إجمالي الوحدات',
            value: countFormat.format(_count('units_count')),
            detail: 'وحدة في سجل العقارات',
            icon: Icons.home_work_outlined,
            color: AppPalette.navy,
            destination: 3,
          ),
          (
            title: 'الوحدات المؤجرة',
            value: countFormat.format(_count('rented_units_count')),
            detail: 'وحدة مرتبطة بعقد',
            icon: Icons.key_rounded,
            color: AppPalette.emerald,
            destination: 3,
          ),
          (
            title: 'الوحدات الشاغرة',
            value: countFormat.format(_count('vacant_units_count')),
            detail: 'وحدة متاحة للتأجير',
            icon: Icons.meeting_room_outlined,
            color: const Color(0xFFB7791F),
            destination: 3,
          ),
          (
            title: 'المستأجرون',
            value: countFormat.format(_count('tenants_count')),
            detail: 'إجمالي المستأجرين المسجلين',
            icon: Icons.people_alt_outlined,
            color: AppPalette.emerald,
            destination: 4,
          ),
          (
            title: 'العقود النشطة',
            value: countFormat.format(_count('active_contracts_count')),
            detail: 'عقد إيجار ساري',
            icon: Icons.description_outlined,
            color: AppPalette.navy,
            destination: 4,
          ),
          (
            title: 'المبالغ المستحقة',
            value: moneyFormat.format(outstanding),
            detail: _currency,
            icon: Icons.account_balance_wallet_outlined,
            color: AppPalette.danger,
            destination: 5,
          ),
        ];

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(28, 24, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'لوحة المعلومات',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: AppPalette.navy,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'نظرة سريعة على العقارات والوحدات والتحصيلات',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppPalette.mutedText,
                      ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: 'تحديث المؤشرات',
                child: IconButton.filledTonal(
                  onPressed: _loadStats,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1420
                    ? 4
                    : constraints.maxWidth >= 980
                    ? 3
                    : constraints.maxWidth >= 650
                    ? 2
                    : 1;
                return GridView.builder(
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 18,
                    childAspectRatio: columns == 1 ? 3.4 : 2.12,
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
    ({
      String title,
      String value,
      String? detail,
      IconData icon,
      Color color,
      int destination,
    })
    item,
  ) {
    return HoverCard(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 18),
      onTap: () =>
          context.read<NavigationProvider>().setIndex(item.destination),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(item.icon, size: 27, color: item.color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: AppPalette.mutedText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  item.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: item.title == 'المبالغ المستحقة'
                        ? item.color
                        : AppPalette.deepNavy,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (item.detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    item.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppPalette.mutedText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.arrow_outward_rounded,
            size: 17,
            color: AppPalette.mutedText.withValues(alpha: 0.7),
          ),
        ],
      ),
    );
  }
}
