import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/credit_note_schema.dart';
import 'package:app/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_credit_note_database_test';
  final helper = DatabaseHelper.instance;

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

  Future<int> accountId(dynamic db, String code) async =>
      ((await db.query(
                'accounts',
                columns: ['id'],
                where: 'code = ?',
                whereArgs: [code],
                limit: 1,
              )).single['id']
              as num)
          .toInt();

  Future<Map<String, Object?>> makeLease(dynamic db, String suffix) async {
    await helper.insertTenantWithAccount({
      'name': 'مستأجر إشعار $suffix',
      'mobile': '779300${suffix.hashCode.abs() % 1000}',
    });
    final tenant = (await db.query(
      'tenants',
      columns: ['id', 'name', 'account_id'],
      where: 'name = ?',
      whereArgs: ['مستأجر إشعار $suffix'],
      limit: 1,
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك إشعار $suffix'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار إشعار $suffix',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'CN-$suffix',
      'status': 'مؤجرة',
    });
    final contractId = await db.insert('contracts', {
      'tenant_id': tenant['id'],
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2027-12-31',
      'rent_amount': 100.0,
      'status': 'Active',
    });
    return {
      ...tenant,
      'contract_id': contractId,
      'unit_id': unitId,
    };
  }

  Future<Map<String, Object?>> makeInvoice(
    dynamic db,
    Map<String, Object?> lease, {
    required String suffix,
  }) async {
    final installmentId = await db.insert('contract_installments', {
      'contract_id': lease['contract_id'],
      'amount': 100.0,
      'paid_amount': 0.0,
      'due_date': '2026-01-01',
      'status': 'Unpaid',
    });
    final invoiceId = await helper.insertTaxInvoice(
      contractId: lease['contract_id'] as int,
      tenantId: lease['id'] as int,
      installmentId: installmentId,
      invoiceDate: '2026-01-01',
      netAmount: 100.0,
      taxAmount: 15.0,
      revenueAccountId: await accountId(db, '4101'),
      taxAccountId: await accountId(db, '2103'),
    );
    return {
      'installment_id': installmentId,
      'invoice_id': invoiceId,
      'suffix': suffix,
    };
  }

  Future<int> makeCashReceipt(
    dynamic db,
    Map<String, Object?> lease,
    int invoiceId,
  ) async => helper.insertTenantReceiptVoucher(
    tenantId: lease['id'] as int,
    amount: 115.0,
    voucherDate: '2026-01-05',
    cashAccountId: await accountId(db, '1101'),
    installmentsToUpdate: const [],
    invoiceId: invoiceId,
  );

  test(
    'drafts do not post, tax rounding balances, limits are cumulative, and aging updates',
    () async {
      final db = await helper.database;
      await db.update('company_info', {'tax_rate': 15.0});
      final lease = await makeLease(db, 'aging');
      final invoice = await makeInvoice(db, lease, suffix: 'aging');
      final invoiceId = invoice['invoice_id'] as int;
      await expectLater(
        helper.createCreditNoteDraft(
          invoiceId: invoiceId,
          noteDate: '2026-02-30',
          totalAmountMinor: 100,
          reason: 'تاريخ غير تقويمي',
        ),
        throwsArgumentError,
      );
      final journalCountBeforeDraft = (await db.query('journal_entries')).length;
      final draftId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-10',
        totalAmountMinor: 5000,
        reason: 'تخفيض متفق عليه للاختبار',
      );
      final draft = (await db.query(
        'credit_notes',
        where: 'id = ?',
        whereArgs: [draftId],
        limit: 1,
      )).single;
      expect(draft['status'], 'draft');
      expect((await db.query('journal_entries')).length, journalCountBeforeDraft);
      expect(
        (await helper.getTenantAgingReport(asOfDate: '2026-02-01'))
            .totalOutstandingMinor,
        11500,
      );

      final secondDraftId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-11',
        totalAmountMinor: 6501,
        reason: 'مسودة تتجاوز المتبقي بعد الإشعار الأول',
      );
      final unpostedJournalId = await db.insert('journal_entries', {
        'entry_date': '2026-01-12',
        'description': 'قيد اختبار غير مرحّل',
        'is_posted': 0,
      });
      await expectLater(
        db.update(
          'credit_notes',
          {
            'status': 'posted',
            'journal_entry_id': unpostedJournalId,
            'posted_at': '2026-01-12T00:00:00',
          },
          where: 'id = ?',
          whereArgs: [secondDraftId],
        ),
        throwsA(isA<Exception>()),
      );
      await helper.postCreditNote(draftId);
      await expectLater(helper.postCreditNote(secondDraftId), throwsStateError);

      final posted = (await db.query(
        'credit_notes',
        where: 'id = ?',
        whereArgs: [draftId],
        limit: 1,
      )).single;
      expect(posted['status'], 'posted');
      expect(posted['net_amount_minor'], 4348);
      expect(posted['tax_amount_minor'], 652);
      expect(
        (posted['net_amount_minor'] as int) +
            (posted['tax_amount_minor'] as int),
        5000,
      );
      final invoiceAfter = (await db.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
        limit: 1,
      )).single;
      expect(invoiceAfter['total_amount'], 115.0);
      final journalId = posted['journal_entry_id'] as int;
      final lines = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [journalId],
      );
      final debitMinor = lines.fold<int>(
        0,
        (total, line) => total + ((line['debit'] as num) * 100).round(),
      );
      final creditMinor = lines.fold<int>(
        0,
        (total, line) => total + ((line['credit'] as num) * 100).round(),
      );
      expect(debitMinor, 5000);
      expect(creditMinor, 5000);
      final agingAfterPost = await helper.getTenantAgingReport(
        asOfDate: '2026-02-01',
      );
      expect(agingAfterPost.totalOutstandingMinor, 6500);
      expect(agingAfterPost.rows.single.obligationMinor, 6500);

      await expectLater(
        helper.reverseCreditNote(
          draftId,
          reversalDate: '2026-01-09',
          reason: 'تاريخ يسبق الإشعار',
        ),
        throwsArgumentError,
      );
      await helper.reverseCreditNote(
        draftId,
        reversalDate: '2026-01-20',
        reason: 'عكس اختباري قبل أي استرداد',
      );
      expect(
        (await helper.getTenantAgingReport(asOfDate: '2026-02-01'))
            .totalOutstandingMinor,
        11500,
      );
    },
  );

  test(
    'cash refunds stay tied to receipt and credit note, with no refund-based limit reset',
    () async {
      final db = await helper.database;
      await db.update('company_info', {'tax_rate': 15.0});
      final lease = await makeLease(db, 'refund');
      final invoice = await makeInvoice(db, lease, suffix: 'refund');
      final invoiceId = invoice['invoice_id'] as int;
      final receiptVoucherId = await makeCashReceipt(db, lease, invoiceId);
      final sourceAllocation = (await db.query(
        'collection_allocations',
        columns: ['id'],
        where: 'voucher_id = ?',
        whereArgs: [receiptVoucherId],
        limit: 1,
      )).single;
      final sourceAllocationId = (sourceAllocation['id'] as num).toInt();

      final firstNoteId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-10',
        totalAmountMinor: 5000,
        reason: 'تخفيض مرتبط برد نقدي اختباري',
      );
      await helper.postCreditNote(firstNoteId);
      var balances = await helper.getCreditNotesForInvoice(invoiceId);
      expect(balances.single['refundable_minor'], 5000);

      final firstRefundId = await helper.insertTenantRefundVoucher(
        tenantId: lease['id'] as int,
        amount: 50.0,
        voucherDate: '2026-01-15',
        cashAccountId: await accountId(db, '1101'),
        collectionAllocationId: sourceAllocationId,
        description: 'رد كامل للإشعار الأول',
        creditNoteId: firstNoteId,
      );
      expect(firstRefundId, greaterThan(0));
      balances = await helper.getCreditNotesForInvoice(invoiceId);
      expect(balances.single['refunded_minor'], 5000);
      expect(balances.single['refundable_minor'], 0);

      final secondNoteId = await helper.createCreditNoteDraft(
        invoiceId: invoiceId,
        noteDate: '2026-01-16',
        totalAmountMinor: 2000,
        reason: 'إشعار لاحق بعد الرد الأول',
      );
      await helper.postCreditNote(secondNoteId);
      balances = await helper.getCreditNotesForInvoice(invoiceId);
      final secondBalance = balances.singleWhere(
        (row) => (row['id'] as num).toInt() == secondNoteId,
      );
      expect(secondBalance['applied_minor'], 0);
      expect(secondBalance['refundable_minor'], 2000);

      await helper.insertTenantRefundVoucher(
        tenantId: lease['id'] as int,
        amount: 20.0,
        voucherDate: '2026-01-20',
        cashAccountId: await accountId(db, '1101'),
        collectionAllocationId: sourceAllocationId,
        description: 'رد جزئي للإشعار الثاني',
        creditNoteId: secondNoteId,
      );
      await expectLater(
        helper.insertTenantRefundVoucher(
          tenantId: lease['id'] as int,
          amount: 0.01,
          voucherDate: '2026-01-21',
          cashAccountId: await accountId(db, '1101'),
          collectionAllocationId: sourceAllocationId,
          description: 'تجاوز رصيد مصدر القبض',
          creditNoteId: secondNoteId,
        ),
        throwsStateError,
      );
      await expectLater(
        helper.reverseCreditNote(
          firstNoteId,
          reversalDate: '2026-01-22',
          reason: 'محاولة عكس بعد الاستخدام',
        ),
        throwsStateError,
      );
      final aging = await helper.getTenantAgingReport(asOfDate: '2026-02-01');
      expect(aging.totalOutstandingMinor, 0);
    },
  );

  test('v29 legacy notes remain unposted for manual review after upgrade', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('CREATE TABLE accounts (id INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY)');
    await db.execute(
      'CREATE TABLE journal_entries (id INTEGER PRIMARY KEY, is_posted INTEGER)',
    );
    await db.execute('''
      CREATE TABLE journal_lines (
        id INTEGER PRIMARY KEY,
        journal_entry_id INTEGER,
        account_id INTEGER,
        debit REAL,
        credit REAL
      )
    ''');
    await db.execute('''
      CREATE TABLE tax_invoices (
        id INTEGER PRIMARY KEY,
        contract_id INTEGER,
        installment_id INTEGER,
        total_amount REAL
      )
    ''');
    await db.execute('CREATE TABLE contracts (id INTEGER PRIMARY KEY, tenant_id INTEGER)');
    await db.execute('''
      CREATE TABLE collection_allocations (
        id INTEGER PRIMARY KEY,
        invoice_id INTEGER,
        voucher_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE vouchers (
        id INTEGER PRIMARY KEY,
        voucher_type TEXT,
        tenant_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE collection_allocation_balances (
        id INTEGER PRIMARY KEY,
        remaining_minor INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE refund_allocations (
        id INTEGER PRIMARY KEY,
        refund_voucher_id INTEGER,
        collection_allocation_id INTEGER,
        amount_minor INTEGER,
        rent_amount_minor INTEGER,
        tax_amount_minor INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE credit_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_id INTEGER,
        note_date TEXT NOT NULL,
        amount REAL NOT NULL
      )
    ''');
    await db.insert('credit_notes', {
      'invoice_id': null,
      'note_date': '2025-12-31',
      'amount': 123.45,
    });

    await CreditNoteSchema.upgradeToV30(db);

    final legacy = (await db.query('credit_notes')).single;
    expect(legacy['amount'], 123.45);
    expect(legacy['status'], 'legacy_review');
    expect(legacy['total_amount_minor'], 0);
    expect(legacy['net_amount_minor'], 0);
    expect(legacy['journal_entry_id'], isNull);
    expect(legacy['created_at'], isNotNull);
    expect(
      (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'view' AND name = 'credit_note_refund_balances'",
      )),
      hasLength(1),
    );
  });

  test('DatabaseHelper upgrades a v29 file while retaining legacy note values', () async {
    final db = await helper.database;
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.execute('DROP VIEW IF EXISTS credit_note_refund_balances');
    final triggerRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    );
    for (final row in triggerRows) {
      final name = row['name']?.toString() ?? '';
      if (name.startsWith('credit_notes_') ||
          name.startsWith('refund_allocations_credit_note_')) {
        await db.execute('DROP TRIGGER IF EXISTS "$name"');
      }
    }
    await db.execute('DROP INDEX IF EXISTS credit_notes_invoice_status_idx');
    await db.execute('DROP INDEX IF EXISTS refund_allocations_credit_note_idx');
    await db.execute('DROP TABLE credit_notes');
    await db.execute('''
      CREATE TABLE credit_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_id INTEGER,
        note_date TEXT NOT NULL,
        amount REAL NOT NULL,
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
      )
    ''');
    await db.insert('credit_notes', {
      'invoice_id': null,
      'note_date': '2025-12-31',
      'amount': 321.09,
    });
    await db.execute('PRAGMA user_version = 29');
    await helper.close();

    final migrated = await helper.database;
    final legacy = (await migrated.query('credit_notes')).single;
    expect(legacy['amount'], 321.09);
    expect(legacy['status'], 'legacy_review');
    expect(legacy['total_amount_minor'], 0);
    expect(legacy['journal_entry_id'], isNull);
    expect(legacy['created_at'], isNotNull);
    expect(
      (await migrated.rawQuery('PRAGMA user_version')).single['user_version'],
      DatabaseHelper.schemaVersion,
    );
    expect(
      await migrated.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'view' AND name = 'credit_note_refund_balances'",
      ),
      hasLength(1),
    );
  });
}
