import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/permission_policy.dart';
import 'package:provider/provider.dart';
import '../../database/database_helper.dart';
import '../../providers/auth_provider.dart';
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
  final _reminderTemplateController = TextEditingController(
    text:
        'عزيزي {اسم_المستأجر}، نود تذكيركم بقسط الإيجار البالغ {المبلغ} والمستحق بتاريخ {تاريخ_الاستحقاق}.',
  );
  final _receiptTemplateController = TextEditingController(
    text: 'تم استلام مبلغ {المبلغ} ريال بسند رقم {رقم_السند}. شكراً لكم.',
  );
  bool _obscureApiKey = true;
  bool _isSaving = false;
  late final AuthProvider _authProvider;
  bool _hadEditPermission = false;

  @override
  void initState() {
    super.initState();
    _authProvider = Provider.of<AuthProvider>(context, listen: false);
    _hadEditPermission = _authProvider.canPerform(
      'sms',
      AppPermissionAction.edit,
    );
    _authProvider.addListener(_handleAuthorizationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadEditorSettings());
    });
  }

  void _handleAuthorizationChanged() {
    final canEdit = _authProvider.canPerform('sms', AppPermissionAction.edit);
    if (_hadEditPermission && !canEdit) {
      _apiKeyController.clear();
    } else if (!_hadEditPermission && canEdit) {
      unawaited(_loadEditorSettings());
    }
    _hadEditPermission = canEdit;
  }

  Future<void> _loadEditorSettings() async {
    final userId = _authProvider.currentUser?.id;
    if (!_authProvider.canPerform('sms', AppPermissionAction.edit)) return;
    try {
      final settings = await DatabaseHelper.instance.getSmsSettingsForEditing();
      if (!mounted ||
          !_authProvider.canPerform('sms', AppPermissionAction.edit) ||
          _authProvider.currentUser?.id != userId) {
        return;
      }
      _loadSettings(settings);
    } catch (error) {
      if (mounted &&
          _authProvider.canPerform('sms', AppPermissionAction.edit) &&
          _authProvider.currentUser?.id == userId) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل إعدادات الرسائل: $error')),
        );
      }
    }
  }

  void _loadSettings(Map<String, dynamic>? settings) {
    if (settings == null) return;
    _apiUrlController.text = settings['api_url']?.toString() ?? '';
    _apiKeyController.text = settings['api_key']?.toString() ?? '';
    _senderNameController.text = settings['sender_name']?.toString() ?? '';
    _reminderTemplateController.text =
        settings['reminder_template']?.toString() ??
        _reminderTemplateController.text;
    _receiptTemplateController.text =
        settings['receipt_template']?.toString() ??
        _receiptTemplateController.text;
    setState(() {});
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      await Provider.of<SmsProvider>(context, listen: false).saveSettings({
        'api_url': _apiUrlController.text.trim(),
        'api_key': _apiKeyController.text.trim(),
        'sender_name': _senderNameController.text.trim(),
        'reminder_template': _reminderTemplateController.text,
        'receipt_template': _receiptTemplateController.text,
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ إعدادات مزود الرسائل')),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ الإعدادات: $e')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _authProvider.removeListener(_handleAuthorizationChanged);
    _apiKeyController.clear();
    _apiUrlController.dispose();
    _apiKeyController.dispose();
    _senderNameController.dispose();
    _reminderTemplateController.dispose();
    _receiptTemplateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    if (!auth.canPerform('sms', AppPermissionAction.edit)) {
      return const Center(
        child: Text('لا تملك صلاحية تعديل إعدادات بوابة الرسائل'),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: ListView(
          children: [
            const Text(
              'إعدادات مزود خدمة الرسائل (API)',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'يرسل التطبيق طلب POST بصيغة JSON بالحقول to وmessage وsender، مع ترويسة Authorization: Bearer <API Key>. استخدم HTTPS؛ يسمح بـ HTTP على localhost فقط للاختبار.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'مسار الـ API (URL)',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final uri = Uri.tryParse(value ?? '');
                final valid =
                    uri != null &&
                    uri.host.isNotEmpty &&
                    (uri.scheme == 'https' ||
                        (uri.scheme == 'http' &&
                            [
                              'localhost',
                              '127.0.0.1',
                              '::1',
                            ].contains(uri.host)));
                return !valid
                    ? 'أدخل URL آمنًا يبدأ بـ https:// (أو HTTP محليًا للاختبار)'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: 'مفتاح الربط (API Key / Token)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                  icon: Icon(
                    _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'مفتاح API مطلوب للإرسال'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _senderNameController,
              decoration: const InputDecoration(
                labelText: 'اسم المرسل (Sender Name)',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'اسم المرسل مطلوب'
                  : null,
            ),
            const SizedBox(height: 32),
            const Text(
              'قوالب الرسائل الجاهزة',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'المتغيرات: {اسم_المستأجر}, {المبلغ}, {تاريخ_الاستحقاق}, {رقم_السند}',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _reminderTemplateController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'قالب تذكير بالأقساط المستحقة',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _receiptTemplateController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'قالب تأكيد استلام الدفعة',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isSaving ? null : _saveSettings,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
              child: _isSaving
                  ? const CircularProgressIndicator()
                  : const Text('حفظ الإعدادات', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}
