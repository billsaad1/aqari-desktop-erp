import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/sms_provider.dart';

class SmsSettingsScreen extends StatefulWidget {
  const SmsSettingsScreen({super.key});

  @override
  State<SmsSettingsScreen> createState() => _SmsSettingsScreenState();
}

class _SmsSettingsScreenState extends State<SmsSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _apiUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _senderNameController = TextEditingController();
  final _reminderTemplateController = TextEditingController(text: 'عزيزي {اسم_المستأجر}، نود تذكيركم بقسط الإيجار البالغ {المبلغ} والمستحق بتاريخ {تاريخ_الاستحقاق}.');
  final _receiptTemplateController = TextEditingController(text: 'تم استلام مبلغ {المبلغ} ريال بسند رقم {رقم_السند}. شكراً لكم.');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSettings();
    });
  }

  void _loadSettings() {
    final prov = Provider.of<SmsProvider>(context, listen: false);
    if (prov.settings != null) {
      _apiUrlController.text = prov.settings!['api_url'] ?? '';
      _apiKeyController.text = prov.settings!['api_key'] ?? '';
      _senderNameController.text = prov.settings!['sender_name'] ?? '';
      _reminderTemplateController.text = prov.settings!['reminder_template'] ?? _reminderTemplateController.text;
      _receiptTemplateController.text = prov.settings!['receipt_template'] ?? _receiptTemplateController.text;
    }
  }

  void _saveSettings() async {
    if (_formKey.currentState!.validate()) {
      await Provider.of<SmsProvider>(context, listen: false).saveSettings({
        'api_url': _apiUrlController.text,
        'api_key': _apiKeyController.text,
        'sender_name': _senderNameController.text,
        'reminder_template': _reminderTemplateController.text,
        'receipt_template': _receiptTemplateController.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الإعدادات بنجاح')));
      }
    }
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _apiKeyController.dispose();
    _senderNameController.dispose();
    _reminderTemplateController.dispose();
    _receiptTemplateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: ListView(
          children: [
            const Text('إعدادات مزود خدمة الرسائل (API)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiUrlController,
              decoration: const InputDecoration(labelText: 'مسار الـ API (URL)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'مفتاح الربط (API Key / Token)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _senderNameController,
              decoration: const InputDecoration(labelText: 'اسم المرسل (Sender Name)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 32),
            const Text('قوالب الرسائل الجاهزة (Templates)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('ملاحظة: يمكنك استخدام المتغيرات التالية بين أقواس معقوفة: {اسم_المستأجر}, {المبلغ}, {تاريخ_الاستحقاق}, {رقم_السند}', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _reminderTemplateController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'قالب تذكير بالأقساط المتأخرة', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _receiptTemplateController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'قالب تأكيد استلام الدفعة', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saveSettings,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
              child: const Text('حفظ الإعدادات', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}
