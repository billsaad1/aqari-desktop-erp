import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class SmsProvider with ChangeNotifier {
  Map<String, dynamic>? _settings;
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = false;

  Map<String, dynamic>? get settings => _settings;
  List<Map<String, dynamic>> get logs => _logs;
  bool get isLoading => _isLoading;

  Future<void> loadSmsData() async {
    _isLoading = true;
    notifyListeners();

    _settings = await DatabaseHelper.instance.getSmsSettings();
    _logs = await DatabaseHelper.instance.getAllSmsLogs();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> saveSettings(Map<String, dynamic> newSettings) async {
    await DatabaseHelper.instance.saveSmsSettings(newSettings);
    await loadSmsData();
  }

  Future<void> sendMockMessage({
    required String recipientNumber,
    required String messageText,
  }) async {
    _isLoading = true;
    notifyListeners();

    // Simulate network delay
    await Future.delayed(const Duration(seconds: 1));

    final log = {
      'recipient_number': recipientNumber,
      'message_text': messageText,
      'sent_at': DateTime.now().toIso8601String(),
      'status': 'Delivered', // Mock success status
    };

    await DatabaseHelper.instance.insertSmsLog(log);

    await loadSmsData();
  }
}
