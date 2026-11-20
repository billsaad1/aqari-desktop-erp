import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_accounting_periods_test';
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

  Future<Map<String, dynamic>> accountByCode(String code) async {
    final db = await helper.database;
    return (await db.query(
      'accounts',
      where: 'code = ?',
      whereArgs: [code],
      limit: 1,
    )).single;
  }

  Future<int> createPeriod() async {
    final period = await helper.createAccountingPeriod(
      startDate: '2026-01-01',
      endDate: '2026-01-31',
    );
    return period.id;
  }

  test('v30 upgrades to v31 without inventing historical periods', () async {
    var db = await helper.database;
    await db.insert('user_permissions', {
      'user_id': 1,
      'screen_name': 'reports',
      'can_view': 1,
      'can_add': 0,
      'can_edit': 0,
      'can_delete': 0,
      'can_print': 1,
      'can_post': 0,
      'can_review_approve': 0,
    });
    await db.execute('PRAGMA user_version = 30');
    await db.execute(
      'ALTER TABLE user_permissions DROP COLUMN can_reopen_period',
    );
    await db.execute(
      'ALTER TABLE user_permissions DROP COLUMN can_close_period',
    );
    await db.execute(
      'ALTER TABLE user_permissions DROP COLUMN can_lock_period',
    );
    final oldTriggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name LIKE 'accounting_period_%'",
    );
    for (final row in oldTriggers) {
      await db.execute('DROP TRIGGER "${row['name']}"');
    }
    await db.execute('DROP TABLE accounting_period_events');
    await db.execute('DROP TABLE accounting_periods');
    await helper.close();

    db = await helper.database;
    final version = await db.rawQuery('PRAGMA user_version');
    expect((version.single.values.single as num).toInt(), 31);
    expect(await db.query('accounting_periods'), isEmpty);
    expect(await db.query('accounting_period_events'), isEmpty);
    final permissionColumns = (await db.rawQuery(
      'PRAGMA table_info(user_permissions)',
    )).map((row) => row['name']).toSet();
    expect(
      permissionColumns,
      containsAll([
        'can_lock_period',
        'can_close_period',
        'can_reopen_period',
      ]),
    );
    final preservedPermission = (await db.query(
      'user_permissions',
      where: 'user_id = ? AND screen_name = ?',
      whereArgs: [1, 'reports'],
      limit: 1,
    )).single;
    expect(preservedPermission['can_view'], 1);
    expect(preservedPermission['can_print'], 1);
    expect(preservedPermission['can_lock_period'], 0);
    expect(preservedPermission['can_close_period'], 0);
    expect(preservedPermission['can_reopen_period'], 0);
    expect(
      AppPermissionCatalog.codeForNavigationIndex(14),
      'accounting_periods',
    );
    final triggerNames = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    )).map((row) => row['name']).toSet();
    expect(
      triggerNames,
      containsAll([
        'accounting_period_journal_insert_guard',
        'accounting_period_journal_update_guard',
        'accounting_period_journal_delete_guard',
        'accounting_period_lines_insert_guard',
        'accounting_period_lines_update_guard',
        'accounting_period_events_no_update',
        'accounting_period_events_no_delete',
      ]),
    );
  });

  test('period dates cannot overlap and invalid dates are rejected', () async {
    await createPeriod();
    await expectLater(
      helper.createAccountingPeriod(
        startDate: '2026-01-31',
        endDate: '2026-02-28',
      ),
      throwsException,
    );
    await expectLater(
      helper.createAccountingPeriod(
        startDate: '2026-02-30',
        endDate: '2026-03-31',
      ),
      throwsArgumentError,
    );
    await expectLater(
      helper.createAccountingPeriod(
        startDate: '2026-03-01',
        endDate: '2026-02-01',
      ),
      throwsArgumentError,
    );
  });

  test('readiness includes entries on 9999-12-31 without year overflow', () async {
    final db = await helper.database;
    final period = await helper.createAccountingPeriod(
      startDate: '9999-12-31',
      endDate: '9999-12-31',
    );
    await db.insert('journal_entries', {
      'entry_date': '9999-12-31T23:59:59',
      'description': 'آخر يوم تقويمي مسموح',
      'is_posted': 0,
    });
    await db.insert('journal_entries', {
      'entry_date': '9999-12-31T12:00:00',
      'description': 'قيد مرحل غير متوازن في نهاية النطاق',
      'is_posted': 1,
    });

    final readiness = await helper.getAccountingPeriodReadiness(period.id);
    expect(readiness.report.unpostedEntries, hasLength(1));
    expect(readiness.report.unbalancedPostedEntries, hasLength(1));
  });

  test(
    'readiness blocks lock, then all journal posting and edits are barred after lock',
    () async {
      final db = await helper.database;
      final periodId = await createPeriod();
      final cash = await accountByCode('1101');
      final revenue = await accountByCode('4101');
      final cashId = (cash['id'] as num).toInt();
      final revenueId = (revenue['id'] as num).toInt();
      final draftId = await db.insert('journal_entries', {
        'entry_date': '2026-01-31T23:59:59',
        'description': 'draft prevents lock',
        'is_posted': 0,
      });

      final blockedReadiness = await helper.getAccountingPeriodReadiness(
        periodId,
      );
      expect(blockedReadiness.report.unpostedEntries, hasLength(1));
      final eventsBeforeFailedLock = await helper.getAccountingPeriodEvents(
        periodId,
      );
      await expectLater(helper.lockAccountingPeriod(periodId), throwsStateError);
      expect(
        (await helper.getAccountingPeriods()).single.status,
        'open',
      );
      expect(
        await helper.getAccountingPeriodEvents(periodId),
        hasLength(eventsBeforeFailedLock.length),
      );

      await db.insert('journal_lines', {
        'journal_entry_id': draftId,
        'account_id': cashId,
        'debit': 25.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': draftId,
        'account_id': revenueId,
        'debit': 0.0,
        'credit': 25.0,
      });
      await db.update(
        'journal_entries',
        {'is_posted': 1},
        where: 'id = ?',
        whereArgs: [draftId],
      );
      final ready = await helper.getAccountingPeriodReadiness(periodId);
      expect(ready.report.isReadyForManualReview, isTrue);

      await helper.lockAccountingPeriod(periodId);
      expect((await helper.getAccountingPeriods()).single.status, 'locked');
      final entriesBefore = await db.query(
        'journal_entries',
        where: 'entry_date >= ? AND entry_date < ?',
        whereArgs: ['2026-01-01', '2026-02-01'],
      );
      final cashBalanceBefore = (await accountByCode('1101'))['balance'];
      final revenueBalanceBefore = (await accountByCode('4101'))['balance'];
      final lineCountBefore = (await db.query('journal_lines')).length;
      final auditCountBefore = (await db.query('audit_logs')).length;

      await expectLater(
        db.insert('journal_entries', {
          'entry_date': '2026-01-31T23:59:59',
          'description': 'direct SQL posting attempt',
          'is_posted': 1,
        }),
        throwsException,
      );
      await expectLater(
        helper.insertJournalEntryWithLines(
          {
            'entry_date': '2026-01-15',
            'description': 'service posting attempt',
          },
          [
            {'account_id': cashId, 'debit': 7.0, 'credit': 0.0},
            {'account_id': revenueId, 'debit': 0.0, 'credit': 7.0},
          ],
        ),
        throwsException,
      );
      await expectLater(
        db.update(
          'journal_entries',
          {'description': 'attempted edit'},
          where: 'id = ?',
          whereArgs: [draftId],
        ),
        throwsException,
      );
      await expectLater(
        db.update(
          'journal_lines',
          {'description': 'attempted line edit'},
          where: 'journal_entry_id = ?',
          whereArgs: [draftId],
        ),
        throwsException,
      );
      await expectLater(
        db.delete(
          'journal_lines',
          where: 'journal_entry_id = ?',
          whereArgs: [draftId],
        ),
        throwsException,
      );
      await db.execute('PRAGMA foreign_keys = OFF');
      try {
        await expectLater(
          db.delete(
            'journal_entries',
            where: 'id = ?',
            whereArgs: [draftId],
          ),
          throwsException,
        );
      } finally {
        await db.execute('PRAGMA foreign_keys = ON');
      }

      expect(
        await db.query(
          'journal_entries',
          where: 'entry_date >= ? AND entry_date < ?',
          whereArgs: ['2026-01-01', '2026-02-01'],
        ),
        hasLength(entriesBefore.length),
      );
      expect((await db.query('journal_lines')).length, lineCountBefore);
      expect((await db.query('audit_logs')).length, auditCountBefore);
      expect((await accountByCode('1101'))['balance'], cashBalanceBefore);
      expect((await accountByCode('4101'))['balance'], revenueBalanceBefore);

      await helper.closeAccountingPeriod(periodId, reason: 'اعتماد الإقفال');
      expect((await helper.getAccountingPeriods()).single.status, 'closed');
      final entriesAfterClose = await db.query('journal_entries');
      expect(entriesAfterClose, hasLength(entriesBefore.length));
      await expectLater(
        db.update(
          'accounting_periods',
          {'status': 'open'},
          where: 'id = ?',
          whereArgs: [periodId],
        ),
        throwsException,
      );
    },
  );

  test('reopening needs a separate grant and a non-empty audited reason', () async {
    final db = await helper.database;
    final periodId = await createPeriod();
    await helper.lockAccountingPeriod(periodId);
    await helper.closeAccountingPeriod(periodId);

    expect(
      PermissionRuntime.allows(
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      ),
      isFalse,
    );
    expect(
      AppPermissionCatalog.roleAllows(
        'SuperAdmin',
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      ),
      isFalse,
    );
    final secondSuperAdminId = await db.insert('users', {
      'username': 'period-reviewer',
      'password_hash': 'test-hash',
      'full_name': 'مراجع الفترة',
      'role': 'SuperAdmin',
    });
    await expectLater(
      helper.replaceUserPermissions(secondSuperAdminId, const [
        {
          'screen_name': 'accounting_periods',
          'can_view': 1,
          'can_lock_period': 1,
          'can_reopen_period': 1,
        },
      ]),
      throwsStateError,
    );
    await helper.replaceUserPermissions(secondSuperAdminId, const [
      {
        'screen_name': 'accounting_periods',
        'can_view': 1,
        'can_reopen_period': 1,
      },
    ]);
    final explicitPermissions = await helper.getUserPermissions(
      secondSuperAdminId,
    );
    PermissionRuntime.activate(
      userId: secondSuperAdminId,
      role: 'SuperAdmin',
      permissionRows: explicitPermissions,
    );
    expect(
      PermissionRuntime.allows(
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      ),
      isTrue,
    );

    final adminId = await db.insert('users', {
      'username': 'period-admin',
      'password_hash': 'test-hash',
      'full_name': 'مدير الإقفال',
      'role': 'Admin',
    });
    PermissionRuntime.activate(
      userId: adminId,
      role: 'Admin',
      permissionRows: const [],
    );
    expect(
      PermissionRuntime.allows(
        'accounting_periods',
        AppPermissionAction.closePeriod,
      ),
      isTrue,
    );
    expect(
      PermissionRuntime.allows(
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      ),
      isFalse,
    );
    await expectLater(
      helper.reopenAccountingPeriod(periodId, reason: 'تصحيح'),
      throwsStateError,
    );
    expect((await helper.getAccountingPeriods()).single.status, 'closed');

    final accountantId = await db.insert('users', {
      'username': 'period-accountant',
      'password_hash': 'test-hash',
      'full_name': 'محاسب الفترة',
      'role': 'Accountant',
    });
    PermissionRuntime.activate(
      userId: accountantId,
      role: 'Accountant',
      permissionRows: const [
        {'screen_name': 'reports', 'can_view': 0},
        {
          'screen_name': 'accounting_periods',
          'can_view': 1,
          'can_reopen_period': 1,
        },
      ],
    );
    expect(
      PermissionRuntime.allows('reports', AppPermissionAction.view),
      isFalse,
    );
    expect(
      PermissionRuntime.allows(
        'accounting_periods',
        AppPermissionAction.view,
      ),
      isTrue,
    );
    expect(
      AppPermissionCatalog.codeForNavigationIndex(14),
      'accounting_periods',
    );
    await expectLater(
      helper.reopenAccountingPeriod(periodId, reason: '   '),
      throwsArgumentError,
    );
    await helper.reopenAccountingPeriod(
      periodId,
      reason: 'تصحيح قيد بعد اعتماد المشرف',
    );
    expect((await helper.getAccountingPeriods()).single.status, 'open');

    final events = await helper.getAccountingPeriodEvents(periodId);
    expect(events.map((event) => event.action), [
      'created',
      'locked',
      'closed',
      'reopened',
    ]);
    expect(events.last.actorName, 'محاسب الفترة');
    expect(events.last.reason, 'تصحيح قيد بعد اعتماد المشرف');
    final audit = await db.query(
      'audit_logs',
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: ['accounting_period', periodId],
      orderBy: 'id ASC',
    );
    expect(
      audit.map((row) => row['action']),
      containsAll([
        'ACCOUNTING_PERIOD_CREATED',
        'ACCOUNTING_PERIOD_LOCKED',
        'ACCOUNTING_PERIOD_CLOSED',
        'ACCOUNTING_PERIOD_REOPENED',
      ]),
    );
    await expectLater(
      db.update(
        'accounting_period_events',
        {'reason': 'tampered'},
        where: 'period_id = ?',
        whereArgs: [periodId],
      ),
      throwsException,
    );
    await expectLater(
      db.delete(
        'accounting_period_events',
        where: 'period_id = ?',
        whereArgs: [periodId],
      ),
      throwsException,
    );
  });
}
