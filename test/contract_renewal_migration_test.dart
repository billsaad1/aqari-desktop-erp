import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final helper = DatabaseHelper.instance;
  final testDirectory = Directory.systemTemp.createTempSync(
    'aqari_contract_migration_',
  );
  final testDocuments = testDirectory.path;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return testDocuments;
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
  });

  setUp(() async {
    await helper.close();
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(() async {
    await helper.close();
  });

  tearDownAll(() async {
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test(
    'a v23 database upgrades the renewal relation and its constraints',
    () async {
      final currentDb = await helper.database;
      await currentDb.execute(
        'DROP TRIGGER IF EXISTS contracts_renewal_link_valid_insert',
      );
      await currentDb.execute(
        'DROP TRIGGER IF EXISTS contracts_renewal_link_immutable',
      );
      await currentDb.execute(
        'DROP INDEX IF EXISTS contracts_live_renewal_source_unique',
      );
      await currentDb.execute('PRAGMA foreign_keys = OFF');
      await currentDb.execute(
        'ALTER TABLE contracts DROP COLUMN renewed_from_contract_id',
      );
      await currentDb.execute('PRAGMA user_version = 23');
      await helper.close();

      final upgradedDb = await helper.database;
      final columns = await upgradedDb.rawQuery('PRAGMA table_info(contracts)');
      expect(
        columns.map((column) => column['name']),
        contains('renewed_from_contract_id'),
      );
      final foreignKeys = await upgradedDb.rawQuery(
        'PRAGMA foreign_key_list(contracts)',
      );
      expect(
        foreignKeys.any(
          (foreignKey) =>
              foreignKey['table'] == 'contracts' &&
              foreignKey['from'] == 'renewed_from_contract_id',
        ),
        isTrue,
      );
      final version = (await upgradedDb.rawQuery(
        'PRAGMA user_version',
      )).single['user_version'];
      expect(version, DatabaseHelper.schemaVersion);
      expect(
        (await upgradedDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'contracts'",
        )).map((row) => row['name']),
        containsAll([
          'contracts_renewal_link_valid_insert',
          'contracts_renewal_link_immutable',
        ]),
      );
      expect(
        (await upgradedDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'contracts_live_renewal_source_unique'",
        )),
        hasLength(1),
      );
    },
  );
}
