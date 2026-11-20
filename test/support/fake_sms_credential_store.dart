import 'package:app/core/sms_credential_store.dart';

class FakeSmsCredentialStore implements SmsCredentialStore {
  final Map<String, String> values = {};
  bool failReads = false;
  bool failWrites = false;
  bool failDeletes = false;
  Future<void> Function(String credentialId)? afterRead;

  @override
  Future<String?> read(String credentialId) async {
    if (failReads) throw StateError('fake secure read failure');
    final value = values[credentialId];
    await afterRead?.call(credentialId);
    return value;
  }

  @override
  Future<void> write(String credentialId, String value) async {
    if (failWrites) throw StateError('fake secure write failure');
    values[credentialId] = value;
  }

  @override
  Future<void> delete(String credentialId) async {
    if (failDeletes) throw StateError('fake secure delete failure');
    values.remove(credentialId);
  }
}
