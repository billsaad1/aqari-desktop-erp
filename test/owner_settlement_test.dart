import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late String testDocuments;
  final helper = DatabaseHelper.instance;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'aqari_owner_settlement_',
    );
    testDocuments = directory.path;
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
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<int> accountId(Database db, String code) async {
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: [code],
      limit: 1,
    );
    return (rows.single['id'] as num).toInt();
  }

  Future<({int ownerId, int liabilityAccountId, int cashAccountId})>
  seedOwnerAndPayable({
    required int amountMinor,
    bool fundCash = true,
    String? creditDate,
  }) async {
    final db = await helper.database;
    await helper.insertOwnerWithAccount({
      'name': 'مالك تسوية اختبار',
      'commission_rate': 0,
    });
    final owner = (await db.query(
      'owners',
      where: 'name = ?',
      whereArgs: ['مالك تسوية اختبار'],
      limit: 1,
    )).single;
    final ownerId = (owner['id'] as num).toInt();
    final liabilityAccountId = (owner['account_id'] as num).toInt();
    final cashAccountId = await accountId(db, '1101');
    final amount = amountMinor / 100.0;
    final sourceOffsetAccountId = fundCash
        ? cashAccountId
        : await db.insert('accounts', {
            'code': '129901',
            'name': 'حساب أصل ممول للاختبار',
            'parent_id': await accountId(db, '1201'),
            'account_type': 'Asset',
            'balance': 0.0,
          });
    await helper.insertJournalEntryWithLines(
      {
        'entry_date': creditDate ?? _yesterday(),
        'description': 'استحقاق مرحّل للاختبار',
      },
      [
        {
          'account_id': sourceOffsetAccountId,
          'debit': amount,
          'credit': 0.0,
          'description': 'مصدر التمويل',
        },
        {
          'account_id': liabilityAccountId,
          'debit': 0.0,
          'credit': amount,
          'description': 'استحقاق المالك المرحّل',
        },
      ],
    );
    return (
      ownerId: ownerId,
      liabilityAccountId: liabilityAccountId,
      cashAccountId: cashAccountId,
    );
  }

  test(
    'posts a linked owner settlement and reduces the liability balance',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);

      expect(await helper.getOwnerSettlementBalanceMinor(ids.ownerId), 10000);
      final voucherId = await helper.insertOwnerSettlementVoucher(
        ownerId: ids.ownerId,
        amountMinor: 7250,
        settlementDate: _today(),
        cashAccountId: ids.cashAccountId,
        description: 'سداد دفعة معتمدة',
      );

      final voucher = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [voucherId],
      )).single;
      expect(voucher['voucher_type'], 'صرف مستحقات مالك');
      expect(voucher['party_name'], 'مالك تسوية اختبار');
      final settlement = (await db.query(
        'owner_settlements',
        where: 'voucher_id = ?',
        whereArgs: [voucherId],
      )).single;
      expect(settlement['owner_id'], ids.ownerId);
      expect(settlement['owner_account_id'], ids.liabilityAccountId);
      expect(settlement['cash_account_id'], ids.cashAccountId);
      expect(settlement['amount_minor'], 7250);
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM owner_settlement_journal_intents',
        )).single['n'],
        0,
      );

      final journalId = (voucher['journal_entry_id'] as num).toInt();
      final lines = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [journalId],
        orderBy: 'id',
      );
      expect(lines, hasLength(2));
      expect(lines.first['account_id'], ids.liabilityAccountId);
      expect(lines.first['debit'], 72.5);
      expect(lines.last['account_id'], ids.cashAccountId);
      expect(lines.last['credit'], 72.5);
      expect(await helper.getOwnerSettlementBalanceMinor(ids.ownerId), 2750);

      final details = await helper.getVoucherDetails(voucherId);
      final settlementDetails = details!['owner_settlement'] as Map;
      expect(settlementDetails['amount_minor'], 7250);
      expect(settlementDetails['owner_account_id'], ids.liabilityAccountId);
      expect(settlementDetails['cash_account_id'], ids.cashAccountId);
      final cashAccount = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [ids.cashAccountId],
        limit: 1,
      )).single;
      final ownerAccount = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [ids.liabilityAccountId],
        limit: 1,
      )).single;
      final pdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند صرف مستحقات مالك',
        voucherNo: voucherId,
        date: _today(),
        targetName: 'مالك تسوية اختبار',
        amount: 72.5,
        accountName: '${cashAccount['name']} / ${ownerAccount['name']}',
        description: 'سداد دفعة معتمدة',
      );
      expect(pdf.length, greaterThan(1000));
      final audit = await db.query(
        'audit_logs',
        where: 'action = ? AND entity_id = ?',
        whereArgs: ['OWNER_SETTLEMENT_POSTED', settlement['id']],
      );
      expect(audit, hasLength(1));
      expect(audit.single['amount_minor'], 7250);
    },
  );

  test(
    'rejects payments above available owner payable without partial records',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 5000);
      final vouchersBefore = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM vouchers',
      );
      final entriesBefore = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM journal_entries',
      );
      final settlementsBefore = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM owner_settlements',
      );

      await expectLater(
        helper.insertOwnerSettlementVoucher(
          ownerId: ids.ownerId,
          amountMinor: 5001,
          settlementDate: _today(),
          cashAccountId: ids.cashAccountId,
          description: 'مبلغ يتجاوز المستحق',
        ),
        throwsStateError,
      );

      expect(
        (await db.rawQuery('SELECT COUNT(*) AS n FROM vouchers')).single['n'],
        vouchersBefore.single['n'],
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM journal_entries',
        )).single['n'],
        entriesBefore.single['n'],
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM owner_settlements',
        )).single['n'],
        settlementsBefore.single['n'],
      );
      expect(await helper.getOwnerSettlementBalanceMinor(ids.ownerId), 5000);
    },
  );

  test(
    'rejects a backdated settlement that predates the owner payable',
    () async {
      final ids = await seedOwnerAndPayable(
        amountMinor: 5000,
        creditDate: _today(),
      );

      await expectLater(
        helper.insertOwnerSettlementVoucher(
          ownerId: ids.ownerId,
          amountMinor: 100,
          settlementDate: _yesterday(),
          cashAccountId: ids.cashAccountId,
          description: 'تاريخ يسبق الاستحقاق',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'rejects a code that looks like cash but is under another asset root',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 5000);
      final misleadingAccountId = await db.insert('accounts', {
        'code': '119901',
        'name': 'ليس صندوقًا رغم بادئة الرمز',
        'parent_id': await accountId(db, '1201'),
        'account_type': 'Asset',
        'balance': 0.0,
      });

      expect(
        (await helper.getOwnerSettlementCashAccounts()).any(
          (account) => (account['id'] as num).toInt() == misleadingAccountId,
        ),
        isFalse,
      );
      await expectLater(
        helper.insertOwnerSettlementVoucher(
          ownerId: ids.ownerId,
          amountMinor: 100,
          settlementDate: _today(),
          cashAccountId: misleadingAccountId,
          description: 'حساب خارج شجرة النقدية',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'SQLite rejects an owner settlement linked to a misleading cash account',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 5000);
      final misleadingAccountId = await db.insert('accounts', {
        'code': '119902',
        'name': 'حساب أصل خارج شجرة النقدية',
        'parent_id': await accountId(db, '1201'),
        'account_type': 'Asset',
        'balance': 0.0,
      });
      await helper.insertJournalEntryWithLines(
        {'entry_date': _yesterday(), 'description': 'تمويل الأصل المضلل'},
        [
          {
            'account_id': misleadingAccountId,
            'debit': 100.0,
            'credit': 0.0,
            'description': 'رصيد غير نقدي',
          },
          {
            'account_id': ids.cashAccountId,
            'debit': 0.0,
            'credit': 100.0,
            'description': 'مصدر تمويل الحساب المضلل',
          },
        ],
      );

      await expectLater(
        db.transaction((txn) async {
          final journalId = await txn.insert('journal_entries', {
            'entry_date': _today(),
            'description': 'قيد يدوي لحساب دفع مضلل',
            'is_posted': 1,
          });
          await txn.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': ids.liabilityAccountId,
            'debit': 10.0,
            'credit': 0.0,
            'description': 'تخفيض التزام المالك',
          });
          await txn.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': misleadingAccountId,
            'debit': 0.0,
            'credit': 10.0,
            'description': 'محاولة دفع من حساب غير نقدي',
          });
          final voucherId = await txn.insert('vouchers', {
            'voucher_type': 'صرف مستحقات مالك',
            'voucher_date': _today(),
            'amount': 10.0,
            'tenant_id': null,
            'party_name': 'مالك تسوية اختبار',
            'journal_entry_id': journalId,
            'description': 'سداد يدوي غير صالح',
            'period_from_date': null,
            'period_to_date': null,
          });
          await txn.insert('owner_settlements', {
            'voucher_id': voucherId,
            'owner_id': ids.ownerId,
            'owner_account_id': ids.liabilityAccountId,
            'cash_account_id': misleadingAccountId,
            'journal_entry_id': journalId,
            'amount_minor': 1000,
            'settlement_date': _today(),
            'owner_name_snapshot': 'مالك تسوية اختبار',
            'description': 'سداد يدوي غير صالح',
            'created_by': 1,
            'created_at': DateTime.now().toIso8601String(),
          });
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM owner_settlements',
        )).single['n'],
        0,
      );
    },
  );

  test(
    'rejects payout when the selected cash account has no posted funds',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 5000, fundCash: false);

      await expectLater(
        helper.insertOwnerSettlementVoucher(
          ownerId: ids.ownerId,
          amountMinor: 100,
          settlementDate: _today(),
          cashAccountId: ids.cashAccountId,
          description: 'لا يوجد رصيد صندوق مرحّل',
        ),
        throwsStateError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM owner_settlements',
        )).single['n'],
        0,
      );
    },
  );

  test(
    'blocks paying an owner account through a general disbursement',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);
      final cash = (await db.query(
        'accounts',
        columns: ['balance'],
        where: 'id = ?',
        whereArgs: [ids.cashAccountId],
      )).single;
      expect((cash['balance'] as num).toDouble(), greaterThan(0));

      await expectLater(
        helper.insertGeneralVoucher(
          {
            'voucher_type': 'صرف عام',
            'voucher_date': _today(),
            'amount': 25.0,
            'description': 'محاولة تجاوز مسار المالك',
          },
          ids.cashAccountId,
          ids.liabilityAccountId,
          null,
          'صرف عام',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'SQLite blocks low-level general vouchers debiting an owner account',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);
      final before = (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM journal_entries',
      )).single['n'];

      await expectLater(
        db.transaction((txn) async {
          final journalId = await txn.insert('journal_entries', {
            'entry_date': _today(),
            'description': 'محاولة SQL لتجاوز مسار المالك',
            'is_posted': 1,
          });
          await txn.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': ids.liabilityAccountId,
            'debit': 10.0,
            'credit': 0.0,
            'description': 'سداد غير مربوط',
          });
          await txn.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': ids.cashAccountId,
            'debit': 0.0,
            'credit': 10.0,
            'description': 'صرف نقدي',
          });
          await txn.insert('vouchers', {
            'voucher_type': 'صرف عام',
            'voucher_date': _today(),
            'amount': 10.0,
            'tenant_id': null,
            'party_name': 'مالك تسوية اختبار',
            'journal_entry_id': journalId,
            'description': 'محاولة صرف عام على التزام المالك',
            'period_from_date': null,
            'period_to_date': null,
          });
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM journal_entries',
        )).single['n'],
        before,
      );
    },
  );

  test(
    'manual journal API cannot debit an owner payable without a settlement link',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);
      final before = (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM journal_entries',
      )).single['n'];

      await expectLater(
        helper.insertJournalEntryWithLines(
          {'entry_date': _today(), 'description': 'خصم مالك يدوي غير مرتبط'},
          [
            {
              'account_id': ids.liabilityAccountId,
              'debit': 10.0,
              'credit': 0.0,
              'cost_center_id': null,
              'description': 'خصم من مستحق المالك',
            },
            {
              'account_id': ids.cashAccountId,
              'debit': 0.0,
              'credit': 10.0,
              'cost_center_id': null,
              'description': 'مقابل نقدي',
            },
          ],
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM journal_entries',
        )).single['n'],
        before,
      );
    },
  );

  test(
    'SQLite blocks direct journal debits to owner payable without an intent',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);
      final before = (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM journal_entries',
      )).single['n'];

      await expectLater(
        db.transaction((txn) async {
          final journalId = await txn.insert('journal_entries', {
            'entry_date': _today(),
            'description': 'خصم مباشر بلا سجل سداد',
            'is_posted': 1,
          });
          await txn.insert('journal_lines', {
            'journal_entry_id': journalId,
            'account_id': ids.liabilityAccountId,
            'debit': 10.0,
            'credit': 0.0,
            'description': 'خصم غير مربوط',
          });
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM journal_entries',
        )).single['n'],
        before,
      );
    },
  );

  test(
    'serializes concurrent payouts so the same balance cannot be paid twice',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);

      Future<int?> attemptSettlement() async {
        try {
          return await helper.insertOwnerSettlementVoucher(
            ownerId: ids.ownerId,
            amountMinor: 6000,
            settlementDate: _today(),
            cashAccountId: ids.cashAccountId,
            description: 'محاولة متزامنة',
          );
        } on StateError {
          return null;
        }
      }

      final results = await Future.wait([
        attemptSettlement(),
        attemptSettlement(),
      ]);
      expect(results.whereType<int>(), hasLength(1));
      expect(results.where((id) => id == null), hasLength(1));
      expect(await helper.getOwnerSettlementBalanceMinor(ids.ownerId), 4000);
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM owner_settlements',
        )).single['n'],
        1,
      );
    },
  );

  test('rejects an owner account shared with another owner', () async {
    final db = await helper.database;
    final ids = await seedOwnerAndPayable(amountMinor: 5000);
    final duplicateId = await db.insert('owners', {
      'name': 'مالك آخر يشارك الحساب',
      'account_id': ids.liabilityAccountId,
    });

    expect(await helper.getOwnerSettlementOwners(), isEmpty);
    await expectLater(
      helper.getOwnerSettlementBalanceMinor(ids.ownerId),
      throwsStateError,
    );
    await expectLater(
      helper.insertOwnerSettlementVoucher(
        ownerId: ids.ownerId,
        amountMinor: 100,
        settlementDate: _today(),
        cashAccountId: ids.cashAccountId,
        description: 'حساب مشترك غير آمن',
      ),
      throwsStateError,
    );
    await db.delete('owners', where: 'id = ?', whereArgs: [duplicateId]);
  });

  test(
    'requires accounting post permission at the database boundary',
    () async {
      final ids = await seedOwnerAndPayable(amountMinor: 5000);
      PermissionRuntime.activate(
        userId: 88,
        role: 'DataEntry',
        permissionRows: [
          {
            'screen_name': 'accounting',
            'can_view': 1,
            'can_add': 1,
            'can_edit': 0,
            'can_delete': 0,
            'can_print': 0,
            'can_post': 0,
          },
        ],
      );

      await expectLater(
        helper.insertOwnerSettlementVoucher(
          ownerId: ids.ownerId,
          amountMinor: 100,
          settlementDate: _today(),
          cashAccountId: ids.cashAccountId,
          description: 'لا يوجد إذن ترحيل',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'owner settlement source records and linked postings are immutable',
    () async {
      final db = await helper.database;
      final ids = await seedOwnerAndPayable(amountMinor: 10000);
      final voucherId = await helper.insertOwnerSettlementVoucher(
        ownerId: ids.ownerId,
        amountMinor: 1000,
        settlementDate: _today(),
        cashAccountId: ids.cashAccountId,
        description: 'سجل غير قابل للمحو',
      );
      final voucher = (await db.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [voucherId],
      )).single;
      final journalId = (voucher['journal_entry_id'] as num).toInt();
      final lineId = (await db.query(
        'journal_lines',
        columns: ['id'],
        where: 'journal_entry_id = ?',
        whereArgs: [journalId],
        limit: 1,
      )).single['id'];

      await expectLater(
        db.update(
          'owner_settlements',
          {'description': 'تعديل'},
          where: 'voucher_id = ?',
          whereArgs: [voucherId],
        ),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.delete(
          'owner_settlements',
          where: 'voucher_id = ?',
          whereArgs: [voucherId],
        ),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.delete('vouchers', where: 'id = ?', whereArgs: [voucherId]),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.update(
          'journal_lines',
          {'debit': 99.0},
          where: 'id = ?',
          whereArgs: [lineId],
        ),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.delete('journal_entries', where: 'id = ?', whereArgs: [journalId]),
        throwsA(isA<DatabaseException>()),
      );
    },
  );

  test(
    'v26 upgrades with owner settlement schema and required barriers',
    () async {
      final db = await helper.database;
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_intent_valid_insert',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_lines_owner_debit_requires_link',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_consume_journal_intent',
      );
      await db.execute('DROP TABLE owner_settlement_journal_intents');
      await db.execute('DROP TABLE owner_settlements');
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_account_general_disbursement_block',
      );
      await db.execute('DROP TRIGGER IF EXISTS owner_settlement_valid_insert');
      await db.execute('DROP TRIGGER IF EXISTS owner_settlements_no_update');
      await db.execute('DROP TRIGGER IF EXISTS owner_settlements_no_delete');
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_vouchers_no_update',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_vouchers_no_delete',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_entries_no_update',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_entries_no_delete',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_lines_no_update',
      );
      await db.execute(
        'DROP TRIGGER IF EXISTS owner_settlement_journal_lines_no_delete',
      );
      await db.execute('DROP INDEX IF EXISTS owner_settlements_owner_date_idx');
      await db.execute('DROP INDEX IF EXISTS owner_settlements_cash_date_idx');
      await db.execute('PRAGMA user_version = 26');
      await helper.close();

      final upgraded = await helper.database;
      expect(
        (await upgraded.rawQuery(
          'PRAGMA table_info(owner_settlements)',
        )).map((row) => row['name']),
        containsAll([
          'voucher_id',
          'owner_id',
          'owner_account_id',
          'cash_account_id',
          'journal_entry_id',
          'amount_minor',
          'created_by',
        ]),
      );
      expect(
        (await upgraded.rawQuery(
          'PRAGMA table_info(owner_settlement_journal_intents)',
        )).map((row) => row['name']),
        containsAll([
          'journal_entry_id',
          'owner_id',
          'owner_account_id',
          'amount_minor',
        ]),
      );
      expect(
        ((await upgraded.rawQuery('PRAGMA user_version')).single[
          'user_version'
        ] as num).toInt(),
        DatabaseHelper.schemaVersion,
      );
      final triggers = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger'",
      )).map((row) => row['name']);
      expect(
        triggers,
        containsAll([
          'owner_settlement_journal_intent_valid_insert',
          'owner_settlement_journal_lines_owner_debit_requires_link',
          'owner_settlement_valid_insert',
          'owner_settlement_consume_journal_intent',
          'owner_settlements_no_update',
          'owner_settlements_no_delete',
          'owner_account_general_disbursement_block',
        ]),
      );
    },
  );
}

String _today() {
  final now = DateTime.now();
  return _dateFormatDateOnly(now);
}

String _yesterday() =>
    _dateFormatDateOnly(DateTime.now().subtract(const Duration(days: 1)));

String _dateFormatDateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
