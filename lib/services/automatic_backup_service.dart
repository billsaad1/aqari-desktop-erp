import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database_helper.dart';

/// Performs app-owned local backups while an authenticated app session is open.
///
/// The desktop app does not run in the background after it is closed. If a daily
/// backup becomes due while the app is closed, it is created after the next
/// successful login. By default, backups live in the application's support
/// directory; an administrator may configure local and removable destinations
/// in System Settings.
class AutomaticBackupService {
  AutomaticBackupService._();

  static final AutomaticBackupService instance = AutomaticBackupService._();

  static const enabledKey = 'automatic_backup_enabled';
  static const retentionKey = 'automatic_backup_retention_count';
  static const lastSuccessKey = 'automatic_backup_last_success_ms';
  static const lastSuccessByPathKey = 'automatic_backup_success_by_path';
  static const lastAttemptKey = 'automatic_backup_last_attempt_ms';
  static const lastPathsKey = 'automatic_backup_last_paths';
  static const lastErrorKey = 'automatic_backup_last_error';
  static const filePrefix = 'aqari_auto_backup_';
  static const defaultRetentionCount = 14;
  static const _interval = Duration(hours: 24);

  Timer? _pollTimer;
  bool _started = false;
  bool _running = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // Avoid doing a potentially expensive SQLite VACUUM during first paint.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 30), () async {
        if (_started) await _runIfDue();
      }),
    );
    _pollTimer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(_runIfDue());
    });
  }

  Future<void> stop() async {
    _started = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Requests a backup after the administrator explicitly enables automation.
  Future<void> runNow() => _runIfDue(force: true);

  Future<void> _runIfDue({bool force = false}) async {
    if (_running) return;
    _running = true;
    try {
      late final SharedPreferences prefs;
      try {
        prefs = await SharedPreferences.getInstance();
      } catch (error, stackTrace) {
        debugPrint(
          'Automatic backup preferences unavailable: $error\n$stackTrace',
        );
        return;
      }
      if (!(prefs.getBool(enabledKey) ?? true)) return;

      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      final directories = await _backupDirectories(prefs);
      final successfulAtByPath = _decodeSuccessMap(
        prefs.getString(lastSuccessByPathKey),
      )..removeWhere((path, _) => !directories.contains(path));
      final dueDirectories = dueBackupDirectories(
        directories: directories,
        successfulAtMsByPath: successfulAtByPath,
        now: now,
        force: force,
      );
      if (dueDirectories.isEmpty) return;

      final successes = <String>[];
      final failures = <String>[];
      await prefs.setInt(lastAttemptKey, now.millisecondsSinceEpoch);
      final retention = (prefs.getInt(retentionKey) ?? defaultRetentionCount)
          .clamp(1, 90)
          .toInt();
      for (final directoryPath in dueDirectories) {
        final targetPath = p.join(
          directoryPath,
          '$filePrefix${_timestamp(now)}.db',
        );
        try {
          await DatabaseHelper.instance.createAutomaticBackupSnapshot(
            targetPath,
          );
          successes.add(targetPath);
          successfulAtByPath[directoryPath] = nowMs;
          try {
            await pruneAutoBackups(
              Directory(directoryPath),
              keepNewest: retention,
            );
          } catch (error) {
            failures.add('تعذر تطبيق سياسة الاحتفاظ في $directoryPath: $error');
          }
        } catch (error) {
          failures.add('$directoryPath: $error');
        }
      }

      await prefs.setString(
        lastSuccessByPathKey,
        jsonEncode(successfulAtByPath),
      );
      if (successes.isNotEmpty) {
        await prefs.setInt(lastSuccessKey, nowMs);
        await prefs.setString(lastPathsKey, successes.join('\n'));
      }
      if (failures.isEmpty) {
        await prefs.remove(lastErrorKey);
      } else {
        await prefs.setString(lastErrorKey, failures.join('\n'));
      }
    } catch (error, stackTrace) {
      debugPrint('Automatic backup failed: $error\n$stackTrace');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(lastErrorKey, error.toString());
      } catch (_) {
        // A failed preference store must not escape the background timer.
      }
    } finally {
      _running = false;
    }
  }

  @visibleForTesting
  static List<String> dueBackupDirectories({
    required List<String> directories,
    required Map<String, int> successfulAtMsByPath,
    required DateTime now,
    bool force = false,
  }) {
    final nowMs = now.millisecondsSinceEpoch;
    return [
      for (final path in directories)
        if (force ||
            successfulAtMsByPath[path] == null ||
            nowMs - successfulAtMsByPath[path]! < 0 ||
            nowMs - successfulAtMsByPath[path]! >= _interval.inMilliseconds)
          path,
    ];
  }

  static Map<String, int> _decodeSuccessMap(String? encoded) {
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is num) entry.key: (entry.value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<List<String>> _backupDirectories(SharedPreferences prefs) async {
    final localPath =
        (prefs.getString('backup_local_path') ??
                prefs.getString('backup_path') ??
                '')
            .trim();
    final externalPath = (prefs.getString('backup_external_path') ?? '').trim();
    final supportDirectory = await getApplicationSupportDirectory();
    final paths = <String>[
      localPath.isEmpty
          ? p.join(supportDirectory.path, 'AqariERP', 'backups')
          : localPath,
      if (externalPath.isNotEmpty) externalPath,
    ];

    final unique = <String, String>{};
    for (final rawPath in paths) {
      final normalized = p.normalize(p.absolute(rawPath));
      final key = Platform.isWindows ? normalized.toLowerCase() : normalized;
      unique.putIfAbsent(key, () => normalized);
    }
    return unique.values.toList(growable: false);
  }

  static String _timestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}'
        '${two(value.month)}${two(value.day)}_'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}_'
        '${value.microsecond.toString().padLeft(6, '0')}';
  }

  /// Removes only generated automatic snapshots, never manual or restore files.
  @visibleForTesting
  static Future<void> pruneAutoBackups(
    Directory directory, {
    required int keepNewest,
  }) async {
    if (keepNewest < 1) {
      throw ArgumentError.value(keepNewest, 'keepNewest', 'Must be at least 1');
    }
    if (!await directory.exists()) return;

    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith(filePrefix) && name.endsWith('.db')) {
        files.add(entity);
      }
    }
    files.sort(
      (left, right) => p.basename(right.path).compareTo(p.basename(left.path)),
    );
    for (final file in files.skip(keepNewest)) {
      if (await file.exists()) await file.delete();
    }
  }
}
