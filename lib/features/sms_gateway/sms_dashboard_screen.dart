import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/sms_provider.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/reports_provider.dart';
import 'package:intl/intl.dart';

class SmsDashboardScreen extends StatefulWidget {
  const SmsDashboardScreen({super.key});

  @override
  State<SmsDashboardScreen> createState() => _SmsDashboardScreenState();
}

class _SmsDashboardScreenState extends State<SmsDashboardScreen> {
  final _messageController = TextEditingController();
  int? _selectedTenantId;
  String _messagePreview = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LeasingProvider>(context, listen: false).loadInitialData();
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).loadAlertsDashboard();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _updatePreview(String template, Map<String, dynamic> variables) {
    String res = template;
    variables.forEach((key, value) {
      res = res.replaceAll('{${key}}', value.toString());
    });
    setState(() {
      _messagePreview = res;
      _messageController.value = TextEditingValue(
        text: res,
        selection: TextSelection.collapsed(offset: res.length),
      );
    });
  }

  void _generatePreviewForTenant(int tenantId) {
    final leasingProv = Provider.of<LeasingProvider>(context, listen: false);
    final smsProv = Provider.of<SmsProvider>(context, listen: false);
    final tenant = leasingProv.tenants.firstWhere((t) => t['id'] == tenantId);
    final reportProv = Provider.of<ReportsProvider>(context, listen: false);
    final due =
        reportProv.dueInstallments
            .where((item) => item['tenant_id'] == tenantId)
            .toList()
          ..sort(
            (a, b) =>
                a['due_date'].toString().compareTo(b['due_date'].toString()),
          );

    final template =
        smsProv.settings?['reminder_template'] ??
        'عزيزي {اسم_المستأجر}، نود تذكيركم بقسط الإيجار البالغ {المبلغ} والمستحق بتاريخ {تاريخ_الاستحقاق}.';
    if (due.isEmpty) {
      final name = tenant['name']?.toString() ?? '';
      setState(() {
        _messagePreview =
            'مرحباً $name، نرجو التواصل مع إدارة العقار عند الحاجة.';
        _messageController.text = _messagePreview;
      });
      return;
    }
    final installment = due.first;
    final remaining =
        (installment['remaining_amount'] as num?)?.toDouble() ??
        ((installment['amount'] as num).toDouble() -
            (installment['paid_amount'] as num? ?? 0).toDouble());
    _updatePreview(template, {
      'اسم_المستأجر': tenant['name'] ?? '',
      'المبلغ': remaining.toStringAsFixed(2),
      'تاريخ_الاستحقاق': installment['due_date'] ?? '',
    });
  }

  void _sendIndividualMessage() async {
    if (_selectedTenantId == null || _messagePreview.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء اختيار مستأجر والتأكد من نص الرسالة'),
        ),
      );
      return;
    }

    final tenant = Provider.of<LeasingProvider>(
      context,
      listen: false,
    ).tenants.firstWhere((t) => t['id'] == _selectedTenantId);
    final mobile = tenant['mobile'];

    if (mobile == null || mobile.toString().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المستأجر لا يملك رقم جوال مسجل')),
      );
      return;
    }

    try {
      await Provider.of<SmsProvider>(
        context,
        listen: false,
      ).sendMessage(recipientNumber: mobile, messageText: _messagePreview);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('استقبل مزود الرسائل الطلب بنجاح')),
        );
        _messageController.clear();
        setState(() {
          _messagePreview = '';
          _selectedTenantId = null;
        });
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  void _sendBulkReminders() async {
    final smsProv = Provider.of<SmsProvider>(context, listen: false);
    final repProv = Provider.of<ReportsProvider>(context, listen: false);

    if (repProv.dueInstallments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد أقساط متأخرة أو قريبة الاستحقاق'),
        ),
      );
      return;
    }

    int successCount = 0;
    int failedCount = 0;
    final leasingProv = Provider.of<LeasingProvider>(context, listen: false);
    for (var inst in repProv.dueInstallments) {
      // Find tenant mobile
      final tenantId = inst['tenant_id'];
      final tenant = leasingProv.tenants.firstWhere(
        (t) => t['id'] == tenantId,
        orElse: () => {},
      );
      final mobile = tenant['mobile'];

      if (mobile != null && mobile.toString().isNotEmpty) {
        String template =
            smsProv.settings?['reminder_template'] ??
            'عزيزي {اسم_المستأجر}، نود تذكيركم بقسط الإيجار البالغ {المبلغ} والمستحق بتاريخ {تاريخ_الاستحقاق}.';
        String finalMsg = template
            .replaceAll('{اسم_المستأجر}', inst['tenant_name'].toString())
            .replaceAll(
              '{المبلغ}',
              ((inst['remaining_amount'] as num?)?.toDouble() ??
                      ((inst['amount'] as num).toDouble() -
                          (inst['paid_amount'] as num? ?? 0).toDouble()))
                  .toStringAsFixed(2),
            )
            .replaceAll('{تاريخ_الاستحقاق}', inst['due_date'].toString());

        try {
          await smsProv.sendMessage(
            recipientNumber: mobile,
            messageText: finalMsg,
          );
          successCount++;
        } catch (_) {
          failedCount++;
        }
      } else {
        failedCount++;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'قبل المزود $successCount طلباً، وفشل/تعذر $failedCount. تحقق من سجل الرسائل.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, SmsProvider>(
      builder: (context, leasingProv, smsProv, child) {
        if (leasingProv.isLoading || smsProv.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'إرسال رسالة فردية',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: _selectedTenantId,
                      items: leasingProv.tenants
                          .map(
                            (t) => DropdownMenuItem<int>(
                              value: t['id'],
                              child: Text('${t['name']} - ${t['mobile']}'),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        setState(() => _selectedTenantId = val);
                        if (val != null) _generatePreviewForTenant(val);
                      },
                      decoration: const InputDecoration(
                        labelText: 'اختر المستأجر',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.05),
                  border: Border.all(color: Colors.blue.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'معاينة الرسالة النهائية:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _messageController,
                      maxLines: 4,
                      onChanged: (value) =>
                          setState(() => _messagePreview = value),
                      decoration: const InputDecoration(
                        hintText: 'نص الرسالة القابل للتعديل',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _sendIndividualMessage,
                icon: const Icon(Icons.send),
                label: const Text('إرسال الآن'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'الإرسال الجماعي (التنبيهات الذكية)',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إرسال تذكير لجميع المتأخرين',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'سيتم سحب جميع الأقساط التي يحل موعدها خلال 3 أيام أو المتأخرة، وإرسال رسالة SMS تلقائية لهم باستخدام قالب التذكير.',
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: smsProv.isLoading ? null : _sendBulkReminders,
                      icon: const Icon(Icons.group),
                      label: const Text('إرسال للجميع بضغطة زر'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: const EdgeInsets.all(16),
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

class SmsLogsScreen extends StatelessWidget {
  const SmsLogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SmsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'سجل الرسائل المرسلة',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: provider.logs.isEmpty
                    ? const Center(child: Text('لا توجد رسائل مرسلة بعد'))
                    : ListView.builder(
                        itemCount: provider.logs.length,
                        itemBuilder: (context, index) {
                          final log = provider.logs[index];
                          final date = DateTime.parse(log['sent_at']);
                          final formattedDate = DateFormat(
                            'yyyy-MM-dd HH:mm',
                          ).format(date);
                          final accepted = log['status'] == 'Accepted';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: accepted
                                    ? Colors.green
                                    : Colors.red,
                                child: Icon(
                                  accepted ? Icons.check : Icons.error_outline,
                                  color: Colors.white,
                                ),
                              ),
                              title: Text(log['recipient_number']),
                              subtitle: Text(log['message_text']),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    formattedDate,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  Text(
                                    log['status'],
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: accepted
                                          ? Colors.green
                                          : Colors.red,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
