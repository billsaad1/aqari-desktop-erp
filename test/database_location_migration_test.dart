import 'dart:io';

import 'package:app/database/database_helper.dart';
import 'package:app/database/database_location_exception.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final helper = DatabaseHelper.instance;
  late Directory root;
  late Directory documents;
  late Directory support;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('aqari_db_location_test_');
    documents = Directory(p.join(root.path, 'Documents'));
    support = Directory(p.join(root.path, 'Support'));
    await documents.create(recursive: true);
    await support.create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return support.path;
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documents.path;
          }
          return null;
        });
  });

  tearDown(() async {
    DatabaseHelper.databaseLocationBeforePublishHookForTesting = null;
    await helper.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<({String activePath, String legacyPath, Database? legacyHandle})>
  prepareLegacy({bool leaveInWal = false}) async {
    final activePath = await helper.getDbPath();
    final current = await helper.database;
    await current.update(
      'company_info',
      {'name_ar': 'مصدر Documents قبل النقل'},
      where: 'id = ?',
      whereArgs: [1],
    );
    await helper.close();

    final legacyPath = p.join(
      documents.path,
      'AbdullahAlNaqeebERP',
      'desktop_erp.db',
    );
    await Directory(p.dirname(legacyPath)).create(recursive: true);
    await File(activePath).copy(legacyPath);

    final oldDatabase = await databaseFactory.openDatabase(legacyPath);
    for (final index in [
      'idx_journal_lines_entry',
      'idx_journal_lines_account_entry',
      'idx_journal_entries_date',
      'idx_contract_installments_contract_due',
      'idx_contract_installments_due_date',
    ]) {
      await oldDatabase.execute('DROP INDEX IF EXISTS $index');
    }
    await oldDatabase.execute('PRAGMA user_version = 33');

    Database? legacyHandle;
    if (leaveInWal) {
      await oldDatabase.execute('PRAGMA journal_mode = WAL');
      await oldDatabase.execute('PRAGMA wal_autocheckpoint = 0');
      await oldDatabase.update(
        'company_info',
        {'name_ar': 'بيانات committed داخل WAL'},
        where: 'id = ?',
        whereArgs: [1],
      );
      final wal = File('$legacyPath-wal');
      expect(await wal.exists(), isTrue);
      expect(await wal.length(), greaterThan(0));
      legacyHandle = oldDatabase;
    } else {
      await oldDatabase.close();
    }

    await support.delete(recursive: true);
    return (
      activePath: activePath,
      legacyPath: legacyPath,
      legacyHandle: legacyHandle,
    );
  }

  test(
    'migrates the v33 Documents database without deleting its source',
    () async {
      final paths = await prepareLegacy();

      expect(await helper.getDbPath(), paths.activePath);
      final migrated = await helper.database;
      final company = await migrated.query(
        'company_info',
        columns: ['name_ar'],
        where: 'id = ?',
        whereArgs: [1],
      );
      expect(company.single['name_ar'], 'مصدر Documents قبل النقل');
      expect(await File(paths.legacyPath).exists(), isTrue);
      expect(await File(paths.activePath).exists(), isTrue);

      final oldDatabase = await databaseFactory.openDatabase(
        paths.legacyPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        final version = await oldDatabase.rawQuery('PRAGMA user_version');
        expect((version.single.values.single as num).toInt(), 33);
        final oldCompany = await oldDatabase.query(
          'company_info',
          columns: ['name_ar'],
          where: 'id = ?',
          whereArgs: [1],
        );
        expect(oldCompany.single['name_ar'], 'مصدر Documents قبل النقل');
      } finally {
        await oldDatabase.close();
      }

      final indexes = (await migrated.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      )).map((row) => row['name']).toSet();
      expect(
        indexes,
        containsAll({
          'idx_journal_lines_entry',
          'idx_journal_lines_account_entry',
          'idx_journal_entries_date',
          'idx_contract_installments_contract_due',
          'idx_contract_installments_due_date',
        }),
      );
    },
  );

  test(
    'copies committed rows from a legacy WAL and keeps the source file',
    () async {
      final paths = await prepareLegacy(leaveInWal: true);
      final sourceHandle = paths.legacyHandle!;

      final migrated = await helper.database;
      final company = await migrated.query(
        'company_info',
        columns: ['name_ar'],
        where: 'id = ?',
        whereArgs: [1],
      );
      expect(company.single['name_ar'], 'بيانات committed داخل WAL');
      expect(await File(paths.legacyPath).exists(), isTrue);

      final oldCompany = await sourceHandle.query(
        'company_info',
        columns: ['name_ar'],
        where: 'id = ?',
        whereArgs: [1],
      );
      expect(oldCompany.single['name_ar'], 'بيانات committed داخل WAL');
      expect(
        ((await sourceHandle.rawQuery(
                  'PRAGMA user_version',
                )).single.values.single
                as num)
            .toInt(),
        33,
      );
      await sourceHandle.close();
    },
  );

  test(
    'fails closed when both database paths exist without a trusted marker',
    () async {
      final activePath = await helper.getDbPath();
      final active = await helper.database;
      await active.update(
        'company_info',
        {'name_ar': 'نسخة المسار الجديد'},
        where: 'id = ?',
        whereArgs: [1],
      );
      await helper.close();

      final legacyPath = p.join(
        documents.path,
        'AbdullahAlNaqeebERP',
        'desktop_erp.db',
      );
      await Directory(p.dirname(legacyPath)).create(recursive: true);
      await File(activePath).copy(legacyPath);
      final legacy = await databaseFactory.openDatabase(legacyPath);
      await legacy.update(
        'company_info',
        {'name_ar': 'نسخة Documents المختلفة'},
        where: 'id = ?',
        whereArgs: [1],
      );
      await legacy.close();

      for (final state in ['prepared', 'complete']) {
        final marker = File('$activePath.location-$state.json');
        if (await marker.exists()) await marker.delete();
      }

      await expectLater(
        helper.database,
        throwsA(isA<DatabaseLocationException>()),
      );
      expect(await File(activePath).exists(), isTrue);
      expect(await File(legacyPath).exists(), isTrue);

      final activeCheck = await databaseFactory.openDatabase(
        activePath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final legacyCheck = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        expect(
          (await activeCheck.query(
            'company_info',
            columns: ['name_ar'],
          )).single['name_ar'],
          'نسخة المسار الجديد',
        );
        expect(
          (await legacyCheck.query(
            'company_info',
            columns: ['name_ar'],
          )).single['name_ar'],
          'نسخة Documents المختلفة',
        );
      } finally {
        await activeCheck.close();
        await legacyCheck.close();
      }
    },
  );

  test(
    'resumes a prepared migration after interruption before publication',
    () async {
      final paths = await prepareLegacy();
      var injected = false;
      DatabaseHelper.databaseLocationBeforePublishHookForTesting = () async {
        if (!injected) {
          injected = true;
          throw StateError('simulated interruption before publish');
        }
      };

      await expectLater(helper.database, throwsA(isA<StateError>()));
      expect(await File(paths.legacyPath).exists(), isTrue);
      expect(await File(paths.activePath).exists(), isFalse);
      expect(
        await File('${paths.activePath}.migrate-staging').exists(),
        isTrue,
      );
      expect(
        await File('${paths.activePath}.location-prepared.json').exists(),
        isTrue,
      );

      DatabaseHelper.databaseLocationBeforePublishHookForTesting = null;
      final resumed = await helper.database;
      final company = await resumed.query(
        'company_info',
        columns: ['name_ar'],
        where: 'id = ?',
        whereArgs: [1],
      );
      expect(company.single['name_ar'], 'مصدر Documents قبل النقل');
      expect(await File(paths.legacyPath).exists(), isTrue);
      expect(await File(paths.activePath).exists(), isTrue);
      expect(
        await File('${paths.activePath}.location-complete.json').exists(),
        isTrue,
      );
    },
  );
}
