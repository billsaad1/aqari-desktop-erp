import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/tenant_financial/credit_note_screen.dart';
import 'package:app/providers/accounting_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

final _testRoot = Directory.systemTemp.createTempSync(
  'aqari_credit_note_widget_test_',
);
final _testDocuments = p.join(_testRoot.path, 'Documents');
final _testSupport = p.join(_testRoot.path, 'Support');

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => _testDocuments;

  @override
  Future<String?> getApplicationSupportPath() async => _testSupport;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  final originalPathProvider = PathProviderPlatform.instance;

  setUpAll(() {
    PathProviderPlatform.instance = _TestPathProvider();
  });

  setUp(() async {
    await helper.close();
    final directory = Directory(_testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
    final supportDirectory = Directory(_testSupport);
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(() async {
    await helper.close();
    PermissionRuntime.clear();
    final directory = Directory(_testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
    final supportDirectory = Directory(_testSupport);
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await _testRoot.exists()) await _testRoot.delete(recursive: true);
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

  testWidgets(
    'loads a SQLite draft, confirms posting, and verifies the balanced entry',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = await tester.runAsync(() async {
        final db = await helper.database;
        await db.update('company_info', {'tax_rate': 15.0});
        await helper.insertTenantWithAccount({
          'name': 'مستأجر اختبار شاشة الإشعار',
          'mobile': '779399001',
        });
        final tenant = (await db.query(
          'tenants',
          columns: ['id', 'name'],
          where: 'name = ?',
          whereArgs: ['مستأجر اختبار شاشة الإشعار'],
          limit: 1,
        )).single;
        final ownerId = await db.insert('owners', {
          'name': 'مالك اختبار الإشعار',
        });
        final propertyId = await db.insert('properties', {
          'name': 'عقار اختبار الإشعار',
          'owner_id': ownerId,
        });
        final unitId = await db.insert('units', {
          'property_id': propertyId,
          'unit_number': 'CN-WIDGET-1',
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
        final installmentId = await db.insert('contract_installments', {
          'contract_id': contractId,
          'amount': 100.0,
          'paid_amount': 0.0,
          'due_date': '2026-01-01',
          'status': 'Unpaid',
        });
        final invoiceId = await helper.insertTaxInvoice(
          contractId: contractId,
          tenantId: (tenant['id'] as num).toInt(),
          installmentId: installmentId,
          invoiceDate: '2026-01-01',
          netAmount: 100.0,
          taxAmount: 15.0,
          revenueAccountId: await accountId(db, '4101'),
          taxAccountId: await accountId(db, '2103'),
        );
        final draftId = await helper.createCreditNoteDraft(
          invoiceId: invoiceId,
          noteDate: '2026-01-10',
          totalAmountMinor: 5000,
          reason: 'تخفيض اختباري معتمد',
        );
        final journalCountBefore = (await db.query('journal_entries')).length;
        return (
          database: db,
          invoiceId: invoiceId,
          draftId: draftId,
          journalCountBefore: journalCountBefore,
        );
      });
      final db = fixture!.database;
      final invoiceId = fixture.invoiceId;
      final draftId = fixture.draftId;
      final journalCountBefore = fixture.journalCountBefore;
      final accounting = AccountingProvider();

      await tester.pumpWidget(
        ChangeNotifierProvider<AccountingProvider>.value(
          value: accounting,
          child: const MaterialApp(home: Scaffold(body: CreditNoteScreen())),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('فاتورة #$invoiceId'), findsOneWidget);

      final draftRows = await tester.runAsync(
        () => db.query(
          'credit_notes',
          where: 'id = ?',
          whereArgs: [draftId],
          limit: 1,
        ),
      );
      final draft = draftRows!.single;
      expect(draft['status'], 'draft');
      expect(draft['journal_entry_id'], isNull);
      final journalRows = await tester.runAsync(
        () => db.query('journal_entries'),
      );
      expect(journalRows!.length, journalCountBefore);
      expect(find.textContaining('مسودة — غير مرحّلة'), findsOneWidget);
      expect(find.byTooltip('ترحيل'), findsOneWidget);

      await tester.tap(find.byTooltip('ترحيل'));
      await tester.pumpAndSettle();
      expect(find.text('ترحيل الإشعار الدائن رقم $draftId؟'), findsOneWidget);
      final beforeConfirm = await tester.runAsync(
        () => db.query('credit_notes', where: 'id = ?', whereArgs: [draftId]),
      );
      expect(beforeConfirm!.single['status'], 'draft');

      await tester.tap(find.text('ترحيل القيد'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final postedRows = await tester.runAsync(
        () => db.query(
          'credit_notes',
          where: 'id = ? AND status = ?',
          whereArgs: [draftId, 'posted'],
          limit: 1,
        ),
      );
      final posted = postedRows!.single;
      expect(posted['status'], 'posted');
      expect(posted['journal_entry_id'], isNotNull);
      final journalId = (posted['journal_entry_id'] as num).toInt();
      final journalRowsPosted = await tester.runAsync(
        () => db.query(
          'journal_entries',
          where: 'id = ?',
          whereArgs: [journalId],
        ),
      );
      final journal = journalRowsPosted!.single;
      expect(journal['is_posted'], 1);
      final lines = await tester.runAsync(
        () => db.query(
          'journal_lines',
          where: 'journal_entry_id = ?',
          whereArgs: [journalId],
        ),
      );
      final postedLines = lines!;
      expect(postedLines, isNotEmpty);
      final debitMinor = postedLines.fold<int>(
        0,
        (sum, row) => sum + ((row['debit'] as num) * 100).round(),
      );
      final creditMinor = postedLines.fold<int>(
        0,
        (sum, row) => sum + ((row['credit'] as num) * 100).round(),
      );
      expect(debitMinor, 5000);
      expect(creditMinor, 5000);
      expect(find.textContaining('مرحّل'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      accounting.dispose();
    },
  );
}
