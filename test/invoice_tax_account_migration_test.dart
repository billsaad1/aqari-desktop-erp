import 'dart:io';

import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_invoice_tax_account_migration_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
  });

  setUp(() async {
    await helper.close();
    final stale = Directory(testDocuments);
    if (await stale.exists()) await stale.delete(recursive: true);
  });

  tearDown(() async {
    await helper.close();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'v21 upgrades to v22 without inventing historical tax accounts',
    () async {
      final db = await helper.database;
      final invoiceId = await db.insert('tax_invoices', {
        'invoice_date': '2026-03-01',
        'net_amount': 100.0,
        'tax_amount': 15.0,
        'total_amount': 115.0,
        'tax_rate': 15.0,
      });
      await db.execute('ALTER TABLE tax_invoices DROP COLUMN tax_account_id');
      await db.execute('PRAGMA user_version = 21');
      await helper.close();

      final upgraded = await helper.database;
      final version = (await upgraded.rawQuery(
        'PRAGMA user_version',
      )).single.values.single;
      final columns = (await upgraded.rawQuery(
        'PRAGMA table_info(tax_invoices)',
      )).map((row) => row['name']).toSet();
      final invoice = (await upgraded.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
      )).single;

      expect(version, DatabaseHelper.schemaVersion);
      expect(columns, contains('tax_account_id'));
      expect(invoice['tax_account_id'], isNull);
      expect(invoice['net_amount'], 100.0);
      expect(invoice['tax_amount'], 15.0);
      expect(invoice['total_amount'], 115.0);
    },
  );
}
