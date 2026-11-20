import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores SMS provider credentials outside the SQLite database.
///
/// On Windows the platform implementation encrypts values and protects its
/// encryption key through Windows Credential Manager. This only protects data
/// at rest; code running as the same Windows user can still request the value.
abstract interface class SmsCredentialStore {
  Future<String?> read(String credentialId);

  Future<void> write(String credentialId, String value);

  Future<void> delete(String credentialId);
}

class PlatformSmsCredentialStore implements SmsCredentialStore {
  PlatformSmsCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyPrefix = 'aqari_erp.sms.api_key.v1.';
  final FlutterSecureStorage _storage;

  String _key(String credentialId) => '$_keyPrefix$credentialId';

  @override
  Future<String?> read(String credentialId) =>
      _storage.read(key: _key(credentialId));

  @override
  Future<void> write(String credentialId, String value) =>
      _storage.write(key: _key(credentialId), value: value);

  @override
  Future<void> delete(String credentialId) =>
      _storage.delete(key: _key(credentialId));
}

class SmsCredentialStoreRegistry {
  SmsCredentialStoreRegistry._();

  static final SmsCredentialStore _platformStore = PlatformSmsCredentialStore();
  static SmsCredentialStore? _testOverride;

  static SmsCredentialStore get instance => _testOverride ?? _platformStore;

  @visibleForTesting
  static set overrideForTesting(SmsCredentialStore? store) {
    _testOverride = store;
  }
}
