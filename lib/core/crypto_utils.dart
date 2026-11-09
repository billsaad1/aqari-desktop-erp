import 'dart:convert';
import 'package:crypto/crypto.dart';

class CryptoUtils {
  /// Hashes a given string using SHA-256 and returns the hex encoded result.
  static String hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Verifies if a given plain text password matches a given hashed password.
  static bool verifyPassword(String password, String hashedPassword) {
    return hashPassword(password) == hashedPassword;
  }
}
