import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/models/tenant_receipt_payment_method.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_tenant_receipt_payment_test';
  final helper = DatabaseHelper.instance;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
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

  Future<int> accountId(dynamic db, String code) async {
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'code = ?',
      whereArgs: [code],
      limit: 1,
    );
    return (rows.single['id'] as num).toInt();
  }

  Future<Map<String, Object?>> createReceiptFixture() async {
    final db = await helper.database;
    await helper.insertTenantWithAccount({
      'name': 'مستأجر طرق القبض',
      'mobile': '779199771',
    });
    final tenant = (await db.query(
      'tenants',
      columns: ['id', 'name', 'account_id'],
      where: 'name = ?',
      whereArgs: ['مستأجر طرق القبض'],
      limit: 1,
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك طرق القبض'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار طرق القبض',
      'owner_id': ownerId,
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'PM-1',
      'status': 'مؤجرة',
    });
    final contractId = await db.insert('contracts', {
      'tenant_id': tenant['id'],
      'unit_id': unitId,
      'start_date': '2026-01-01',
      'end_date': '2026-12-31',
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
    final correctionTargetInstallmentId = await db.insert(
      'contract_installments',
      {
        'contract_id': contractId,
        'amount': 100.0,
        'paid_amount': 0.0,
        'due_date': '2026-02-01',
        'status': 'Unpaid',
      },
    );
    return {
      'db': db,
      'tenant_id': (tenant['id'] as num).toInt(),
      'cash_account_id': await accountId(db, '1101'),
      'bank_account_id': await accountId(db, '1102'),
      'installment_id': installmentId,
      'correction_target_installment_id': correctionTargetInstallmentId,
    };
  }

  Future<int> postReceipt(
    Map<String, Object?> fixture, {
    required int account,
    required String method,
    int? bankId,
    String? reference,
    String? bankName,
  }) {
    return helper.insertTenantReceiptVoucher(
      tenantId: fixture['tenant_id']! as int,
      amount: 100.0,
      voucherDate: '2026-11-23',
      cashAccountId: account,
      installmentsToUpdate: [
        {
          'id': fixture['installment_id'],
          'paid_amount': 100.0,
          'status': 'Paid',
        },
      ],
      description: 'اختبار طريقة القبض',
      paymentMethod: method,
      paymentBankId: bankId,
      paymentReference: reference,
      paymentBankName: bankName,
    );
  }

  test('cash receipt is stored and debited to the cashbox account', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final voucherId = await postReceipt(
      fixture,
      account: fixture['cash_account_id']! as int,
      method: TenantReceiptPaymentMethod.cash.databaseValue,
    );

    final voucher = (await db.query(
      'vouchers',
      where: 'id = ?',
      whereArgs: [voucherId],
      limit: 1,
    )).single;
    final details = await helper.getTenantReceiptVoucherDetails(voucherId);
    final lines = (details!['journal_lines'] as List)
        .whereType<Map>()
        .map((line) => Map<String, dynamic>.from(line))
        .toList();

    expect(voucher['payment_method'], 'cash');
    expect(voucher['payment_reference'], isNull);
    expect(voucher['payment_bank_name'], isNull);
    expect(
      lines.singleWhere((line) => (line['debit'] as num) > 0)['account_code'],
      '1101',
    );
    expect(
      TenantReceiptPaymentMethod.displayLabel(method: voucher['payment_method']),
      'نقداً للصندوق',
    );
  });

  test('bank transfer uses and snapshots the selected bank ledger account', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final bankId = await db.insert('banks', {
      'name': 'مصرف الاختبار',
      'account_id': fixture['bank_account_id'],
    });
    final options = await helper.getTenantReceiptBankOptions();
    expect(
      options.any((option) => option['bank_id'] == bankId),
      isTrue,
    );

    final voucherId = await postReceipt(
      fixture,
      account: fixture['bank_account_id']! as int,
      method: TenantReceiptPaymentMethod.bankTransfer.databaseValue,
      bankId: bankId,
      reference: 'TRF-2026-0042',
    );
    final voucher = (await db.query(
      'vouchers',
      where: 'id = ?',
      whereArgs: [voucherId],
      limit: 1,
    )).single;
    final details = await helper.getTenantReceiptVoucherDetails(voucherId);
    final debitLine = (details!['journal_lines'] as List)
        .whereType<Map>()
        .map((line) => Map<String, dynamic>.from(line))
        .singleWhere((line) => (line['debit'] as num) > 0);

    expect(voucher['payment_method'], 'bank_transfer');
    expect(voucher['payment_reference'], 'TRF-2026-0042');
    expect(voucher['payment_bank_name'], 'مصرف الاختبار');
    expect(debitLine['account_id'], fixture['bank_account_id']);
    expect(
      TenantReceiptPaymentMethod.displayLabel(
        method: voucher['payment_method'],
        reference: voucher['payment_reference'],
        bankName: voucher['payment_bank_name'],
      ),
      'حوالة بنكية — مصرف الاختبار — مرجع TRF-2026-0042',
    );
  });

  test('bank transfer cannot post to an account different from selected bank', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final bankId = await db.insert('banks', {
      'name': 'مصرف الحساب الثاني',
      'account_id': fixture['bank_account_id'],
    });

    await expectLater(
      postReceipt(
        fixture,
        account: fixture['cash_account_id']! as int,
        method: TenantReceiptPaymentMethod.bankTransfer.databaseValue,
        bankId: bankId,
      ),
      throwsArgumentError,
    );
    final installment = (await db.query(
      'contract_installments',
      where: 'id = ?',
      whereArgs: [fixture['installment_id']],
      limit: 1,
    )).single;
    expect(installment['paid_amount'], 0.0);
    expect(
      await db.query(
        'vouchers',
        where: "voucher_type = 'قبض مستأجر'",
      ),
      isEmpty,
    );
  });

  test('check receipt requires a number and posts to the selected clearing account', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final cashRootId = await accountId(db, '11');
    final clearingAccountId = await db.insert('accounts', {
      'code': '1198',
      'name': 'شيكات برسم التحصيل',
      'parent_id': cashRootId,
      'account_type': 'Asset',
      'balance': 0.0,
    });

    await expectLater(
      postReceipt(
        fixture,
        account: clearingAccountId,
        method: TenantReceiptPaymentMethod.check.databaseValue,
      ),
      throwsArgumentError,
    );

    final voucherId = await postReceipt(
      fixture,
      account: clearingAccountId,
      method: TenantReceiptPaymentMethod.check.databaseValue,
      reference: 'CHQ-90817',
      bankName: 'بنك إصدار الشيك',
    );
    final voucher = (await db.query(
      'vouchers',
      where: 'id = ?',
      whereArgs: [voucherId],
      limit: 1,
    )).single;
    final details = await helper.getTenantReceiptVoucherDetails(voucherId);
    final debitLine = (details!['journal_lines'] as List)
        .whereType<Map>()
        .map((line) => Map<String, dynamic>.from(line))
        .singleWhere((line) => (line['debit'] as num) > 0);

    expect(voucher['payment_method'], 'check');
    expect(voucher['payment_reference'], 'CHQ-90817');
    expect(voucher['payment_bank_name'], 'بنك إصدار الشيك');
    expect(debitLine['account_code'], '1198');
    expect(
      TenantReceiptPaymentMethod.displayLabel(
        method: voucher['payment_method'],
        reference: voucher['payment_reference'],
        bankName: voucher['payment_bank_name'],
      ),
      'شيك رقم CHQ-90817 — بنك إصدار الشيك',
    );
  });

  test('receipt correction preserves the original method, bank, and reference', () async {
    final fixture = await createReceiptFixture();
    final db = fixture['db'] as dynamic;
    final bankId = await db.insert('banks', {
      'name': 'مصرف تصحيح القبض',
      'account_id': fixture['bank_account_id'],
    });
    final sourceVoucherId = await postReceipt(
      fixture,
      account: fixture['bank_account_id']! as int,
      method: TenantReceiptPaymentMethod.bankTransfer.databaseValue,
      bankId: bankId,
      reference: 'TRF-CORRECTION-1',
    );

    final replacementVoucherId = await helper.correctTenantReceiptVoucher(
      sourceVoucherId: sourceVoucherId,
      replacementInstallmentId:
          fixture['correction_target_installment_id']! as int,
      correctedAmount: 100.0,
      correctionDate: '2026-11-23',
      description: 'تخصيص السند على القسط الصحيح',
      reason: 'اختبار الحفاظ على بيانات القبض',
    );
    final details = await helper.getTenantReceiptVoucherDetails(
      replacementVoucherId,
    );
    final voucher = Map<String, dynamic>.from(details!['voucher'] as Map);

    expect(voucher['payment_method'], 'bank_transfer');
    expect(voucher['payment_reference'], 'TRF-CORRECTION-1');
    expect(voucher['payment_bank_name'], 'مصرف تصحيح القبض');
  });

  test('new schema contains persistent payment method fields', () async {
    final db = await helper.database;
    final columns = await db.rawQuery('PRAGMA table_info(vouchers)');
    final names = columns.map((column) => column['name']).toSet();

    expect(DatabaseHelper.schemaVersion, 36);
    expect(names, containsAll(['payment_method', 'payment_reference', 'payment_bank_name']));
  });
}
