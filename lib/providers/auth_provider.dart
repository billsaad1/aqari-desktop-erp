import 'dart:async';

import 'package:flutter/material.dart';
import '../models/user_model.dart';
import '../database/database_helper.dart';
import '../core/crypto_utils.dart';
import '../core/permission_policy.dart';

class AuthProvider with ChangeNotifier {
  User? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _sessionRefreshTimer;
  bool _isRefreshingSession = false;
  int _sessionGeneration = 0;
  bool _disposed = false;
  String? _sessionPasswordHash;

  User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  bool get isAuthenticated => _currentUser != null;

  bool canAccessScreen(String module) =>
      PermissionRuntime.allows(module, AppPermissionAction.view);

  bool canPerform(String module, AppPermissionAction action) =>
      PermissionRuntime.allows(module, action);

  bool _isCurrentGeneration(int generation) =>
      !_disposed && generation == _sessionGeneration;

  Future<bool> login(String username, String password) async {
    if (_disposed) return false;
    final generation = ++_sessionGeneration;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _currentUser = null;
    _sessionPasswordHash = null;
    PermissionRuntime.clear();
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final userMap = await DatabaseHelper.instance
          .getAuthenticationRecordByUsername(username);
      if (!_isCurrentGeneration(generation)) return false;
      if (userMap != null) {
        final passwordHash = userMap['password_hash']?.toString() ?? '';
        final user = User.fromMap(userMap);
        if (CryptoUtils.verifyPassword(password, passwordHash)) {
          if (!user.isActive) {
            _errorMessage = 'هذا الحساب موقوف. تواصل مع مدير النظام.';
          } else {
            if (user.id == null) throw StateError('معرف المستخدم غير صالح');
            PermissionRuntime.activate(
              userId: user.id,
              role: user.role,
              permissionRows: [
                for (final module in AppPermissionCatalog.modules)
                  {
                    'screen_name': module.code,
                    'can_view': false,
                    'can_add': false,
                    'can_edit': false,
                    'can_delete': false,
                    'can_print': false,
                    'can_post': false,
                  },
              ],
            );
            final permissions = await DatabaseHelper.instance
                .getUserPermissionsForAuthentication(user.id!);
            if (!_isCurrentGeneration(generation)) return false;
            PermissionRuntime.activate(
              userId: user.id,
              role: user.role,
              permissionRows: permissions,
            );
            _currentUser = user;
            _sessionPasswordHash = passwordHash;
            await DatabaseHelper.instance.recordAuthenticationAudit(
              expectedUserId: user.id!,
              isLogin: true,
            );
            if (!_isCurrentGeneration(generation) ||
                _currentUser?.id != user.id) {
              return false;
            }

            if (CryptoUtils.isLegacyHash(passwordHash)) {
              final upgradedHash = CryptoUtils.hashPassword(password);
              await DatabaseHelper.instance.updateUserPassword(
                user.id!,
                upgradedHash,
                mustChangePassword: user.mustChangePassword,
              );
              if (!_isCurrentGeneration(generation) ||
                  _currentUser?.id != user.id) {
                return false;
              }
              _sessionPasswordHash = upgradedHash;
            }

            _startSessionValidation();

            _isLoading = false;
            notifyListeners();
            return true;
          }
        }
      }
      _errorMessage ??= 'اسم المستخدم أو كلمة المرور غير صحيحة';
    } catch (_) {
      if (!_isCurrentGeneration(generation)) return false;
      _currentUser = null;
      _sessionPasswordHash = null;
      PermissionRuntime.clear();
      _errorMessage =
          'تعذر إتمام تسجيل الدخول. تحقق من قاعدة البيانات أو تواصل مع المسؤول.';
    }

    if (!_isCurrentGeneration(generation)) return false;
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    final user = _currentUser;
    final auditFuture = user?.id != null
        ? DatabaseHelper.instance.recordAuthenticationAudit(
            expectedUserId: user!.id!,
            isLogin: false,
          )
        : null;
    _sessionGeneration++;
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = null;
    _currentUser = null;
    _sessionPasswordHash = null;
    PermissionRuntime.clear();
    _isLoading = false;
    if (!_disposed) notifyListeners();
    if (auditFuture != null) {
      try {
        await auditFuture;
      } catch (_) {
        // Always clear the local session even when audit storage is unavailable.
      }
    }
  }

  Future<void> refreshCurrentUserPermissions({int? expectedGeneration}) async {
    final generation = expectedGeneration ?? _sessionGeneration;
    final user = _currentUser;
    final passwordHash = _sessionPasswordHash;
    if (user == null || user.id == null || passwordHash == null) return;
    final isValid = await DatabaseHelper.instance.isUserSessionValid(
      userId: user.id!,
      expectedRole: user.role,
      expectedPasswordHash: passwordHash,
    );
    if (_disposed ||
        generation != _sessionGeneration ||
        _currentUser?.id != user.id) {
      return;
    }
    if (!isValid) {
      if (generation != _sessionGeneration || _currentUser?.id != user.id) {
        return;
      }
      await logout();
      return;
    }
    final permissions = await DatabaseHelper.instance
        .getUserPermissionsForAuthentication(user.id!);
    if (_disposed ||
        generation != _sessionGeneration ||
        _currentUser?.id != user.id) {
      return;
    }
    PermissionRuntime.activate(
      userId: user.id,
      role: user.role,
      permissionRows: permissions,
    );
    if (!_disposed) notifyListeners();
  }

  void _startSessionValidation() {
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_refreshSessionSafely());
    });
  }

  Future<void> _refreshSessionSafely() async {
    final userId = _currentUser?.id;
    if (userId == null || _isRefreshingSession || _disposed) return;
    final generation = _sessionGeneration;
    _isRefreshingSession = true;
    try {
      await refreshCurrentUserPermissions(expectedGeneration: generation);
    } catch (_) {
      if (!_disposed &&
          generation == _sessionGeneration &&
          _currentUser?.id == userId) {
        await logout();
      }
    } finally {
      _isRefreshingSession = false;
    }
  }

  Future<void> changePassword(String newPassword) async {
    if (_disposed) throw StateError('جلسة الدخول غير متاحة');
    final generation = ++_sessionGeneration;
    final user = _currentUser;
    if (user == null || user.id == null)
      throw StateError('لا توجد جلسة مستخدم صالحة');
    if (newPassword.length < 12)
      throw ArgumentError('كلمة المرور يجب ألا تقل عن 12 حرفاً');

    final passwordHash = CryptoUtils.hashPassword(newPassword);
    await DatabaseHelper.instance.updateUserPassword(user.id!, passwordHash);
    if (!_isCurrentGeneration(generation) || _currentUser?.id != user.id)
      return;
    _sessionPasswordHash = passwordHash;
    _currentUser = User(
      id: user.id,
      username: user.username,
      fullName: user.fullName,
      role: user.role,
      cashBoxAccountId: user.cashBoxAccountId,
      mustChangePassword: false,
    );
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _sessionRefreshTimer?.cancel();
    _sessionPasswordHash = null;
    if (_currentUser != null) {
      _currentUser = null;
      PermissionRuntime.clear();
    }
    super.dispose();
  }
}
