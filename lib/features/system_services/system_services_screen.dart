import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/reports_provider.dart';

class SystemServicesScreen extends StatefulWidget {
  const SystemServicesScreen({super.key});

  @override
  State<SystemServicesScreen> createState() => _SystemServicesScreenState();
}

class _SystemServicesScreenState extends State<SystemServicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ReportsProvider>(context, listen: false).loadAlertsDashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('لوحة التنبيهات والخدمات الذكية', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              Expanded(
                child: Row(
                  children: [
                    // Alerts: Due Installments
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          border: Border.all(color: Colors.orange),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.warning, color: Colors.orange),
                                SizedBox(width: 8),
                                Text('أقساط قريبة الاستحقاق أو متأخرة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange)),
                              ],
                            ),
                            const Divider(),
                            Expanded(
                              child: provider.dueInstallments.isEmpty
                                  ? const Center(child: Text('لا توجد أقساط مستحقة حالياً'))
                                  : ListView.builder(
                                      itemCount: provider.dueInstallments.length,
                                      itemBuilder: (context, index) {
                                        final inst = provider.dueInstallments[index];
                                        return Card(
                                          child: ListTile(
                                            title: Text(inst['tenant_name'] ?? 'غير معروف'),
                                            subtitle: Text('تاريخ الاستحقاق: ${inst['due_date']} | المبلغ: ${inst['amount']}'),
                                            trailing: IconButton(
                                              icon: const Icon(Icons.payment, color: Colors.green),
                                              tooltip: 'الذهاب للتحصيل (تحتاج للتبديل يدوياً لشاشة القبض)',
                                              onPressed: () {
                                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('انتقل إلى عمليات المستأجرين -> قبض مستأجر')));
                                              },
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    // Alerts: Expiring Contracts
                    Expanded(
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          border: Border.all(color: Colors.red),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.time_to_leave, color: Colors.red),
                                SizedBox(width: 8),
                                Text('عقود تنتهي قريباً (خلال 30 يوماً)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red)),
                              ],
                            ),
                            const Divider(),
                            Expanded(
                              child: provider.expiringContracts.isEmpty
                                  ? const Center(child: Text('لا توجد عقود تنتهي قريباً'))
                                  : ListView.builder(
                                      itemCount: provider.expiringContracts.length,
                                      itemBuilder: (context, index) {
                                        final contract = provider.expiringContracts[index];
                                        return Card(
                                          child: ListTile(
                                            title: Text(contract['tenant_name'] ?? 'غير معروف'),
                                            subtitle: Text('تاريخ النهاية: ${contract['end_date']}\nالوحدة: ${contract['unit_number']} - ${contract['property_name']}'),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
