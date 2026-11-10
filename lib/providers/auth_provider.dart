import 'package:flutter/material.dart';
import '../models/user_model.dart';
import '../database/database_helper.dart';
import '../core/crypto_utils.dart';

class AuthProvider with ChangeNotifier {
  User? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;

  User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  bool get isAuthenticated => _currentUser != null;

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final userMap = await DatabaseHelper.instance.getUserByUsername(username);
      if (userMap != null) {
        final user = User.fromMap(userMap);
        if (CryptoUtils.verifyPassword(password, user.passwordHash)) {
          await DatabaseHelper.instance.insertAuditLog({
            'user_id': user.id,
            'action': 'LOGIN',
            'details': 'تم تسجيل الدخول بنجاح',
            'timestamp': DateTime.now().toIso8601String(),
          });

          if (CryptoUtils.isLegacyHash(user.passwordHash)) {
            await DatabaseHelper.instance.updateUserPassword(
              user.id!,
              CryptoUtils.hashPassword(password),
              mustChangePassword: user.mustChangePassword,
            );
          }

          _currentUser = user;

          _isLoading = false;
          notifyListeners();
          return true;
        }
      }
      _errorMessage = 'اسم المستخدم أو كلمة المرور غير صحيحة';
    } catch (_) {
      _currentUser = null;
      _errorMessage =
          'تعذر إتمام تسجيل الدخول. تحقق من قاعدة البيانات أو تواصل مع المسؤول.';
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    final user = _currentUser;
    _currentUser = null;
    notifyListeners();
    if (user != null) {
      try {
        await DatabaseHelper.instance.insertAuditLog({
          'user_id': user.id,
          'action': 'LOGOUT',
          'details': 'تم تسجيل الخروج',
          'timestamp': DateTime.now().toIso8601String(),
        });
      } catch (_) {
        // Always clear the local session even when audit storage is unavailable.
      }
    }
  }

  Future<void> changePassword(String newPassword) async {
    final user = _currentUser;
    if (user == null || user.id == null)
      throw StateError('لا توجد جلسة مستخدم صالحة');
    if (newPassword.length < 12)
      throw ArgumentError('كلمة المرور يجب ألا تقل عن 12 حرفاً');

    final passwordHash = CryptoUtils.hashPassword(newPassword);
    await DatabaseHelper.instance.updateUserPassword(user.id!, passwordHash);
    _currentUser = User(
      id: user.id,
      username: user.username,
      passwordHash: passwordHash,
      fullName: user.fullName,
      role: user.role,
      cashBoxAccountId: user.cashBoxAccountId,
      mustChangePassword: false,
    );
    notifyListeners();
  }
}
