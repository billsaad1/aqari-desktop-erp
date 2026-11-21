import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_location_exception.dart';

typedef DatabaseAtPathOpener = Future<Database> Function(String path);
typedef DatabaseFileValidator = Future<void> Function(String path);
typedef OpenDatabaseValidator = Future<void> Function(Database database);

/// Moves the live database to Application Support without deleting its source.
/// A prepared manifest makes interrupted migrations resumable; an ambiguous
/// pair of databases is rejected rather than choosing one automatically.
class DatabaseLocationMigrator {
  const DatabaseLocationMigrator({
    required this.openDatabaseAtPath,
    required this.validateDatabaseFile,
    required this.validateOpenDatabase,
    required this.allowFreshDatabaseReplacement,
    this.beforePublishHook,
  });

  final DatabaseAtPathOpener openDatabaseAtPath;
  final DatabaseFileValidator validateDatabaseFile;
  final OpenDatabaseValidator validateOpenDatabase;
  final bool Function() allowFreshDatabaseReplacement;
  final Future<void> Function()? beforePublishHook;

  String _manifestPath(String activePath, String state) =>
      '$activePath.location-$state.json';

  DatabaseLocationException _conflict(
    String message,
    String legacyPath,
    String activePath,
  ) => DatabaseLocationException(
    message: message,
    legacyPath: legacyPath,
    activePath: activePath,
  );

  Future<String> _sqliteStamp(String databasePath) async {
    final parts = <String>[];
    for (final suffix in ['', '-wal']) {
      final file = File('$databasePath$suffix');
      if (!await file.exists()) {
        parts.add('$suffix:missing');
        continue;
      }
      final stat = await file.stat();
      parts.add('$suffix:${stat.size}:${stat.modified.microsecondsSinceEpoch}');
    }
    return parts.join('|');
  }

