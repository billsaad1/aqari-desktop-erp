import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../core/permission_policy.dart';

class SmsProvider with ChangeNotifier {
  Map<String, dynamic>? _settings;
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = false;
  String? _errorMessage;
  int _loadGeneration = 0;
  int? _authorizedUserId;
  bool _hadSmsView = false;

  Map<String, dynamic>? get settings => _settings;
  List<Map<String, dynamic>> get logs => _logs;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Called by the app-level auth proxy. SMS logs can contain personal data,
  /// so discard them whenever the session changes or loses sms.view.
  void syncAuthorization({required int? userId, required bool canViewSms}) {
    if (_authorizedUserId != userId || (_hadSmsView && !canViewSms)) {
      clearSensitiveData(notify: false);
    }
    _authorizedUserId = userId;
    _hadSmsView = canViewSms;
  }

  bool _isSecureEndpoint(Uri uri) =>
      uri.host.isNotEmpty &&
      (uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              ['localhost', '127.0.0.1', '::1'].contains(uri.host)));

  String _safeError(Object error) {
    if (error is TimeoutException) return 'انتهت مهلة الاتصال بمزود الرسائل';
    if (error is SocketException) return 'تعذر الاتصال بمزود الرسائل';
    if (error is HttpException &&
        error.message.startsWith('استجاب مزود الرسائل'))
      return error.message;
    if (error is StateError) return error.message;
    return 'تعذر إرسال الرسالة؛ تحقق من إعداد المزود والاتصال';
  }

  Map<String, dynamic>? _publicSettings(Map<String, dynamic>? settings) {
    if (settings == null) return null;
    final safeSettings = Map<String, dynamic>.from(settings);
    safeSettings.remove('api_key');
    safeSettings.remove('api_key_secret_id');
    safeSettings.remove('clear_api_key');
    return safeSettings;
  }

  Future<void> loadSmsData() async {
    final generation = ++_loadGeneration;
    _isLoading = true;
    notifyListeners();
    try {
      final settings = await DatabaseHelper.instance
          .getSmsSettingsForDashboard();
      final logs = await DatabaseHelper.instance.getAllSmsLogs();
      if (generation != _loadGeneration) return;
      _settings = _publicSettings(settings);
      _logs = logs;
      _errorMessage = null;
    } catch (e) {
      if (generation != _loadGeneration) return;
      _settings = null;
      _logs = [];
      _errorMessage = 'تعذر تحميل إعدادات الرسائل وسجلها: $e';
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void clearSensitiveData({bool notify = true}) {
    _loadGeneration++;
    _settings = null;
    _logs = [];
    _isLoading = false;
    _errorMessage = null;
    if (notify) notifyListeners();
  }

  Future<void> saveSettings(Map<String, dynamic> newSettings) async {
    final uri = Uri.tryParse(newSettings['api_url']?.toString() ?? '');
    if (uri == null || !_isSecureEndpoint(uri)) {
      throw ArgumentError(
        'أدخل API آمنًا يبدأ بـ https:// (يسمح بـ http محليًا للاختبار فقط)',
      );
    }
    if ((newSettings['sender_name']?.toString().trim() ?? '').isEmpty) {
      throw ArgumentError('اسم المرسل مطلوب');
    }
    await DatabaseHelper.instance.saveSmsSettings(newSettings);
    _settings = _publicSettings(newSettings);
    if (PermissionRuntime.allows('sms', AppPermissionAction.view)) {
      await loadSmsData();
    } else {
      notifyListeners();
    }
  }

  Future<void> sendMessage({
    required String recipientNumber,
    required String messageText,
  }) async {
    PermissionRuntime.require('sms', AppPermissionAction.add);
    if (recipientNumber.trim().isEmpty || messageText.trim().isEmpty) {
      throw ArgumentError('رقم الجوال ونص الرسالة مطلوبان');
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    HttpClient? client;
    Object? sendError;
    var status = 'Failed';
    final now = DateTime.now().toIso8601String();

    try {
      // Fetch the credential for this request only; never cache it in provider
      // state that survives screen changes or logout.
      final settings = await DatabaseHelper.instance.getSmsSettingsForSending();
      if (settings == null) throw StateError('أكمل إعداد مزود الرسائل أولاً');
      PermissionRuntime.require('sms', AppPermissionAction.add);
      final uri = Uri.tryParse(settings['api_url']?.toString() ?? '');
      if (uri == null || !_isSecureEndpoint(uri)) {
        throw StateError('عنوان مزود الرسائل غير صالح');
      }
      final apiKey = settings['api_key']?.toString().trim() ?? '';
      if (apiKey.isEmpty) throw StateError('مفتاح API غير مضبوط');

      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.add(
        utf8.encode(
          jsonEncode({
            'to': recipientNumber.trim(),
            'message': messageText,
            'sender': settings['sender_name']?.toString() ?? '',
          }),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'استجاب مزود الرسائل بالحالة HTTP ${response.statusCode}',
        );
      }
      status = 'Accepted';
    } catch (e) {
      sendError = e;
      status = 'Failed: ${_safeError(e)}';
      _errorMessage = _safeError(e);
    } finally {
      client?.close(force: true);
      try {
        await DatabaseHelper.instance.insertSmsLog({
          'recipient_number': recipientNumber,
          'message_text': messageText,
          'sent_at': now,
          'status': status,
        });
      } catch (logError) {
        _errorMessage =
            '${_errorMessage ?? 'تم إرسال الطلب'}؛ وتعذر حفظ سجل الرسالة: $logError';
      }
      if (PermissionRuntime.allows('sms', AppPermissionAction.view)) {
        try {
          _logs = await DatabaseHelper.instance.getAllSmsLogs();
        } catch (_) {
          // Keep the current in-memory log list if storage is unavailable.
        }
      }
      _isLoading = false;
      notifyListeners();
    }

    if (sendError != null) throw StateError(_safeError(sendError));
  }
}
