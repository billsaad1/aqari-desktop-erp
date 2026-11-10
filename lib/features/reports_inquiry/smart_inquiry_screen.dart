import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'package:provider/provider.dart';
import '../../providers/reports_provider.dart';

class SmartInquiryScreen extends StatelessWidget {
  const SmartInquiryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'الاستعلام السريع',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            decoration: const InputDecoration(
              labelText: 'بحث بالاسم، الجوال، أو رقم الشقة...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (val) {
              if (val.length >= 3) {
                Provider.of<ReportsProvider>(
                  context,
                  listen: false,
                ).search(val);
              } else if (val.isEmpty) {
                Provider.of<ReportsProvider>(context, listen: false).search('');
              }
            },
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Consumer<ReportsProvider>(
              builder: (context, provider, child) {
                if (provider.isLoading)
                  return const Center(child: CircularProgressIndicator());
                if (provider.searchResults.isEmpty)
                  return const Center(child: Text('لا توجد نتائج مطابقة'));

                return ListView.builder(
                  itemCount: provider.searchResults.length,
                  itemBuilder: (context, index) {
                    final res = provider.searchResults[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              res['tenant_name'] ?? 'غير معروف',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.navy,
                              ),
                            ),
                            Text('الجوال: ${res['mobile'] ?? ''}'),
                            const Divider(),
                            Text(
                              'العقار: ${res['property_name']} - الشقة/الوحدة: ${res['unit_number']}',
                            ),
                            Text(
                              'حالة العقد: ${res['contract_status']} | رقم العقد: ${res['contract_id']}',
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'إجمالي العقد: ${res['total_amount'] ?? 0.0}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'المدفوع: ${res['paid_amount'] ?? 0.0}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                                Text(
                                  'المتبقي: ${(res['total_amount'] ?? 0.0) - (res['paid_amount'] ?? 0.0)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
