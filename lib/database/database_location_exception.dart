class DatabaseLocationException implements Exception {
  const DatabaseLocationException({
    required this.message,
    this.legacyPath,
    this.activePath,
  });

  final String message;
  final String? legacyPath;
  final String? activePath;

  @override
  String toString() => message;
}
