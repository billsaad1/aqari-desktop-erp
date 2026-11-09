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
          _currentUser = user;

          // Log audit
          await DatabaseHelper.instance.insertAuditLog({
            'user_id': user.id,
            'action': 'LOGIN',
            'details': 'تم تسجيل الدخول بنجاح',
            'timestamp': DateTime.now().toIso8601String(),
          });

          _isLoading = false;
          notifyListeners();
          return true;
        }
      }
      _errorMessage = 'اسم المستخدم أو كلمة المرور غير صحيحة';
    } catch (e) {
      _errorMessage = 'حدث خطأ أثناء تسجيل الدخول: \$e';
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    if (_currentUser != null) {
      await DatabaseHelper.instance.insertAuditLog({
        'user_id': _currentUser!.id,
        'action': 'LOGOUT',
        'details': 'تم تسجيل الخروج',
        'timestamp': DateTime.now().toIso8601String(),
      });
    }
    _currentUser = null;
    notifyListeners();
  }
}