  Future<Map<String, dynamic>?> _readManifest(
    String activePath,
    String state,
    String legacyPath,
  ) async {
    final file = File(_manifestPath(activePath, state));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['formatVersion'] != 1 ||
          decoded['state'] != state) {
        throw const FormatException('Unsupported database-location manifest');
      }
      return decoded;
    } catch (error) {
      throw _conflict(
        'ملف حالة نقل قاعدة البيانات تالف أو غير مفهوم. لم نغيّر أي نسخة. الخطأ: $error',
        legacyPath,
        activePath,
      );
    }
  }

  Future<void> _writeManifest(
    String activePath,
    String state,
    String legacyPath,
    Map<String, Object?> values,
  ) async {
    final destination = File(_manifestPath(activePath, state));
    if (await destination.exists()) return;
    final temporary = File(
      '${destination.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({'formatVersion': 1, 'state': state, ...values}),
        flush: true,
      );
      if (await destination.exists()) {
        throw _conflict(
          'ظهر ملف حالة آخر أثناء ترحيل قاعدة البيانات. لم نستبدل أي ملف.',
          legacyPath,
          activePath,
        );
      }
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _replacePreparedManifest(
    String activePath,
    String legacyPath,
    String legacyStamp,
  ) async {
    final destination = File(_manifestPath(activePath, 'prepared'));
    final temporary = File(
      '${destination.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'formatVersion': 1,
          'state': 'prepared',
          'source': legacyPath,
          'legacyStamp': legacyStamp,
          'stagingPath': '$activePath.migrate-staging',
        }),
        flush: true,
      );
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Database> _openAndValidate(String path) async {
    final database = await openDatabaseAtPath(path);
    try {
      await validateOpenDatabase(database);
    } catch (_) {
      await database.close();
      rethrow;
    }
    await database.close();
    await validateDatabaseFile(path);
    return openDatabaseAtPath(path);
  }

  Future<String> _snapshotLegacy(
    String legacyPath,
    String stagingPath,
    String expectedStamp,
    String activePath,
  ) async {
    if (await _sqliteStamp(legacyPath) != expectedStamp) {
      throw _conflict(
        'تغيرت قاعدة البيانات القديمة قبل أخذ اللقطة. لم نثبت أي نسخة؛ أوقف أي إصدار آخر من البرنامج ثم أعد المحاولة.',
        legacyPath,
        activePath,
      );
    }
    final staging = File(stagingPath);
    if (await staging.exists()) await staging.delete();
    Database? readOnlySource;
    var stampWhileOpen = expectedStamp;
    try {
      // Open an independent read-only connection: sqflite's default
      // single-instance behavior could otherwise return and close a connection
      // already owned by the application. SQLite permits VACUUM INTO from a
      // read-only source while writing only to the new staging file.
      readOnlySource = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      await readOnlySource.rawQuery('PRAGMA schema_version');
      final escapedPath = stagingPath.replaceAll("'", "''");
      await readOnlySource.execute("VACUUM INTO '$escapedPath'");
      stampWhileOpen = await _sqliteStamp(legacyPath);
    } finally {
      await readOnlySource?.close();
    }
    final stampAfterSnapshot = await _sqliteStamp(legacyPath);
    if (stampWhileOpen != expectedStamp) {
      if (await staging.exists()) await staging.delete();
      throw _conflict(
        'تغيرت قاعدة البيانات القديمة أثناء أخذ لقطة SQLite. أُبقي المصدر كما هو؛ أوقف أي إصدار آخر من البرنامج وأعد المحاولة.',
        legacyPath,
        activePath,
      );
    }
    return stampAfterSnapshot;
  }

  Future<Database> _resumePreparedMigration({
    required String activePath,
    required String legacyPath,
    required Map<String, dynamic> manifest,
  }) async {
    var expectedStamp = manifest['legacyStamp'] as String?;
    final stagingPath = manifest['stagingPath'] as String?;
    final expectedStagingPath = '$activePath.migrate-staging';
    if (expectedStamp == null ||
        stagingPath == null ||
        stagingPath != expectedStagingPath) {
      throw _conflict(
        'بيانات استرداد ترحيل قاعدة البيانات ناقصة أو غير مطابقة للمسار. لم نحذف أو نستبدل أي نسخة.',
        legacyPath,
        activePath,
      );
    }

    final legacy = File(legacyPath);
    final active = File(activePath);
    if (await legacy.exists()) {
      final currentStamp = await _sqliteStamp(legacyPath);
      if (currentStamp != expectedStamp) {
        if (await active.exists()) {
          throw _conflict(
            'تغيرت النسخة القديمة بعد اعتماد لقطة الترحيل. أوقفنا التشغيل بدل تجاهل تغييرات محتملة.',
            legacyPath,
            activePath,
          );
        }
        final staging = File(stagingPath);
        if (await staging.exists()) await staging.delete();
        expectedStamp = currentStamp;
        await _replacePreparedManifest(activePath, legacyPath, expectedStamp);
      }
    }

    if (!await active.exists()) {
      if (!await File(stagingPath).exists()) {
        if (!await legacy.exists()) {
          throw _conflict(
            'تعذر العثور على المصدر أو اللقطة المرحلية لإكمال النقل. احتفظ بأي ملفات باقية وأرسل تفاصيل التشخيص للدعم.',
            legacyPath,
            activePath,
          );
        }
        expectedStamp = await _snapshotLegacy(
          legacyPath,
          stagingPath,
          expectedStamp,
          activePath,
        );
        await _replacePreparedManifest(activePath, legacyPath, expectedStamp);
      }

      await _validateAndCloseStaging(stagingPath);
      await beforePublishHook?.call();
      if (await active.exists()) {
        throw _conflict(
          'ظهرت قاعدة بيانات في المسار الجديد أثناء النقل. لم نستبدلها.',
          legacyPath,
          activePath,
        );
      }
      if (await legacy.exists() &&
          await _sqliteStamp(legacyPath) != expectedStamp) {
        throw _conflict(
          'تغير المصدر قبل تثبيت اللقطة؛ لم نستبدل قاعدة البيانات في المسار الجديد.',
          legacyPath,
          activePath,
        );
      }
      await File(stagingPath).rename(activePath);
    }

    final candidate = await openDatabaseAtPath(activePath);
    try {
      await validateOpenDatabase(candidate);
    } catch (_) {
      await candidate.close();
      rethrow;
    }
    await candidate.close();
    try {
      await validateDatabaseFile(activePath);
      if (await legacy.exists() &&
          await _sqliteStamp(legacyPath) != expectedStamp) {
        throw _conflict(
          'تغير المصدر بعد تثبيت اللقطة وقبل اعتماد النقل. احتفظ بالنسختين لمراجعة الاسترداد.',
          legacyPath,
          activePath,
        );
      }
      await _writeManifest(activePath, 'complete', legacyPath, {
        'source': legacyPath,
        'sourceStamp': expectedStamp,
      });
      final prepared = File(_manifestPath(activePath, 'prepared'));
      if (await prepared.exists()) await prepared.delete();
    } catch (_) {
      rethrow;
    }
    return openDatabaseAtPath(activePath);
  }

  Future<void> _validateAndCloseStaging(String stagingPath) async {
    final staged = await openDatabaseAtPath(stagingPath);
    try {
      await validateOpenDatabase(staged);
    } finally {
      await staged.close();
    }
    await validateDatabaseFile(stagingPath);
  }

  Future<Database> open({
    required String activePath,
    required String legacyPath,
  }) async {
    if (p.normalize(activePath) == p.normalize(legacyPath)) {
      return openDatabaseAtPath(activePath);
    }

    await Directory(p.dirname(activePath)).create(recursive: true);
    final lockHandle = await File(
      '$activePath.location.lock',
    ).open(mode: FileMode.append);
    await lockHandle.lock(FileLock.exclusive);
    try {
      final active = File(activePath);
      final legacy = File(legacyPath);
      final complete = await _readManifest(activePath, 'complete', legacyPath);
      if (complete != null) {
        if (!await active.exists()) {
          if (!allowFreshDatabaseReplacement()) {
            throw _conflict(
              'ملف قاعدة التشغيل غير موجود رغم وجود علامة نقل مكتملة. لم ننشئ قاعدة فارغة فوق بيانات محتملة.',
              legacyPath,
              activePath,
            );
          }
          final resetDatabase = await openDatabaseAtPath(activePath);
          await validateOpenDatabase(resetDatabase);
          return resetDatabase;
        }
        final sourceStamp = complete['sourceStamp'] as String?;
        if (await legacy.exists() &&
            (sourceStamp == null ||
                await _sqliteStamp(legacyPath) != sourceStamp)) {
          throw _conflict(
            'اكتشفنا تغيرًا في قاعدة Documents القديمة بعد اعتماد المسار الجديد. أوقفنا التشغيل لمنع تجاهل تغييرات محتملة؛ لم نحذف أي نسخة.',
            legacyPath,
            activePath,
          );
        }
        if (await File('$legacyPath-wal').exists() && sourceStamp == null) {
          throw _conflict(
            'توجد بقايا WAL لقاعدة قديمة بلا سجل ترحيل موثوق. لم نفتح قاعدة بديلة.',
            legacyPath,
            activePath,
          );
        }
        return await openDatabaseAtPath(activePath);
      }

      final prepared = await _readManifest(activePath, 'prepared', legacyPath);
      if (prepared != null) {
        return await _resumePreparedMigration(
          activePath: activePath,
          legacyPath: legacyPath,
          manifest: prepared,
        );
      }

      final activeExists = await active.exists();
      final legacyExists = await legacy.exists();
      final activeWalExists = await File('$activePath-wal').exists();
      if (activeExists && legacyExists) {
        throw _conflict(
          'وجدنا قاعدتين في المسارين القديم والجديد من دون سجل يحدد النسخة المعتمدة. لم نختر أيًّا منهما ولم نستبدل أو نحذف الملفات.',
          legacyPath,
          activePath,
        );
      }
      if (!activeExists && activeWalExists && !legacyExists) {
        throw _conflict(
          'وجدنا سجل WAL بلا ملف قاعدة التشغيل، ولا يوجد مصدر قديم مؤكد. لم ننشئ قاعدة جديدة فوقه.',
          legacyPath,
          activePath,
        );
      }

      if (legacyExists) {
        final legacyStamp = await _sqliteStamp(legacyPath);
        final stagingPath = '$activePath.migrate-staging';
        await _writeManifest(activePath, 'prepared', legacyPath, {
          'source': legacyPath,
          'legacyStamp': legacyStamp,
          'stagingPath': stagingPath,
        });
        return await _resumePreparedMigration(
          activePath: activePath,
          legacyPath: legacyPath,
          manifest: {
            'source': legacyPath,
            'legacyStamp': legacyStamp,
            'stagingPath': stagingPath,
          },
        );
      }

      final opened = await _openAndValidate(activePath);
      try {
        await _writeManifest(activePath, 'complete', legacyPath, {
          'source': null,
          'sourceStamp': null,
        });
        return opened;
      } catch (_) {
        await opened.close();
        rethrow;
      }
    } finally {
      await lockHandle.unlock();
      await lockHandle.close();
    }
  }
}
