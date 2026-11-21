import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final testDirectory = Directory.systemTemp.createTempSync(
    'aqari_general_voucher_lines_test_',
  );
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return testDirectory.path;
          }
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDirectory.path;
          }
          return null;
        });
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  setUp(() async {
    await helper.close();
  });

  tearDownAll(() async {
    await helper.close();
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test(
    'posts multiple described accounts in one balanced atomic voucher',
    () async {
      final db = await helper.database;
      final cashAccount = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1101'],
        limit: 1,
      )).single;
      final revenueAccounts = await db.query(
        'accounts',
        where: "account_type = 'Revenue' AND parent_id IS NOT NULL",
        orderBy: 'code',
        limit: 2,
      );
      expect(revenueAccounts, hasLength(2));
      final cashAccountId = (cashAccount['id'] as num).toInt();
      final firstRevenueId = (revenueAccounts[0]['id'] as num).toInt();
      final secondRevenueId = (revenueAccounts[1]['id'] as num).toInt();
      final costCenterId = await db.insert('cost_centers', {
        'code': 'TEST-MULTI-${DateTime.now().microsecondsSinceEpoch}',
        'name': 'مركز تكلفة السند متعدد البنود',
      });
      final today = DateTime.now().toIso8601String().substring(0, 10);

      final voucherId = await helper.insertGeneralVoucherWithLines(
        {
          'voucher_type': 'قبض عام',
          'voucher_date': today,
          'amount': 100.0,
          'party_name': 'عميل اختبار',
          'description': 'تحصيل من مصدرين',
          'period_from_date': '2026-11-01',
          'period_to_date': '2026-11-30',
        },
        cashAccountId,
        [
          {
            'account_id': firstRevenueId,
            'amount': 40.0,
            'cost_center_id': costCenterId,
            'description': 'إيراد البند الأول',
          },
          {
            'account_id': secondRevenueId,
            'amount': 60.0,
            'cost_center_id': null,
            'description': 'إيراد البند الثاني',
          },
        ],
        'قبض عام',
      );

      final details = await helper.getVoucherDetails(voucherId);
      expect(details, isNotNull);
      final voucher = details!['voucher'] as Map;
      expect(voucher['description'], 'تحصيل من مصدرين');
      expect(voucher['party_name'], 'عميل اختبار');
      expect(voucher['period_from_date'], '2026-11-01');
      expect(voucher['period_to_date'], '2026-11-30');
      final lines = (details['journal_lines'] as List)
          .cast<Map<String, dynamic>>();
      expect(lines, hasLength(3));
      expect(lines.map((line) => line['line_description']).toList(), [
        'تحصيل من مصدرين',
        'إيراد البند الأول',
        'إيراد البند الثاني',
      ]);
      expect(
        lines.fold<double>(0, (sum, line) => sum + (line['debit'] as num)),
        100.0,
      );
      expect(
        lines.fold<double>(0, (sum, line) => sum + (line['credit'] as num)),
        100.0,
      );
      final firstLine = lines.singleWhere(
        (line) => line['account_id'] == firstRevenueId,
      );
      expect(firstLine['cost_center_id'], costCenterId);

      final vouchersBeforeFailure = await db.query('vouchers');
      final journalsBeforeFailure = await db.query('journal_entries');
      final journalLinesBeforeFailure = await db.query('journal_lines');
      final accountRowsBeforeFailure = await db.query(
        'accounts',
        columns: ['id', 'balance'],
        where: 'id IN (?, ?, ?)',
        whereArgs: [cashAccountId, firstRevenueId, secondRevenueId],
      );
      final balancesBeforeFailure = {
        for (final row in accountRowsBeforeFailure)
          (row['id'] as num).toInt(): (row['balance'] as num).toDouble(),
      };
      await db.execute('''
      CREATE TRIGGER test_reject_general_voucher_counterpart
      BEFORE INSERT ON journal_lines
      WHEN NEW.description = 'رفض آلي للاختبار'
      BEGIN
        SELECT RAISE(ABORT, 'simulated counterpart failure');
      END
    ''');

      try {
        await expectLater(
          helper.insertGeneralVoucherWithLines(
            {
              'voucher_type': 'قبض عام',
              'voucher_date': today,
              'amount': 10.0,
              'description': 'سند يجب أن يتراجع بالكامل',
            },
            cashAccountId,
            [
              {
                'account_id': firstRevenueId,
                'amount': 5.0,
                'cost_center_id': null,
                'description': 'بند صالح أولًا',
              },
              {
                'account_id': secondRevenueId,
                'amount': 5.0,
                'cost_center_id': null,
                'description': 'رفض آلي للاختبار',
              },
            ],
            'قبض عام',
          ),
          throwsA(anything),
        );
      } finally {
        await db.execute(
          'DROP TRIGGER test_reject_general_voucher_counterpart',
        );
      }

      expect(
        await db.query('vouchers'),
        hasLength(vouchersBeforeFailure.length),
      );
      expect(
        await db.query('journal_entries'),
        hasLength(journalsBeforeFailure.length),
      );
      expect(
        await db.query('journal_lines'),
        hasLength(journalLinesBeforeFailure.length),
      );
      final accountRowsAfterFailure = await db.query(
        'accounts',
        columns: ['id', 'balance'],
        where: 'id IN (?, ?, ?)',
        whereArgs: [cashAccountId, firstRevenueId, secondRevenueId],
      );
      expect({
        for (final row in accountRowsAfterFailure)
          (row['id'] as num).toInt(): (row['balance'] as num).toDouble(),
      }, balancesBeforeFailure);
    },
  );
}
