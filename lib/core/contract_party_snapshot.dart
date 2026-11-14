import 'dart:convert';

/// Immutable party/property values captured when a lease contract is created.
/// Legacy contracts without a snapshot continue to use their linked master data.
class ContractPartySnapshot {
  ContractPartySnapshot._();

  static Map<String, dynamic> decode(Map<String, dynamic> contract) {
    final value = contract['party_snapshot'];
    if (value is! String || value.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const {};
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return const {};
    }
  }

  static Map<String, dynamic> section(
    Map<String, dynamic> snapshot,
    String key,
  ) {
    final value = snapshot[key];
    if (value is! Map) return const {};
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static String? tenantName(Map<String, dynamic> contract) {
    final value = section(decode(contract), 'tenant')['name'];
    if (value is! String || value.trim().isEmpty) return null;
    return value;
  }
}
