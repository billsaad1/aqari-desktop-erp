import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class CryptoUtils {
  static const int _iterations = 120000;
  static const int _keyLength = 32;

  /// PBKDF2-HMAC-SHA256 with a unique random salt for each password.
  static String hashPassword(String password) {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final derived = _pbkdf2(
      utf8.encode(password),
      salt,
      _iterations,
      _keyLength,
    );
    return 'pbkdf2_sha256\$$_iterations\$${base64Url.encode(salt)}\$${base64Url.encode(derived)}';
  }

  /// Supports legacy SHA-256 only so existing accounts can be migrated on login.
  static bool verifyPassword(String password, String hashedPassword) {
    if (!hashedPassword.startsWith('pbkdf2_sha256\$')) {
      final legacy = sha256.convert(utf8.encode(password)).toString();
      return _constantTimeEquals(
        utf8.encode(legacy),
        utf8.encode(hashedPassword),
      );
    }

    try {
      final parts = hashedPassword.split('\$');
      if (parts.length != 4 || parts[0] != 'pbkdf2_sha256') return false;
      final iterations = int.parse(parts[1]);
      if (iterations < 10000 || iterations > 1000000) return false;
      final salt = base64Url.decode(base64Url.normalize(parts[2]));
      final expected = base64Url.decode(base64Url.normalize(parts[3]));
      final actual = _pbkdf2(
        utf8.encode(password),
        salt,
        iterations,
        expected.length,
      );
      return _constantTimeEquals(actual, expected);
    } catch (_) {
      return false;
    }
  }

  static bool isLegacyHash(String hash) => !hash.startsWith('pbkdf2_sha256\$');

  static List<int> _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int length,
  ) {
    final hmac = Hmac(sha256, password);
    final blocks = (length / 32).ceil();
    final derived = BytesBuilder(copy: false);

    for (var block = 1; block <= blocks; block++) {
      final blockIndex = <int>[
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      var u = hmac.convert([...salt, ...blockIndex]).bytes;
      final accumulator = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < accumulator.length; j++) {
          accumulator[j] ^= u[j];
        }
      }
      derived.add(accumulator);
    }
    return derived.takeBytes().sublist(0, length);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}
