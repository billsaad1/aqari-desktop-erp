import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:app/core/arabic_amount_words.dart';
import 'package:app/core/crypto_utils.dart';
import 'package:app/core/company_logo_storage.dart';
import 'package:app/core/lease_contract_pdf.dart';
import 'package:app/core/contract_party_snapshot.dart';
import 'package:app/core/internal_tax.dart';
import 'package:app/core/lease_contract_terms.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/database/database_integrity_migrations.dart';
import 'package:app/models/company_info_model.dart';
import 'package:app/features/general_accounting/chart_of_accounts_screen.dart';
import 'package:app/features/tenant_financial/voucher_history_screen.dart';
import 'package:app/features/tenant_financial/tenant_payment_screen.dart';
import 'package:app/features/tenants_leasing/tenants_screen.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/accounting_provider.dart';
import 'package:app/providers/leasing_provider.dart';
import 'package:app/providers/property_provider.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:app/providers/sms_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const testDocuments = '/tmp/aqari_erp_flutter_test';

  setUpAll(() async {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    final staleTestDirectory = Directory(testDocuments);
    if (await staleTestDirectory.exists()) {
      await staleTestDirectory.delete(recursive: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
  });

  tearDownAll(() async {
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await DatabaseHelper.instance.close();
    final directory = Directory(testDocuments);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('credential hashing', () {
    test(
      'uses salted PBKDF2 and verifies without accepting wrong passwords',
      () {
        final first = CryptoUtils.hashPassword('A-strong-password-2026');
        final second = CryptoUtils.hashPassword('A-strong-password-2026');
        expect(first, startsWith('pbkdf2_sha256\$'));
        expect(first, isNot(second));
        expect(
          CryptoUtils.verifyPassword('A-strong-password-2026', first),
          isTrue,
        );
        expect(CryptoUtils.verifyPassword('wrong-password', first), isFalse);
      },
    );

    test('can authenticate legacy SHA-256 hashes for migration', () {
      const legacyAdminHash =
          '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92';
      expect(CryptoUtils.isLegacyHash(legacyAdminHash), isTrue);
      expect(CryptoUtils.verifyPassword('123456', legacyAdminHash), isTrue);
      expect(
        CryptoUtils.verifyPassword('not-123456', legacyAdminHash),
        isFalse,
      );
    });
  });

  group('internal tax calculation', () {
    test('calculates from the configured percent with cent rounding', () {
      expect(InternalTax.calculate(100, 15), 15.0);
      expect(InternalTax.calculate(19.99, 7.5), 1.5);
      expect(InternalTax.calculate(0.01, 50), 0.01);
      expect(InternalTax.calculate(100, 0), 0.0);
    });

    test('rejects invalid tax percentages and preserves company settings', () {
      expect(() => InternalTax.calculate(100, 100.01), throwsArgumentError);
      expect(() => InternalTax.calculate(-1, 15), throwsArgumentError);

      final company = CompanyInfo.fromMap({
        'name_ar': 'شركة اختبار',
        'tax_rate': 7.5,
      });
      expect(company.taxRate, 7.5);
      expect(company.toMap()['tax_rate'], 7.5);
    });
  });

  group('user permissions', () {
    test(
      'explicit screen permissions override role defaults only for that screen',
      () {
        PermissionRuntime.activate(
          userId: 42,
          role: 'Accountant',
          permissionRows: [
            {
              'screen_name': 'properties',
              'can_view': 1,
              'can_add': 0,
              'can_edit': 1,
              'can_delete': 0,
              'can_print': 0,
              'can_post': 0,
            },
          ],
        );
        expect(
          PermissionRuntime.allows('properties', AppPermissionAction.view),
          isTrue,
        );
        expect(
          PermissionRuntime.allows('properties', AppPermissionAction.add),
          isFalse,
        );
        expect(
          PermissionRuntime.allows('properties', AppPermissionAction.edit),
          isTrue,
        );
        expect(
          PermissionRuntime.allows('accounting', AppPermissionAction.view),
          isTrue,
        );
        expect(
          PermissionRuntime.allows('system_settings', AppPermissionAction.view),
          isFalse,
        );
        PermissionRuntime.activate(
          userId: 1,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
      },
    );

    test(
      'tenant receipt detail reads require tenant finance view, not voucher history view',
      () async {
        PermissionRuntime.activate(
          userId: 42,
          role: 'Accountant',
          permissionRows: [
            {
              'screen_name': 'tenant_financial',
              'can_view': 1,
              'can_add': 0,
              'can_edit': 0,
              'can_delete': 0,
              'can_print': 0,
              'can_post': 0,
            },
            {
              'screen_name': 'voucher_history',
              'can_view': 0,
              'can_add': 0,
              'can_edit': 0,
              'can_delete': 0,
              'can_print': 0,
              'can_post': 0,
            },
          ],
        );
        try {
          expect(
            await DatabaseHelper.instance.getTenantReceiptVoucherDetails(-1),
            isNull,
          );
          await expectLater(
            DatabaseHelper.instance.getVoucherDetails(-1),
            throwsStateError,
          );
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
        }
      },
    );

    test(
      'legacy roles receive documented defaults for each permission action',
      () {
        PermissionRuntime.activate(
          userId: 42,
          role: 'Accountant',
          permissionRows: const [],
        );
        expect(
          PermissionRuntime.allows('accounting', AppPermissionAction.post),
          isTrue,
        );
        expect(
          PermissionRuntime.allows('accounting', AppPermissionAction.delete),
          isFalse,
        );
        expect(
          PermissionRuntime.allows('reports', AppPermissionAction.print),
          isTrue,
        );

        PermissionRuntime.activate(
          userId: 43,
          role: 'DataEntry',
          permissionRows: const [],
        );
        expect(
          PermissionRuntime.allows('properties', AppPermissionAction.add),
          isTrue,
        );
        expect(
          PermissionRuntime.allows(
            'tenant_financial',
            AppPermissionAction.view,
          ),
          isFalse,
        );
        expect(
          PermissionRuntime.allows('leasing', AppPermissionAction.post),
          isFalse,
        );
        PermissionRuntime.activate(
          userId: 1,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
      },
    );

    test(
      'SMS send permission is checked before any external request',
      () async {
        final provider = SmsProvider();
        PermissionRuntime.activate(
          userId: 42,
          role: 'DataEntry',
          permissionRows: const [],
        );
        try {
          await expectLater(
            provider.sendMessage(
              recipientNumber: '+15555550123',
              messageText: 'اختبار صلاحية فقط',
            ),
            throwsA(isA<StateError>()),
          );
          expect(provider.logs, isEmpty);
        } finally {
          provider.dispose();
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
        }
      },
    );

    test(
      'SMS credentials are editor-only and cleared with the session',
      () async {
        final db = await DatabaseHelper.instance.database;
        final provider = SmsProvider();
        await db.delete('sms_logs');
        await db.delete('sms_settings');
        await db.insert('sms_settings', {
          'api_url': 'https://sms.example.test/send',
          'api_key': 'test-secret-token',
          'sender_name': 'Aqari',
          'reminder_template': 'Reminder',
          'receipt_template': 'Receipt',
        });
        await db.insert('sms_logs', {
          'recipient_number': '+15555550123',
          'message_text': 'Sensitive test log',
          'sent_at': DateTime.now().toIso8601String(),
          'status': 'Accepted',
        });

        try {
          provider.syncAuthorization(userId: 1, canViewSms: true);
          await provider.loadSmsData();
          expect(provider.settings?.containsKey('api_key'), isFalse);
          expect(provider.logs, hasLength(1));

          await provider.saveSettings({
            'api_url': 'https://sms.example.test/send',
            'api_key': 'test-secret-token',
            'sender_name': 'Aqari Updated',
            'reminder_template': 'Reminder',
            'receipt_template': 'Receipt',
          });
          expect(provider.settings?.containsKey('api_key'), isFalse);
          expect(
            (await DatabaseHelper.instance
                .getSmsSettingsForEditing())?['api_key'],
            'test-secret-token',
          );

          PermissionRuntime.activate(
            userId: 44,
            role: 'DataEntry',
            permissionRows: [
              {
                'screen_name': 'sms',
                'can_view': 1,
                'can_add': 0,
                'can_edit': 0,
                'can_delete': 0,
                'can_print': 0,
                'can_post': 0,
              },
            ],
          );
          await expectLater(
            DatabaseHelper.instance.getSmsSettingsForEditing(),
            throwsA(isA<StateError>()),
          );

          provider.syncAuthorization(userId: null, canViewSms: false);
          expect(provider.settings, isNull);
          expect(provider.logs, isEmpty);
        } finally {
          provider.dispose();
          await db.delete('sms_logs');
          await db.delete('sms_settings');
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
        }
      },
    );

    test('clearing report data invalidates in-flight report queries', () async {
      final reports = ReportsProvider();
      try {
        final search = reports.search('no matching record expected');
        reports.clearReportResults(notify: false);
        await search;
        expect(reports.searchResults, isEmpty);

        final occupancy = reports.loadOccupancyStats();
        reports.clearReportResults(notify: false);
        await occupancy;
        expect(reports.occupancyStats, isEmpty);

        final statement = reports.loadAccountStatement(
          1,
          '2026-01-01',
          '2026-12-31',
        );
        reports.clearReportResults(notify: false);
        await statement;
        expect(reports.accountStatement, isEmpty);
        expect(reports.accountOpeningBalance, 0);
      } finally {
        reports.dispose();
      }
    });

    test(
      'stale full property load cannot replace the leasing-only projection',
      () async {
        final pendingFullLoad = Completer<PropertyDataSnapshot>();
        final provider = PropertyProvider(
          fullDataLoader: () => pendingFullLoad.future,
          leasingDataLoader: () async => [
            {'id': 81, 'name': 'اسم العقار فقط'},
          ],
        );
        try {
          final fullLoad = provider.loadInitialData();
          await provider.loadForLeasing();
          pendingFullLoad.complete(
            PropertyDataSnapshot(
              owners: [
                {'id': 4, 'name': 'بيانات مالك خاصة'},
              ],
              properties: [
                {
                  'id': 81,
                  'name': 'اسم العقار فقط',
                  'owner_name': 'بيانات مالك خاصة',
                },
              ],
              cities: const [],
              propertyTypes: const [],
              unitTypes: const [],
              costCenters: const [],
            ),
          );
          await fullLoad;

          expect(provider.owners, isEmpty);
          expect(provider.properties, [
            {'id': 81, 'name': 'اسم العقار فقط'},
          ]);
          expect(provider.isLoading, isFalse);
        } finally {
          provider.dispose();
        }
      },
    );

    test(
      'least-privilege roles cannot read unrelated records or account balances',
      () async {
        final db = await DatabaseHelper.instance.database;
        final accountId = await db.insert('accounts', {
          'code': 'PERM-TEST-${DateTime.now().microsecondsSinceEpoch}',
          'name': 'حساب اختبار صلاحيات',
          'account_type': 'Asset',
          'balance': 98765.43,
        });
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final ownerName = 'مالك اختبار $suffix';
        await DatabaseHelper.instance.insertOwnerWithAccount({
          'name': ownerName,
          'identity_number': 'OWNER-ID-$suffix',
          'mobile': '0550000000',
          'iban': 'SA0000000000000000000000',
          'commission_rate': 0,
        });
        final owner = (await db.query(
          'owners',
          where: 'name = ?',
          whereArgs: [ownerName],
          limit: 1,
        )).single;
        final ownerId = owner['id'] as int;
        final ownerAccountId = owner['account_id'] as int;
        final propertyName = 'عقار اختبار $suffix';
        final propertyId = await DatabaseHelper.instance.insertProperty({
          'name': propertyName,
          'owner_id': ownerId,
        });
        await DatabaseHelper.instance.insertUnit({
          'property_id': propertyId,
          'unit_number': 'PERM-$suffix',
          'default_rent': 100,
          'default_rent_period': 'monthly',
        });
        final accountingProvider = AccountingProvider();
        final propertyProvider = PropertyProvider();
        await accountingProvider.loadAccounts();
        expect(
          accountingProvider.accounts.any(
            (account) =>
                account['id'] == accountId && account.containsKey('balance'),
          ),
          isTrue,
        );
        PermissionRuntime.activate(
          userId: 42,
          role: 'DataEntry',
          permissionRows: [
            {
              'screen_name': 'sms',
              'can_view': 1,
              'can_add': 1,
              'can_edit': 0,
              'can_delete': 0,
              'can_print': 0,
              'can_post': 0,
            },
            for (final module in const [
              'leasing',
              'tenant_financial',
              'properties',
              'accounting',
              'lookups',
              'reports',
              'system_services',
            ])
              {
                'screen_name': module,
                'can_view': 0,
                'can_add': 0,
                'can_edit': 0,
                'can_delete': 0,
                'can_print': 0,
                'can_post': 0,
              },
          ],
        );
        try {
          await expectLater(
            DatabaseHelper.instance.getAllTenants(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getAllContracts(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getDueInstallments(3),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getAllOwners(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getProperties(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getUnitsForProperty(1),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getLookupData('users'),
            throwsArgumentError,
          );
          await expectLater(
            DatabaseHelper.instance.insertLookupData('accounts', const {}),
            throwsArgumentError,
          );
          await expectLater(
            DatabaseHelper.instance.getLookupData('cost_centers'),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getAllAccounts(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getAccountById(accountId),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.recordAuthenticationAudit(
              expectedUserId: 1,
              isLogin: true,
            ),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getAuthenticationRecordByUsername('admin'),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getUserPermissionsForAuthentication(1),
            throwsA(isA<StateError>()),
          );

          PermissionRuntime.activate(
            userId: 46,
            role: 'DataEntry',
            permissionRows: [
              {
                'screen_name': 'reports',
                'can_view': 1,
                'can_add': 0,
                'can_edit': 0,
                'can_delete': 0,
                'can_print': 1,
                'can_post': 0,
              },
              for (final module in const [
                'dashboard',
                'system_settings',
                'lookups',
                'properties',
                'leasing',
                'tenant_financial',
                'accounting',
                'sms',
                'system_services',
                'voucher_history',
              ])
                {
                  'screen_name': module,
                  'can_view': 0,
                  'can_add': 0,
                  'can_edit': 0,
                  'can_delete': 0,
                  'can_print': 0,
                  'can_post': 0,
                },
            ],
          );
          final reportAccounts = await DatabaseHelper.instance.getAllAccounts();
          expect(
            reportAccounts.any((account) => account['id'] == accountId),
            isTrue,
          );
          expect(
            reportAccounts.every((account) => !account.containsKey('balance')),
            isTrue,
          );
          expect(
            (await DatabaseHelper.instance.getAccountById(
              accountId,
            ))!.containsKey('balance'),
            isFalse,
          );
          expect(
            await DatabaseHelper.instance.getAccountOpeningBalance(
              accountId,
              '2000-01-01',
            ),
            0,
          );
          expect(
            await DatabaseHelper.instance.getAccountStatement(
              accountId,
              '2000-01-01',
              '2100-01-01',
            ),
            isEmpty,
          );

          PermissionRuntime.activate(
            userId: 44,
            role: 'DataEntry',
            permissionRows: [
              {
                'screen_name': 'leasing',
                'can_view': 1,
                'can_add': 0,
                'can_edit': 0,
                'can_delete': 0,
                'can_print': 0,
                'can_post': 0,
              },
              for (final module in const [
                'properties',
                'tenant_financial',
                'accounting',
                'lookups',
                'reports',
                'system_services',
                'sms',
              ])
                {
                  'screen_name': module,
                  'can_view': 0,
                  'can_add': 0,
                  'can_edit': 0,
                  'can_delete': 0,
                  'can_print': 0,
                  'can_post': 0,
                },
            ],
          );
          final leasingProperties = await DatabaseHelper.instance
              .getPropertiesForLeasing();
          await propertyProvider.loadForLeasing();
          final leasingProperty = leasingProperties.singleWhere(
            (item) => item['id'] == propertyId,
          );
          expect(leasingProperty.keys.toSet(), {'id', 'name'});
          expect(leasingProperty['name'], propertyName);
          expect(propertyProvider.errorMessage, isNull);
          expect(propertyProvider.owners, isEmpty);
          expect(propertyProvider.properties, hasLength(1));
          expect(propertyProvider.properties.single.keys.toSet(), {
            'id',
            'name',
          });
          await expectLater(
            DatabaseHelper.instance.getAllOwners(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getProperties(),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            DatabaseHelper.instance.getUnitsForProperty(propertyId),
            throwsA(isA<StateError>()),
          );

          PermissionRuntime.activate(
            userId: 43,
            role: 'DataEntry',
            permissionRows: [
              {
                'screen_name': 'tenant_financial',
                'can_view': 1,
                'can_add': 0,
                'can_edit': 0,
                'can_delete': 0,
                'can_print': 0,
                'can_post': 0,
              },
              for (final module in const [
                'accounting',
                'leasing',
                'reports',
                'system_services',
                'lookups',
                'properties',
                'sms',
              ])
                {
                  'screen_name': module,
                  'can_view': 0,
                  'can_add': 0,
                  'can_edit': 0,
                  'can_delete': 0,
                  'can_print': 0,
                  'can_post': 0,
                },
            ],
          );
          final financialAccounts = await DatabaseHelper.instance
              .getAllAccounts();
          await accountingProvider.loadAccounts();
          expect(
            financialAccounts.any((account) => account['id'] == accountId),
            isTrue,
          );
          expect(
            financialAccounts.every(
              (account) => !account.containsKey('balance'),
            ),
            isTrue,
          );
          expect(
            (await DatabaseHelper.instance.getAccountById(
              accountId,
            ))!.containsKey('balance'),
            isFalse,
          );
          expect(
            accountingProvider.accounts.every(
              (account) => !account.containsKey('balance'),
            ),
            isTrue,
          );
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
          await db.delete(
            'units',
            where: 'property_id = ?',
            whereArgs: [propertyId],
          );
          await db.delete(
            'properties',
            where: 'id = ?',
            whereArgs: [propertyId],
          );
          await db.delete('owners', where: 'id = ?', whereArgs: [ownerId]);
          await db.delete(
            'accounts',
            where: 'id = ?',
            whereArgs: [ownerAccountId],
          );
          await db.delete('accounts', where: 'id = ?', whereArgs: [accountId]);
          accountingProvider.dispose();
          propertyProvider.dispose();
        }
      },
    );

    test(
      'view-only settings permission cannot export a database backup',
      () async {
        PermissionRuntime.activate(
          userId: 42,
          role: 'Admin',
          permissionRows: [
            {
              'screen_name': 'system_settings',
              'can_view': 1,
              'can_add': 0,
              'can_edit': 0,
              'can_delete': 0,
              'can_print': 0,
              'can_post': 0,
            },
          ],
        );
        try {
          expect(
            PermissionRuntime.allows(
              'system_settings',
              AppPermissionAction.view,
            ),
            isTrue,
          );
          expect(
            PermissionRuntime.allows(
              'system_settings',
              AppPermissionAction.edit,
            ),
            isFalse,
          );
          await expectLater(
            DatabaseHelper.instance.backupToFile('/tmp/aqari-denied-backup.db'),
            throwsA(isA<StateError>()),
          );
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
        }
      },
    );

    test(
      'permission rows save atomically and can be cleared back to role defaults',
      () async {
        final username =
            'permission_test_${DateTime.now().microsecondsSinceEpoch}';
        final userId = await DatabaseHelper.instance.insertUser({
          'username': username,
          'full_name': 'مستخدم اختبار الصلاحيات',
          'password_hash': CryptoUtils.hashPassword('Test-password-1234'),
          'role': 'DataEntry',
        });
        try {
          final savedUser = (await DatabaseHelper.instance.getAllUsers())
              .singleWhere((user) => user['id'] == userId);
          expect(savedUser['must_change_password'], 1);
          await expectLater(
            DatabaseHelper.instance.replaceUserPermissions(userId, [
              {
                'screen_name': 'accounting',
                'can_view': false,
                'can_add': false,
                'can_edit': false,
                'can_delete': false,
                'can_print': true,
                'can_post': false,
              },
            ]),
            throwsA(isA<ArgumentError>()),
          );
          await DatabaseHelper.instance.replaceUserPermissions(userId, [
            {
              'screen_name': 'accounting',
              'can_view': true,
              'can_add': false,
              'can_edit': false,
              'can_delete': false,
              'can_print': true,
              'can_post': false,
            },
          ]);
          final saved = await DatabaseHelper.instance.getUserPermissions(
            userId,
          );
          expect(saved, hasLength(1));
          expect(saved.single['screen_name'], 'accounting');
          expect(saved.single['can_view'], 1);
          expect(saved.single['can_print'], 1);

          await DatabaseHelper.instance.replaceUserPermissions(userId, []);
          expect(
            await DatabaseHelper.instance.getUserPermissions(userId),
            isEmpty,
          );
        } finally {
          await DatabaseHelper.instance.deleteUser(userId);
        }
      },
    );

    test(
      'login loads custom permissions and logout clears the runtime session',
      () async {
        final username =
            'permission_login_${DateTime.now().microsecondsSinceEpoch}';
        final userId = await DatabaseHelper.instance.insertUser({
          'username': username,
          'full_name': 'مستخدم جلسة اختبار',
          'password_hash': CryptoUtils.hashPassword('Test-password-1234'),
          'role': 'DataEntry',
        });
        final auth = AuthProvider();
        try {
          await DatabaseHelper.instance.replaceUserPermissions(userId, [
            {
              'screen_name': 'accounting',
              'can_view': true,
              'can_add': false,
              'can_edit': false,
              'can_delete': false,
              'can_print': true,
              'can_post': false,
            },
          ]);
          expect(await auth.login(username, 'Test-password-1234'), isTrue);
          expect(auth.currentUser?.mustChangePassword, isTrue);
          expect(
            auth.currentUser?.toMap().containsKey('password_hash'),
            isFalse,
          );
          expect(auth.canAccessScreen('accounting'), isTrue);
          expect(
            auth.canPerform('accounting', AppPermissionAction.post),
            isFalse,
          );
          final db = await DatabaseHelper.instance.database;
          await db.update(
            'user_permissions',
            {'can_view': 0, 'can_print': 0},
            where: 'user_id = ? AND screen_name = ?',
            whereArgs: [userId, 'accounting'],
          );
          await auth.refreshCurrentUserPermissions();
          expect(auth.canAccessScreen('accounting'), isFalse);
          final pendingRefresh = auth.refreshCurrentUserPermissions();
          await auth.logout();
          await pendingRefresh;
          expect(PermissionRuntime.hasSession, isFalse);
          expect(auth.canAccessScreen('accounting'), isFalse);
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
          final db = await DatabaseHelper.instance.database;
          await db.delete(
            'audit_logs',
            where: 'user_id = ?',
            whereArgs: [userId],
          );
          await DatabaseHelper.instance.deleteUser(userId);
          auth.dispose();
        }
      },
    );

    test('a stale login cannot replace a newer session', () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final firstName = 'older_login_$suffix';
      final secondName = 'newer_login_$suffix';
      final password = 'Test-password-1234';
      final firstId = await DatabaseHelper.instance.insertUser({
        'username': firstName,
        'full_name': 'محاولة الدخول الأقدم',
        'password_hash': CryptoUtils.hashPassword(password),
        'role': 'DataEntry',
      });
      final secondId = await DatabaseHelper.instance.insertUser({
        'username': secondName,
        'full_name': 'محاولة الدخول الأحدث',
        'password_hash': CryptoUtils.hashPassword(password),
        'role': 'Admin',
      });
      final auth = AuthProvider();
      try {
        final olderAttempt = auth.login(firstName, password);
        final newerAttempt = auth.login(secondName, password);
        expect(await newerAttempt, isTrue);
        expect(await olderAttempt, isFalse);
        expect(auth.currentUser?.username, secondName);
        expect(PermissionRuntime.userId, secondId);
      } finally {
        await auth.logout();
        auth.dispose();
        PermissionRuntime.activate(
          userId: 1,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
        final db = await DatabaseHelper.instance.database;
        await db.delete(
          'audit_logs',
          where: 'user_id IN (?, ?)',
          whereArgs: [firstId, secondId],
        );
        await DatabaseHelper.instance.deleteUser(firstId);
        await DatabaseHelper.instance.deleteUser(secondId);
      }
    });

    test(
      'an in-flight login cannot activate permissions after dispose',
      () async {
        final username =
            'disposed_login_${DateTime.now().microsecondsSinceEpoch}';
        final userId = await DatabaseHelper.instance.insertUser({
          'username': username,
          'full_name': 'تسجيل دخول منتهي للاختبار',
          'password_hash': CryptoUtils.hashPassword('Test-password-1234'),
          'role': 'DataEntry',
        });
        final auth = AuthProvider();
        final loginFuture = auth.login(username, 'Test-password-1234');
        auth.dispose();
        try {
          expect(await loginFuture, isFalse);
          expect(auth.currentUser, isNull);
          expect(PermissionRuntime.hasSession, isFalse);
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
          final db = await DatabaseHelper.instance.database;
          await db.delete(
            'audit_logs',
            where: 'user_id = ?',
            whereArgs: [userId],
          );
          await DatabaseHelper.instance.deleteUser(userId);
        }
      },
    );

    test(
      'deactivated users cannot log in and can be reactivated safely',
      () async {
        final username =
            'inactive_user_${DateTime.now().microsecondsSinceEpoch}';
        final password = 'Test-password-1234';
        final userId = await DatabaseHelper.instance.insertUser({
          'username': username,
          'full_name': 'حساب موقوف للاختبار',
          'password_hash': CryptoUtils.hashPassword(password),
          'role': 'DataEntry',
        });
        final auth = AuthProvider();
        try {
          await DatabaseHelper.instance.setUserActive(userId, false);
          expect(
            (await (await DatabaseHelper.instance.database).query(
              'users',
              columns: ['is_active'],
              where: 'id = ?',
              whereArgs: [userId],
              limit: 1,
            )).single['is_active'],
            0,
          );
          expect(await auth.login(username, password), isFalse);
          expect(auth.errorMessage, contains('الحساب موقوف'));
          expect(PermissionRuntime.hasSession, isFalse);

          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
          await DatabaseHelper.instance.setUserActive(userId, true);
          expect(await auth.login(username, password), isTrue);
          final db = await DatabaseHelper.instance.database;
          await db.update(
            'users',
            {'is_active': 0},
            where: 'id = ?',
            whereArgs: [userId],
          );
          await auth.refreshCurrentUserPermissions();
          expect(auth.currentUser, isNull);
          expect(PermissionRuntime.hasSession, isFalse);
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
          final db = await DatabaseHelper.instance.database;
          await db.delete(
            'audit_logs',
            where: 'user_id = ?',
            whereArgs: [userId],
          );
          await DatabaseHelper.instance.deleteUser(userId);
          auth.dispose();
        }
      },
    );

    test('disposing auth invalidates an in-flight session refresh', () async {
      final username = 'disposed_auth_${DateTime.now().microsecondsSinceEpoch}';
      final userId = await DatabaseHelper.instance.insertUser({
        'username': username,
        'full_name': 'جلسة التخلص للاختبار',
        'password_hash': CryptoUtils.hashPassword('Test-password-1234'),
        'role': 'DataEntry',
      });
      final auth = AuthProvider();
      var disposed = false;
      try {
        expect(await auth.login(username, 'Test-password-1234'), isTrue);
        final pendingRefresh = auth.refreshCurrentUserPermissions();
        auth.dispose();
        disposed = true;
        await pendingRefresh;
        expect(auth.currentUser, isNull);
        expect(PermissionRuntime.hasSession, isFalse);
      } finally {
        if (!disposed) auth.dispose();
        PermissionRuntime.activate(
          userId: 1,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
        final db = await DatabaseHelper.instance.database;
        await db.delete(
          'audit_logs',
          where: 'user_id = ?',
          whereArgs: [userId],
        );
        await DatabaseHelper.instance.deleteUser(userId);
      }
    });

    test(
      'database writes reject an unauthorized role even when called directly',
      () async {
        PermissionRuntime.activate(
          userId: 42,
          role: 'DataEntry',
          permissionRows: const [],
        );
        try {
          expect(
            PermissionRuntime.allows('accounting', AppPermissionAction.view),
            isFalse,
          );
          await expectLater(
            DatabaseHelper.instance.insertAccount({
              'code': 'TEST-DENIED',
              'name': 'يجب رفضه',
              'account_type': 'Asset',
            }),
            throwsA(isA<StateError>()),
          );
          expect(
            await (await DatabaseHelper.instance.database).query(
              'accounts',
              where: 'code = ?',
              whereArgs: ['TEST-DENIED'],
            ),
            isEmpty,
          );
        } finally {
          PermissionRuntime.activate(
            userId: 1,
            role: 'SuperAdmin',
            permissionRows: const [],
          );
        }
      },
    );
    test('a user cannot replace their own permissions', () async {
      await expectLater(
        DatabaseHelper.instance.replaceUserPermissions(1, []),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'only a superadmin can manage superadmin roles, and the last remains',
      () async {
        PermissionRuntime.activate(
          userId: 42,
          role: 'Admin',
          permissionRows: [
            {
              'screen_name': 'system_settings',
              'can_view': 1,
              'can_add': 1,
              'can_edit': 1,
              'can_delete': 1,
              'can_print': 1,
              'can_post': 1,
            },
          ],
        );
        await expectLater(
          DatabaseHelper.instance.updateUser({'id': 1, 'role': 'Admin'}),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          DatabaseHelper.instance.deleteUser(1),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          DatabaseHelper.instance.updateUserPassword(
            1,
            CryptoUtils.hashPassword('unauthorized-reset-password'),
          ),
          throwsA(isA<StateError>()),
        );

        PermissionRuntime.activate(
          userId: 42,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
        await expectLater(
          DatabaseHelper.instance.updateUser({'id': 1, 'role': 'Admin'}),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          DatabaseHelper.instance.deleteUser(1),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          DatabaseHelper.instance.setUserActive(1, false),
          throwsA(isA<StateError>()),
        );
        PermissionRuntime.activate(
          userId: 1,
          role: 'SuperAdmin',
          permissionRows: const [],
        );
      },
    );
  });

  group('company logo files', () {
    test('accepts a JPG extension with a JPEG signature', () {
      final jpeg = img.encodeJpg(img.Image(width: 2, height: 2));
      expect(CompanyLogoStorage.validateBytes('company.JPG', jpeg), isNull);
      expect(CompanyLogoStorage.validateBytes('company.jpeg', jpeg), isNull);
      expect(
        CompanyLogoStorage.validateBytes('company.jpg', [0x89, 0x50, 0x4e]),
        contains('لا يطابق'),
      );
      expect(
        CompanyLogoStorage.validateBytes('broken.jpg', [
          0xff,
          0xd8,
          0xff,
          0xe0,
          0x00,
        ]),
        contains('تعذر فك ترميز الصورة'),
      );
      expect(
        CompanyLogoStorage.validateBytes('company.gif', jpeg),
        contains('PNG أو JPG'),
      );
      expect(
        CompanyLogoStorage.validateBytes(
          'company.jpg',
          Uint8List(CompanyLogoStorage.maxBytes + 1),
        ),
        contains('8 ميغابايت'),
      );
    });

    test(
      'stores candidate logos privately and deletes only managed files',
      () async {
        final support = await Directory.systemTemp.createTemp(
          'aqari-logo-storage-test-',
        );
        final jpeg = img.encodeJpg(img.Image(width: 2, height: 2));
        final outside = File('${support.path}/not-managed.jpg');
        try {
          final saved = await CompanyLogoStorage.saveCandidate(
            fileName: 'valid.jpg',
            bytes: jpeg,
            supportDirectory: support.path,
          );
          expect(await saved.exists(), isTrue);
          expect(
            saved.path,
            contains(
              '${Platform.pathSeparator}branding${Platform.pathSeparator}',
            ),
          );
          expect(saved.path.toLowerCase().endsWith('.jpg'), isTrue);
          expect(await saved.readAsBytes(), jpeg);

          await outside.writeAsBytes(jpeg);
          await CompanyLogoStorage.deleteManagedFile(
            outside.path,
            supportDirectory: support.path,
          );
          expect(await outside.exists(), isTrue);

          await CompanyLogoStorage.deleteManagedFile(
            saved.path,
            supportDirectory: support.path,
          );
          expect(await saved.exists(), isFalse);
        } finally {
          await support.delete(recursive: true);
        }
      },
    );
  });

  test('PDF direction preserves RTL Arabic fallbacks and LTR dates', () {
    expect(
      PrintUtils.resolveTextDirection(
        'غير مدون',
        preferred: pw.TextDirection.ltr,
      ),
      pw.TextDirection.rtl,
    );
    expect(PrintUtils.resolveTextDirection('2026/11/10'), pw.TextDirection.ltr);
  });

  test('spells receipt amounts in Arabic using the selected currency', () {
    expect(
      ArabicAmountWords.format(1220, 'ريال سعودي'),
      'ألف ومئتان وعشرون ريال سعودي',
    );
    expect(ArabicAmountWords.format(1, 'ريال سعودي'), 'ريال سعودي واحد');
    expect(ArabicAmountWords.format(2, 'ريال سعودي'), 'ريالان سعوديان');
    expect(
      ArabicAmountWords.format(10.5, 'ريال سعودي'),
      'عشرة ريالات سعودية وخمسون هللة',
    );
  });

  test('lease terms prefer saved settings and strip display numbering', () {
    expect(LeaseContractTerms.defaultClauses, hasLength(8));
    expect(LeaseContractTerms.resolve('شرط خاص للمؤسسة\n2. شرط ثانٍ'), [
      'شرط خاص للمؤسسة',
      'شرط ثانٍ',
    ]);
    expect(LeaseContractTerms.resolve('١. بند مرقم بالأرقام العربية'), [
      'بند مرقم بالأرقام العربية',
    ]);
    expect(LeaseContractTerms.resolve('  '), LeaseContractTerms.defaultClauses);
  });

  test(
    'v11 migration preserves legacy units and blocks new duplicates',
    () async {
      sqfliteFfiInit();
      final path =
          '${Directory.systemTemp.path}/aqari-v11-migration-${DateTime.now().microsecondsSinceEpoch}.db';
      final oldDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE units (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              property_id INTEGER NOT NULL,
              unit_number TEXT NOT NULL,
              floor TEXT
            )
          ''');
            await db.execute('''
            CREATE TABLE contracts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id INTEGER NOT NULL,
              rent_amount REAL NOT NULL
            )
          ''');
            await db.insert('units', {
              'property_id': 41,
              'unit_number': 'DUP-01',
              'floor': 'الأرضي',
            });
            await db.insert('units', {
              'property_id': 41,
              'unit_number': ' dup-01 ',
              'floor': 'الأول',
            });
            await db.insert('contracts', {'unit_id': 1, 'rent_amount': 1000.0});
          },
        ),
      );
      await oldDb.close();

      final migratedDb = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 12,
          onUpgrade: (db, oldVersion, newVersion) async {
            expect(oldVersion, 11);
            expect(newVersion, 12);
            await DatabaseIntegrityMigrations.upgradeToV12(db);
          },
        ),
      );
      try {
        expect(
          (await migratedDb.rawQuery(
            'PRAGMA user_version',
          )).single.values.single,
          12,
        );
        final contractColumns = (await migratedDb.rawQuery(
          'PRAGMA table_info(contracts)',
        )).map((row) => row['name']).toSet();
        expect(contractColumns, contains('party_snapshot'));
        expect(await migratedDb.query('units'), hasLength(2));
        expect(await migratedDb.query('contracts'), hasLength(1));
        await expectLater(
          migratedDb.insert('units', {
            'property_id': 41,
            'unit_number': 'DUP-01',
          }),
          throwsA(isA<Exception>()),
        );
        await migratedDb.update(
          'units',
          {'unit_number': 'DUP-01', 'floor': 'الثاني'},
          where: 'id = ?',
          whereArgs: [1],
        );
        await migratedDb.update(
          'units',
          {'unit_number': 'LEGACY-01'},
          where: 'id = ?',
          whereArgs: [1],
        );
        expect(
          (await migratedDb.query(
            'units',
            where: 'id = ?',
            whereArgs: [1],
          )).single['unit_number'],
          'LEGACY-01',
        );
        expect(await migratedDb.query('units'), hasLength(2));
      } finally {
        await migratedDb.close();
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    },
  );

  test(
    'creates a valid Arabic voucher PDF and a consistent SQLite backup',
    () async {
      final db = await DatabaseHelper.instance.database;
      final info = await DatabaseHelper.instance.getCompanyInfo();
      expect(info?['name_ar'], isNotEmpty);
      expect(info?['terms_conditions'], LeaseContractTerms.defaultText);
      final tenantColumns = (await db.rawQuery(
        'PRAGMA table_info(tenants)',
      )).map((row) => row['name']).toSet();
      final ownerColumns = (await db.rawQuery(
        'PRAGMA table_info(owners)',
      )).map((row) => row['name']).toSet();
      final unitColumns = (await db.rawQuery(
        'PRAGMA table_info(units)',
      )).map((row) => row['name']).toSet();
      final contractColumns = (await db.rawQuery(
        'PRAGMA table_info(contracts)',
      )).map((row) => row['name']).toSet();
      final voucherColumns = (await db.rawQuery(
        'PRAGMA table_info(vouchers)',
      )).map((row) => row['name']).toSet();
      final voucherTables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(
        tenantColumns,
        containsAll(['identity_issue_date', 'identity_source', 'profession']),
      );
      expect(
        ownerColumns,
        containsAll(['identity_issue_date', 'identity_source']),
      );
      expect(unitColumns, containsAll(['default_rent', 'default_rent_period']));
      expect(
        contractColumns,
        containsAll([
          'purpose',
          'electricity_reading',
          'unit_rent_amount',
          'unit_rent_period',
          'party_snapshot',
          'cancellation_reason',
          'cancelled_at',
        ]),
      );
      expect(
        voucherColumns,
        containsAll(['party_name', 'period_from_date', 'period_to_date']),
      );
      expect(voucherTables, contains('voucher_installment_allocations'));

      final summary = await DatabaseHelper.instance.getDashboardSummary();
      expect(summary['properties_count'], 0);
      expect(summary['units_count'], 0);

      final pdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: 17,
        date: '2026-11-10',
        targetName: 'مستأجر تجريبي',
        amount: 1250.50,
        paymentMethod: 'نقداً',
        accountName: 'الصندوق الرئيسي',
        description: 'دفعة إيجار اختبارية',
      );
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
      expect(latin1.decode(pdf), contains('AqariPDFArabic'));
      final detailedVoucherPdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: 18,
        date: '2026-11-10',
        targetName: 'مستأجر تجريبي',
        amount: 1250.50,
        accountName: '',
        description: 'دفعة إيجار اختبارية',
        periodStartDate: '2026-11-01',
        periodEndDate: '2026-11-30',
        journalLines: [
          {'account_name': 'الصندوق الرئيسي', 'debit': 1250.5, 'credit': 0},
          {'account_name': 'حساب المستأجر', 'debit': 0, 'credit': 1250.5},
        ],
        installmentAllocations: [
          {
            'property_name': 'عقار الاختبار',
            'unit_number': '1',
            'due_date': '2026-11-10',
            'installment_amount': 1250.5,
            'allocated_amount': 1250.5,
          },
        ],
      );
      expect(String.fromCharCodes(detailedVoucherPdf.take(5)), '%PDF-');
      expect(detailedVoucherPdf.length, greaterThan(pdf.length));
      expect(PrintUtils.suggestedPdfName('سند قبض/17'), 'سند_قبض_17.pdf');
      expect(PrintUtils.currencyInArabic('YER'), 'ريال يمني');
      expect(PrintUtils.currencyInArabic('ريال سعودي (SAR)'), 'ريال سعودي');
      expect(
        LeaseContractPdf.formatAmountInWords(3222.5, 'YER'),
        allOf(contains('ريال يمني'), contains('فلس'), isNot(contains('سعودي'))),
      );
      expect(
        LeaseContractPdf.formatAmountInWords(10.5, 'SAR'),
        allOf(contains('ريالات سعودية'), contains('هللة')),
      );

      final backupPath = '$testDocuments/aqari-test-backup.db';
      final secretId = await db.insert('sms_settings', {
        'api_key': 'secret-test-token-must-not-be-backed-up',
      });
      try {
        final dashboardSettings = await DatabaseHelper.instance
            .getSmsSettingsForDashboard();
        expect(dashboardSettings?.containsKey('api_key'), isFalse);
        await DatabaseHelper.instance.backupToFile(backupPath);
        final backup = File(backupPath);
        expect(await backup.exists(), isTrue);
        expect(await backup.length(), greaterThan(0));
        final backupDb = await databaseFactory.openDatabase(
          backupPath,
          options: OpenDatabaseOptions(readOnly: true),
        );
        try {
          final backedUpSmsSettings = await backupDb.query(
            'sms_settings',
            columns: ['api_key'],
          );
          expect(
            backedUpSmsSettings.every((row) => row['api_key'] == null),
            isTrue,
          );
        } finally {
          await backupDb.close();
        }
        expect(
          (await db.query(
            'sms_settings',
            columns: ['api_key'],
            where: 'id = ?',
            whereArgs: [secretId],
          )).single['api_key'],
          'secret-test-token-must-not-be-backed-up',
        );
        await backup.delete();
        await db.rawQuery('PRAGMA integrity_check');
      } finally {
        await db.delete('sms_settings', where: 'id = ?', whereArgs: [secretId]);
        final backup = File(backupPath);
        if (await backup.exists()) await backup.delete();
      }
    },
  );

  test(
    'restores a validated backup and preserves a verified rollback copy',
    () async {
      final db = await DatabaseHelper.instance.database;
      final companyRows = await db.query('company_info', limit: 1);
      expect(companyRows, isNotEmpty);
      final companyId = companyRows.single['id'];
      final originalName = companyRows.single['name_ar'];
      final backupPath = '$testDocuments/aqari-restore-source.db';
      await DatabaseHelper.instance.backupToFile(backupPath);

      await db.update(
        'company_info',
        {'name_ar': 'تغيير مؤقت لاختبار الاستعادة'},
        where: 'id = ?',
        whereArgs: [companyId],
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        'تغيير مؤقت لاختبار الاستعادة',
      );

      final rollbackPath = await DatabaseHelper.instance.restoreFromFile(
        backupPath,
      );
      expect(File(rollbackPath).existsSync(), isTrue);
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      final rollbackDb = await databaseFactory.openDatabase(
        rollbackPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        expect(
          (await rollbackDb.query('company_info', limit: 1)).single['name_ar'],
          'تغيير مؤقت لاختبار الاستعادة',
        );
      } finally {
        await rollbackDb.close();
      }
      await File(backupPath).delete();
      await File(rollbackPath).delete();
    },
  );

  test(
    'rejects a corrupt restore without changing live data or an existing backup',
    () async {
      final db = await DatabaseHelper.instance.database;
      final originalName = (await DatabaseHelper.instance
          .getCompanyInfo())?['name_ar'];
      final corruptPath = '$testDocuments/not-a-database.db';
      await File(corruptPath).writeAsBytes(List<int>.filled(256, 0));

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(corruptPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );
      expect(await db.rawQuery('PRAGMA integrity_check'), isNotEmpty);

      final existingBackupPath = '$testDocuments/do-not-overwrite.db';
      final existingBackup = File(existingBackupPath);
      await existingBackup.writeAsString('preserve-existing-file');
      await expectLater(
        DatabaseHelper.instance.backupToFile(existingBackupPath),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existingBackup.readAsString(), 'preserve-existing-file');
      await File(corruptPath).delete();
      await existingBackup.delete();
    },
  );

  test(
    'rejects incomplete schemas and uncheckpointed WAL backups before replacement',
    () async {
      final originalName = (await DatabaseHelper.instance
          .getCompanyInfo())?['name_ar'];
      final completeBackupPath = '$testDocuments/complete-schema.db';
      final incompleteBackupPath = '$testDocuments/incomplete-schema.db';
      final missingColumnBackupPath =
          '$testDocuments/missing-contract-column.db';
      await DatabaseHelper.instance.backupToFile(completeBackupPath);
      await File(completeBackupPath).copy(incompleteBackupPath);
      final incompleteDb = await databaseFactory.openDatabase(
        incompleteBackupPath,
      );
      await incompleteDb.execute('DROP TABLE sms_logs');
      await incompleteDb.close();

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(incompleteBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      await File(completeBackupPath).copy(missingColumnBackupPath);
      final missingColumnDb = await databaseFactory.openDatabase(
        missingColumnBackupPath,
      );
      await missingColumnDb.execute(
        'ALTER TABLE contracts DROP COLUMN payment_method',
      );
      await missingColumnDb.close();
      await expectLater(
        DatabaseHelper.instance.restoreFromFile(missingColumnBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );

      final walBackupPath = '$testDocuments/wal-pending-backup.db';
      await DatabaseHelper.instance.backupToFile(walBackupPath);
      final walDatabase = await databaseFactory.openDatabase(walBackupPath);
      await walDatabase.rawQuery('PRAGMA journal_mode = WAL');
      await walDatabase.execute(
        'CREATE TABLE committed_in_wal (id INTEGER PRIMARY KEY, value TEXT)',
      );
      await walDatabase.insert('committed_in_wal', {'value': 'committed'});
      expect(File('$walBackupPath-wal').lengthSync(), greaterThan(32));

      await expectLater(
        DatabaseHelper.instance.restoreFromFile(walBackupPath),
        throwsA(isA<StateError>()),
      );
      expect(
        (await DatabaseHelper.instance.getCompanyInfo())?['name_ar'],
        originalName,
      );
      await walDatabase.close();

      for (final path in [
        completeBackupPath,
        incompleteBackupPath,
        missingColumnBackupPath,
        walBackupPath,
      ]) {
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('$path$suffix');
          if (await file.exists()) await file.delete();
        }
      }
    },
  );

  test(
    'upgrades a valid v11 backup during restore before replacing live data',
    () async {
      final sourcePath = '$testDocuments/aqari-v11-restore.db';
      await DatabaseHelper.instance.backupToFile(sourcePath);
      final legacyDatabase = await databaseFactory.openDatabase(sourcePath);
      await legacyDatabase.execute(
        'ALTER TABLE contracts DROP COLUMN party_snapshot',
      );
      await legacyDatabase.execute('ALTER TABLE users DROP COLUMN is_active');
      await legacyDatabase.execute('DROP TRIGGER units_unique_number_insert');
      await legacyDatabase.execute('DROP TRIGGER units_unique_number_update');
      await legacyDatabase.execute('PRAGMA user_version = 11');
      await legacyDatabase.close();

      final rollbackPath = await DatabaseHelper.instance.restoreFromFile(
        sourcePath,
      );
      final restored = await DatabaseHelper.instance.database;
      expect(
        (await restored.rawQuery('PRAGMA user_version')).single.values.single,
        20,
      );
      expect(
        (await restored.rawQuery(
          'PRAGMA table_info(users)',
        )).map((row) => row['name']),
        contains('is_active'),
      );
      expect(
        (await restored.query(
          'users',
          columns: ['is_active'],
          where: 'id = 1',
        )).single['is_active'],
        1,
      );
      expect(
        (await restored.rawQuery(
          'PRAGMA table_info(contracts)',
        )).map((row) => row['name']),
        contains('party_snapshot'),
      );
      expect(
        (await restored.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger'",
        )).map((row) => row['name']),
        containsAll([
          'units_unique_number_insert',
          'units_unique_number_update',
        ]),
      );
      expect(File(rollbackPath).existsSync(), isTrue);
      await File(sourcePath).delete();
      await File(rollbackPath).delete();
    },
  );

  test(
    'unit rent period is explicit and legacy rows are not guessed',
    () async {
      final db = await DatabaseHelper.instance.database;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single.values.single,
        20,
      );

      final ownerId = await db.insert('owners', {'name': 'مالك الدورية'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار اختبار الدورية',
        'owner_id': ownerId,
      });
      final legacyUnitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'LEGACY-01',
        'default_rent': 1200.0,
        'status': 'شاغرة',
      });
      await DatabaseHelper.instance.insertTenantWithAccount({
        'name': 'مستأجر اختبار الدورية',
        'mobile': '777000001',
      });
      final tenantId = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر اختبار الدورية'],
      )).single['id'];
      final contractsBefore = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM contracts',
      )).single['count'];

      await expectLater(
        DatabaseHelper.instance.insertContractWithInstallments(
          {
            'tenant_id': tenantId,
            'unit_id': legacyUnitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-10',
            'rent_amount': 1200.0,
            'payment_method': 'سنوي',
            'status': 'Active',
          },
          [
            {
              'amount': 1200.0,
              'paid_amount': 0.0,
              'due_date': '2026-11-10',
              'status': 'Unpaid',
            },
          ],
        ),
        throwsStateError,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [legacyUnitId],
        )).single['default_rent_period'],
        isNull,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM contracts',
        )).single['count'],
        contractsBefore,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [legacyUnitId],
        )).single['status'],
        'شاغرة',
      );

      await expectLater(
        DatabaseHelper.instance.insertUnit({
          'property_id': propertyId,
          'unit_number': 'NEW-NO-PERIOD',
          'default_rent': 100.0,
        }),
        throwsArgumentError,
      );
      final newUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'NEW-ANNUAL',
        'default_rent': 24000.0,
        'default_rent_period': 'annual',
        'status': 'شاغرة',
      });
      final newUnit = (await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [newUnitId],
      )).single;
      expect(newUnit['default_rent'], 24000.0);
      expect(newUnit['default_rent_period'], 'annual');
    },
  );

  test(
    'entity relationships reject missing parents and duplicate units',
    () async {
      final db = await DatabaseHelper.instance.database;
      final accountCountBefore = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM accounts',
      )).single['count'];

      await expectLater(
        DatabaseHelper.instance.insertOwnerWithAccount({
          'name': '   ',
          'commission_rate': 5.0,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertOwnerWithAccount({
          'name': 'مالك عمولة غير صالحة',
          'commission_rate': 101.0,
        }),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM accounts',
        )).single['count'],
        accountCountBefore,
      );

      await DatabaseHelper.instance.insertOwnerWithAccount({
        'name': 'مالك العلاقات',
        'commission_rate': 0.0,
      });
      final owner = (await db.query(
        'owners',
        where: 'name = ?',
        whereArgs: ['مالك العلاقات'],
      )).single;
      final ownerId = owner['id'] as int;

      await expectLater(
        DatabaseHelper.instance.insertProperty({
          'name': 'عقار بلا مالك صحيح',
          'owner_id': 999999,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertProperty({
          'name': 'عقار بمرجع مدينة غير صحيح',
          'owner_id': ownerId,
          'city_id': 999999,
        }),
        throwsArgumentError,
      );
      final propertyId = await DatabaseHelper.instance.insertProperty({
        'name': 'عقار العلاقات',
        'owner_id': ownerId,
      });

      final firstUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'UNIT-01',
        'default_rent': 1000.0,
        'default_rent_period': 'monthly',
        'status': 'شاغرة',
      });
      await expectLater(
        DatabaseHelper.instance.insertUnit({
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
        }),
        throwsStateError,
      );
      await expectLater(
        db.insert('units', {
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
        }),
        throwsA(isA<Exception>()),
      );
      final secondUnitId = await DatabaseHelper.instance.insertUnit({
        'property_id': propertyId,
        'unit_number': 'UNIT-02',
        'default_rent_period': 'annual',
        'status': 'شاغرة',
      });
      await expectLater(
        DatabaseHelper.instance.updateUnit({
          'id': secondUnitId,
          'unit_number': 'unit-01',
          'default_rent_period': 'annual',
        }),
        throwsStateError,
      );
      expect(
        (await db.query(
          'units',
          where: 'id = ?',
          whereArgs: [firstUnitId],
        )).single['unit_number'],
        'UNIT-01',
      );

      await db.execute('DROP TRIGGER IF EXISTS units_unique_number_insert');
      await db.execute('DROP TRIGGER IF EXISTS units_unique_number_update');
      late final int legacyDuplicateId;
      try {
        legacyDuplicateId = await db.insert('units', {
          'property_id': propertyId,
          'unit_number': ' unit-01 ',
          'default_rent_period': 'annual',
          'status': 'شاغرة',
        });
      } finally {
        await DatabaseIntegrityMigrations.installUnitNumberGuards(db);
      }
      final duplicateRows = await DatabaseHelper.instance.getUnitsForProperty(
        propertyId,
      );
      expect(
        duplicateRows.where((row) => row['has_duplicate_number'] == 1).length,
        2,
      );
      await DatabaseHelper.instance.updateUnit({
        'id': legacyDuplicateId,
        'unit_number': ' unit-01 ',
        'default_rent_period': 'annual',
      });
      await DatabaseHelper.instance.updateUnit({
        'id': legacyDuplicateId,
        'unit_number': 'UNIT-03',
        'default_rent_period': 'annual',
      });
      final resolvedRows = await DatabaseHelper.instance.getUnitsForProperty(
        propertyId,
      );
      expect(
        resolvedRows.every((row) => row['has_duplicate_number'] == 0),
        isTrue,
      );

      final accountsBeforeInvalidTenant = (await db.rawQuery(
        'SELECT COUNT(*) AS count FROM accounts',
      )).single['count'];
      await expectLater(
        DatabaseHelper.instance.insertTenantWithAccount({
          'name': 'مستأجر بجنسية غير موجودة',
          'mobile': '777222333',
          'nationality_id': 999999,
        }),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTenantWithAccount({
          'name': 'اسم فقط',
          'mobile': ' ',
        }),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM accounts',
        )).single['count'],
        accountsBeforeInvalidTenant,
      );

      await expectLater(
        DatabaseHelper.instance.updateProperty({
          'id': propertyId,
          'name': 'عقار العلاقات',
          'owner_id': 999999,
        }),
        throwsArgumentError,
      );
    },
  );

  test(
    'default lease template embeds the settings logo and fits one page',
    () async {
      final logoFile = File(
        '${Directory.systemTemp.path}/aqari-test-logo-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await logoFile.writeAsBytes(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      try {
        final pdf = await LeaseContractPdf.build(
          companyInfo: {
            'name_ar': 'مؤسسة النقيب التجارية',
            'name_en': 'AL-NAQIB TRADING EST.',
            'activity_name_ar': 'للمقاولات ومواد البناء',
            'activity_name_en': 'Contracting & Building Materials',
            'commercial_register': '4601000613',
            'address_ar': 'شارع عمرو بن العاص - صنعاء',
            'telephone': '0777420665',
            'logo_path': logoFile.path,
            'terms_conditions': LeaseContractTerms.defaultText,
          },
          contract: {
            'id': 7,
            'start_date': '2026-09-09',
            'end_date': '2026-12-12',
            'rent_amount': 3222.0,
            'payment_method': 'شهري',
            'purpose': 'سكني',
            'electricity_reading': '12345',
          },
          owner: {
            'name': 'عبدالله محمد أحمد النقيب',
            'identity_number': '1029836135',
            'identity_issue_date': '1998/01/17',
            'identity_source': 'البيت',
          },
          tenant: {
            'name': 'مستأجر تجريبي',
            'identity_number': '1234567890',
            'mobile': '777000000',
            'nationality_name': 'يمني',
            'profession': 'موظف',
          },
          property: {
            'name': 'عقار الاختبار',
            'address': 'شارع عكرمة بن أبي جهل',
          },
          unit: {'unit_number': '1'},
          unitTypeName: 'غرفة',
        );
        final source = latin1.decode(pdf);
        expect(source, contains('AqariPDFArabic'));
        expect(RegExp(r'/Subtype\s*/Image').hasMatch(source), isTrue);
        expect(RegExp(r'/Type\s*/Page\b').allMatches(source).length, 1);
      } finally {
        if (await logoFile.exists()) await logoFile.delete();
      }
    },
  );

  test(
    'long lease terms add pages and keep signatures in the document flow',
    () async {
      final longTerms = List.generate(
        28,
        (index) =>
            'شرط ${index + 1}: يلتزم الطرفان بتنفيذ الالتزامات الواردة في هذا العقد '
            'بما يحفظ حقوق الطرفين ويضمن سلامة العقار وتسوية الالتزامات المالية '
            'وفق الأنظمة والتعليمات المعمول بها طوال مدة الإيجار.',
      ).join('\n');
      final pdf = await LeaseContractPdf.build(
        companyInfo: {'terms_conditions': longTerms},
        contract: {'rent_amount': 1200.0},
        owner: {'name': 'المؤجر'},
        tenant: {'name': 'المستأجر'},
        property: {'name': 'العقار'},
        unit: {'unit_number': '1'},
      );
      final source = latin1.decode(pdf);
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(source).length,
        greaterThan(1),
      );
    },
  );

  test(
    'posts leasing receipts and invoices atomically and rejects invalid duplicates',
    () async {
      final db = await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.updateCompanyInfo({
        'name_ar': 'منشأة اختبار الفاتورة',
        'tax_rate': 15.0,
      });
      final ownerId = await db.insert('owners', {'name': 'مالك الاختبار'});
      final propertyId = await db.insert('properties', {
        'name': 'عقار الاختبار',
        'owner_id': ownerId,
      });
      final unitId = await db.insert('units', {
        'property_id': propertyId,
        'unit_number': 'T-01',
        'default_rent': 100.0,
        'default_rent_period': 'monthly',
      });
      await DatabaseHelper.instance.insertTenantWithAccount({
        'name': 'مستأجر الاختبار',
        'mobile': '777000000',
      });
      final tenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر الاختبار'],
      )).single;
      final tenantId = tenant['id'] as int;

      final installments = List.generate(12, (index) {
        final due = DateTime(2026, 11 + index, 10);
        return {
          'amount': 100.0,
          'paid_amount': 0.0,
          'due_date': due.toIso8601String().substring(0, 10),
          'status': 'Unpaid',
        };
      });
      final contractId = await DatabaseHelper.instance
          .insertContractWithInstallments({
            'tenant_id': tenantId,
            'unit_id': unitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-10',
            'rent_amount': 1200.0,
            'payment_method': 'شهري',
            'status': 'Active',
          }, installments);
      expect(contractId, greaterThan(0));

      final storedContract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      expect(storedContract['rent_amount'], 1200.0);
      expect(storedContract['unit_rent_amount'], 100.0);
      expect(storedContract['unit_rent_period'], 'monthly');
      final partySnapshot = ContractPartySnapshot.decode(storedContract);
      expect(
        ContractPartySnapshot.section(partySnapshot, 'tenant')['name'],
        'مستأجر الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'owner')['name'],
        'مالك الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'property')['name'],
        'عقار الاختبار',
      );
      expect(
        ContractPartySnapshot.section(partySnapshot, 'unit')['unit_number'],
        'T-01',
      );

      final storedInstallments = await DatabaseHelper.instance
          .getInstallmentsForContract(contractId);
      final cashAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['1101'],
              )).single['id']
              as int;
      final cashGroupId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['11'],
              )).single['id']
              as int;
      final revenueRootId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4'],
              )).single['id']
              as int;
      final groupedPostingVouchersBefore = (await db.query('vouchers')).length;
      final groupedPostingEntriesBefore = (await db.query(
        'journal_entries',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: tenantId,
          amount: 10.0,
          voucherDate: '2026-11-10',
          cashAccountId: cashGroupId,
          installmentsToUpdate: [
            {
              'id': storedInstallments[2]['id'],
              'paid_amount': 10.0,
              'status': 'Partially Paid',
            },
          ],
        ),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-11-10',
            'amount': 10.0,
            'description': 'حساب نقدية تجميعي',
          },
          cashGroupId,
          (await db.query(
                'accounts',
                where: "account_type = 'Revenue' AND parent_id IS NOT NULL",
                limit: 1,
              )).single['id']
              as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTenantRefundVoucher(
          tenantId: tenantId,
          amount: 10.0,
          voucherDate: '2026-11-10',
          cashAccountId: cashGroupId,
          collectionAllocationId: -1,
          description: 'حساب نقدية تجميعي',
        ),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTaxInvoice(
          contractId: contractId,
          tenantId: tenantId,
          installmentId: storedInstallments[2]['id'] as int,
          invoiceDate: '2026-11-10',
          netAmount: 100.0,
          taxAmount: 15.0,
          revenueAccountId: revenueRootId,
          taxAccountId:
              (await db.query(
                    'accounts',
                    where: 'code = ?',
                    whereArgs: ['2103'],
                  )).single['id']
                  as int,
        ),
        throwsArgumentError,
      );
      expect((await db.query('vouchers')).length, groupedPostingVouchersBefore);
      expect(
        (await db.query('journal_entries')).length,
        groupedPostingEntriesBefore,
      );
      final receiptId = await DatabaseHelper.instance
          .insertTenantReceiptVoucher(
            tenantId: tenantId,
            amount: 150.0,
            voucherDate: '2026-11-10',
            cashAccountId: cashAccountId,
            installmentsToUpdate: [
              {
                'id': storedInstallments[0]['id'],
                'paid_amount': 100.0,
                'status': 'Paid',
              },
              {
                'id': storedInstallments[1]['id'],
                'paid_amount': 50.0,
                'status': 'Partially Paid',
              },
            ],
          );
      expect(receiptId, greaterThan(0));
      final receiptHistory = await DatabaseHelper.instance.getVoucherHistory(
        voucherType: 'قبض مستأجر',
      );
      expect(receiptHistory.single['id'], receiptId);
      expect(receiptHistory.single['party_name'], 'مستأجر الاختبار');
      final receiptDetails = await DatabaseHelper.instance.getVoucherDetails(
        receiptId,
      );
      expect(receiptDetails, isNotNull);
      expect((receiptDetails!['journal_lines'] as List).length, 2);
      final paidInstallments = receiptDetails['installments'] as List;
      expect(paidInstallments.length, 2);
      expect(
        paidInstallments
            .map((row) => (row['allocated_amount'] as num).toDouble())
            .toList(),
        [100.0, 50.0],
      );

      final revenueAccount = (await db.query(
        'accounts',
        where: "account_type = 'Revenue' AND parent_id IS NOT NULL",
        limit: 1,
      )).single;
      final vouchersBeforeMismatch = (await db.query('vouchers')).length;
      final entriesBeforeMismatch = (await db.query('journal_entries')).length;
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'صرف عام',
            'voucher_date': '2026-11-10',
            'amount': 20.0,
            'description': 'سند بنوع مخالف',
          },
          cashAccountId,
          revenueAccount['id'] as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      expect((await db.query('vouchers')).length, vouchersBeforeMismatch);
      expect((await db.query('journal_entries')).length, entriesBeforeMismatch);

      final vouchersBeforeInvalidPeriod = (await db.query('vouchers')).length;
      final entriesBeforeInvalidPeriod = (await db.query(
        'journal_entries',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-11-10',
            'amount': 20.0,
            'description': 'فترة ناقصة',
            'period_from_date': '2026-11-01',
          },
          cashAccountId,
          revenueAccount['id'] as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-11-10',
            'amount': 20.0,
            'description': 'فترة معكوسة',
            'period_from_date': '2026-11-30',
            'period_to_date': '2026-11-01',
          },
          cashAccountId,
          revenueAccount['id'] as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      expect((await db.query('vouchers')).length, vouchersBeforeInvalidPeriod);
      expect(
        (await db.query('journal_entries')).length,
        entriesBeforeInvalidPeriod,
      );

      final generalVoucherId = await DatabaseHelper.instance
          .insertGeneralVoucher(
            {
              'voucher_type': 'قبض عام',
              'voucher_date': '2026-11-10',
              'amount': 20.0,
              'description': 'اختبار',
              'period_from_date': '2026-11-01',
              'period_to_date': '2026-11-30',
            },
            cashAccountId,
            revenueAccount['id'] as int,
            null,
            'قبض عام',
          );
      expect(generalVoucherId, greaterThan(0));
      final generalDetails = await DatabaseHelper.instance.getVoucherDetails(
        generalVoucherId,
      );
      expect(generalDetails, isNotNull);
      expect((generalDetails!['voucher'] as Map)['party_name'], 'اختبار');
      expect(
        (generalDetails['voucher'] as Map)['period_from_date'],
        '2026-11-01',
      );
      expect(
        (generalDetails['voucher'] as Map)['period_to_date'],
        '2026-11-30',
      );
      expect((generalDetails['journal_lines'] as List).length, 2);

      final refundSource = (await db.query(
        'collection_allocations',
        where: 'voucher_id = ?',
        whereArgs: [receiptId],
        orderBy: 'id',
        limit: 1,
      )).single;
      final refundSourceId = refundSource['id'] as int;
      final paymentId = await DatabaseHelper.instance.insertTenantRefundVoucher(
        tenantId: tenantId,
        amount: 25.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashAccountId,
        collectionAllocationId: refundSourceId,
        description: 'رد جزء من سند القبض الاختباري',
      );
      final paymentDetails = await DatabaseHelper.instance.getVoucherDetails(
        paymentId,
      );
      expect(paymentDetails, isNotNull);
      expect(
        (paymentDetails!['voucher'] as Map)['party_name'],
        'مستأجر الاختبار',
      );
      expect((paymentDetails['journal_lines'] as List).length, 2);
      final refundLinks = paymentDetails['refunds'] as List;
      expect(refundLinks, hasLength(1));
      expect(refundLinks.single['source_receipt_voucher_id'], receiptId);
      expect(refundLinks.single['allocated_amount'], 25.0);
      expect(refundLinks.single['rent_refund_amount'], 25.0);
      expect(refundLinks.single['tax_refund_amount'], 0.0);
      final refundPdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند رد مستأجر',
        voucherNo: paymentId,
        date: '2026-11-10',
        targetName: 'مستأجر الاختبار',
        amount: 25.0,
        accountName: 'الصندوق الرئيسي',
        description: 'رد مرتبط بالمصدر',
        refundAllocations: refundLinks
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList(),
      );
      expect(refundPdf, isNotEmpty);
      final remainingAfterPartialRefund = await DatabaseHelper.instance
          .getRefundableCollectionAllocations(tenantId);
      expect(
        remainingAfterPartialRefund.singleWhere(
          (row) => row['collection_allocation_id'] == refundSourceId,
        )['remaining_amount'],
        75.0,
      );
      final vouchersBeforeExcessRefund = (await db.query('vouchers')).length;
      final journalsBeforeExcessRefund = (await db.query(
        'journal_entries',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTenantRefundVoucher(
          tenantId: tenantId,
          amount: 75.01,
          voucherDate: '2026-11-10',
          cashAccountId: cashAccountId,
          collectionAllocationId: refundSourceId,
          description: 'اختبار تجاوز سقف الرد',
        ),
        throwsStateError,
      );
      expect((await db.query('vouchers')).length, vouchersBeforeExcessRefund);
      expect(
        (await db.query('journal_entries')).length,
        journalsBeforeExcessRefund,
      );
      await DatabaseHelper.instance.insertTenantRefundVoucher(
        tenantId: tenantId,
        amount: 75.0,
        voucherDate: '2026-11-10',
        cashAccountId: cashAccountId,
        collectionAllocationId: refundSourceId,
        description: 'إكمال رد مصدر القبض',
      );
      final fullyRefundedSource = (await db.query(
        'collection_allocation_balances',
        where: 'id = ?',
        whereArgs: [refundSourceId],
      )).single;
      expect(fullyRefundedSource['remaining_minor'], 0);
      final refundedInstallment = (await db.query(
        'contract_installments',
        where: 'id = ?',
        whereArgs: [storedInstallments[0]['id']],
      )).single;
      expect(refundedInstallment['paid_amount'], 0.0);
      expect(refundedInstallment['status'], 'Unpaid');

      final taxAccountId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['2103'],
              )).single['id']
              as int;
      final invoiceId = await DatabaseHelper.instance.insertTaxInvoice(
        contractId: contractId,
        tenantId: tenantId,
        installmentId: storedInstallments[2]['id'] as int,
        invoiceDate: '2026-11-10',
        netAmount: 100.0,
        taxAmount: 15.0,
        revenueAccountId: revenueAccount['id'] as int,
        taxAccountId: taxAccountId,
      );
      expect(invoiceId, greaterThan(0));
      final storedInvoice = (await db.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
      )).single;
      expect(storedInvoice['net_amount'], 100.0);
      expect(storedInvoice['tax_amount'], 15.0);
      expect(storedInvoice['total_amount'], 115.0);
      expect(storedInvoice['tax_rate'], 15.0);
      expect(storedInvoice['installment_id'], storedInstallments[2]['id']);
      final historicalInvoiceId = await DatabaseHelper.instance
          .insertTaxInvoice(
            contractId: contractId,
            tenantId: tenantId,
            installmentId: storedInstallments[1]['id'] as int,
            invoiceDate: '2026-11-10',
            netAmount: 100.0,
            taxAmount: 15.0,
            revenueAccountId: revenueAccount['id'] as int,
            taxAccountId: taxAccountId,
          );
      final priorReceiptDetails = await DatabaseHelper.instance
          .getVoucherDetails(receiptId);
      final priorReceiptInvoiceLinks =
          priorReceiptDetails!['invoices'] as List<Map<String, Object?>>;
      expect(priorReceiptInvoiceLinks, hasLength(1));
      expect(
        priorReceiptInvoiceLinks.single['invoice_id'],
        historicalInvoiceId,
      );
      expect(priorReceiptInvoiceLinks.single['allocated_amount'], 50.0);
      final unbilledForContract = await DatabaseHelper.instance
          .getUnbilledInstallmentsForContract(contractId);
      expect(
        unbilledForContract.any(
          (row) =>
              row['id'] == storedInstallments[1]['id'] ||
              row['id'] == storedInstallments[2]['id'],
        ),
        isFalse,
      );
      await db.update(
        'contract_installments',
        {'paid_amount': 25.0, 'status': 'Partially Paid'},
        where: 'id = ?',
        whereArgs: [storedInstallments[4]['id']],
      );
      final invoicesBeforeUnmatchedPayment = (await db.query(
        'tax_invoices',
      )).length;
      final journalsBeforeUnmatchedPayment = (await db.query(
        'journal_entries',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTaxInvoice(
          contractId: contractId,
          tenantId: tenantId,
          installmentId: storedInstallments[4]['id'] as int,
          invoiceDate: '2026-11-10',
          netAmount: 100.0,
          taxAmount: 15.0,
          revenueAccountId: revenueAccount['id'] as int,
          taxAccountId: taxAccountId,
        ),
        throwsStateError,
      );
      expect(
        (await db.query('tax_invoices')).length,
        invoicesBeforeUnmatchedPayment,
      );
      expect(
        (await db.query('journal_entries')).length,
        journalsBeforeUnmatchedPayment,
      );
      await db.update(
        'contract_installments',
        {'paid_amount': 0.0, 'status': 'Unpaid'},
        where: 'id = ?',
        whereArgs: [storedInstallments[4]['id']],
      );
      final taxJournalEntry = (await db.query(
        'journal_entries',
        where: 'id = ?',
        whereArgs: [storedInvoice['journal_entry_id']],
      )).single;
      final taxJournalLines = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [taxJournalEntry['id']],
      );
      expect(taxJournalLines, hasLength(3));
      expect(
        taxJournalLines.fold<double>(
          0,
          (sum, line) => sum + (line['debit'] as num).toDouble(),
        ),
        115.0,
      );
      expect(
        taxJournalLines.fold<double>(
          0,
          (sum, line) => sum + (line['credit'] as num).toDouble(),
        ),
        115.0,
      );
      expect(storedInvoice['journal_entry_id'], taxJournalEntry['id']);

      await expectLater(
        DatabaseHelper.instance.insertTaxInvoice(
          contractId: contractId,
          tenantId: tenantId,
          installmentId: storedInstallments[2]['id'] as int,
          invoiceDate: '2026-11-10',
          netAmount: 100.0,
          taxAmount: 15.0,
          revenueAccountId: revenueAccount['id'] as int,
          taxAccountId: taxAccountId,
        ),
        throwsStateError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTaxInvoice(
          contractId: contractId,
          tenantId: tenantId,
          installmentId: storedInstallments[2]['id'] as int,
          invoiceDate: '2026-11-11',
          netAmount: 100.0,
          taxAmount: 14.99,
          revenueAccountId: revenueAccount['id'] as int,
          taxAccountId: taxAccountId,
        ),
        throwsArgumentError,
      );
      await expectLater(
        DatabaseHelper.instance.updateCompanyInfo({'tax_rate': 100.01}),
        throwsArgumentError,
      );
      await DatabaseHelper.instance.updateCompanyInfo({'tax_rate': 0.0});
      final zeroRateInvoiceId = await DatabaseHelper.instance.insertTaxInvoice(
        contractId: contractId,
        tenantId: tenantId,
        installmentId: storedInstallments[3]['id'] as int,
        invoiceDate: '2026-11-12',
        netAmount: 100.0,
        taxAmount: 0.0,
        revenueAccountId: revenueAccount['id'] as int,
        taxAccountId: null,
      );
      final zeroRateInvoice = (await db.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [zeroRateInvoiceId],
      )).single;
      expect(zeroRateInvoice['tax_rate'], 0.0);
      expect(zeroRateInvoice['tax_amount'], 0.0);
      expect(zeroRateInvoice['total_amount'], 100.0);
      final zeroTaxJournalEntry = (await db.query(
        'journal_entries',
        where: 'entry_date = ? AND description = ?',
        whereArgs: ['2026-11-12', 'إثبات فاتورة ضريبية إيجار'],
        orderBy: 'id DESC',
        limit: 1,
      )).single;
      final zeroTaxJournalLines = await db.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [zeroTaxJournalEntry['id']],
      );
      expect(zeroTaxJournalLines, hasLength(2));
      expect(
        zeroTaxJournalLines.any((line) => line['account_id'] == taxAccountId),
        isFalse,
      );
      await DatabaseHelper.instance.updateCompanyInfo({'tax_rate': 15.0});

      final openInvoicesBeforePayment = await DatabaseHelper.instance
          .getOpenTaxInvoicesForTenant(tenantId);
      final historicOpenInvoice = openInvoicesBeforePayment.singleWhere(
        (invoice) => invoice['id'] == historicalInvoiceId,
      );
      expect(historicOpenInvoice['paid_amount'], 50.0);
      expect(historicOpenInvoice['remaining_amount'], 65.0);
      final partialInvoiceReceiptId = await DatabaseHelper.instance
          .insertTenantReceiptVoucher(
            tenantId: tenantId,
            amount: 50.0,
            voucherDate: '2026-11-13',
            cashAccountId: cashAccountId,
            installmentsToUpdate: const [],
            invoiceId: invoiceId,
          );
      final partialInvoiceReceiptDetails = await DatabaseHelper.instance
          .getVoucherDetails(partialInvoiceReceiptId);
      final partialInvoiceLinks =
          partialInvoiceReceiptDetails!['invoices']
              as List<Map<String, Object?>>;
      expect(partialInvoiceLinks.single['invoice_id'], invoiceId);
      expect(partialInvoiceLinks.single['allocated_amount'], 50.0);
      expect(
        (partialInvoiceReceiptDetails['installments'] as List)
            .single['allocated_amount'],
        50.0,
      );
      final receiptInstallments =
          (partialInvoiceReceiptDetails['installments'] as List)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
      final receiptInvoices = partialInvoiceLinks
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final invoiceReceiptPdf = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند قبض مستأجر',
        voucherNo: partialInvoiceReceiptId,
        date: '2026-11-13',
        targetName: 'مستأجر الاختبار',
        amount: 50.0,
        accountName: 'الصندوق',
        description: 'سداد فاتورة داخلية رقم $invoiceId',
        installmentAllocations: receiptInstallments,
        invoiceAllocations: receiptInvoices,
      );
      expect(invoiceReceiptPdf.length, greaterThan(1000));

      final vouchersBeforeRejectedPayments = (await db.query(
        'vouchers',
      )).length;
      final journalsBeforeRejectedPayments = (await db.query(
        'journal_entries',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: tenantId,
          amount: 66.0,
          voucherDate: '2026-11-13',
          cashAccountId: cashAccountId,
          installmentsToUpdate: const [],
          invoiceId: invoiceId,
        ),
        throwsStateError,
      );
      await expectLater(
        DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: tenantId,
          amount: 50.0,
          voucherDate: '2026-11-13',
          cashAccountId: cashAccountId,
          installmentsToUpdate: [
            {
              'id': storedInstallments[2]['id'],
              'paid_amount': 100.0,
              'status': 'Paid',
            },
          ],
        ),
        throwsStateError,
      );
      expect(
        (await db.query('vouchers')).length,
        vouchersBeforeRejectedPayments,
      );
      expect(
        (await db.query('journal_entries')).length,
        journalsBeforeRejectedPayments,
      );

      final finalInvoiceReceiptId = await DatabaseHelper.instance
          .insertTenantReceiptVoucher(
            tenantId: tenantId,
            amount: 65.0,
            voucherDate: '2026-11-14',
            cashAccountId: cashAccountId,
            installmentsToUpdate: const [],
            invoiceId: invoiceId,
          );
      expect(finalInvoiceReceiptId, greaterThan(partialInvoiceReceiptId));
      final paidInstallment = (await db.query(
        'contract_installments',
        where: 'id = ?',
        whereArgs: [storedInstallments[2]['id']],
      )).single;
      expect(paidInstallment['amount'], 100.0);
      expect(paidInstallment['paid_amount'], 100.0);
      expect(paidInstallment['status'], 'Paid');
      final invoiceAllocations = await db.query(
        'voucher_invoice_allocations',
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      );
      expect(
        invoiceAllocations.fold<double>(
          0,
          (sum, row) => sum + (row['amount'] as num).toDouble(),
        ),
        115.0,
      );
      final openInvoicesAfterPayment = await DatabaseHelper.instance
          .getOpenTaxInvoicesForTenant(tenantId);
      expect(
        openInvoicesAfterPayment.any((row) => row['id'] == invoiceId),
        isFalse,
      );
      expect(
        openInvoicesAfterPayment.singleWhere(
          (row) => row['id'] == historicalInvoiceId,
        )['remaining_amount'],
        65.0,
      );

      await expectLater(
        DatabaseHelper.instance.cancelContract(
          contractId,
          reason: 'محاولة إلغاء بعد التحصيل',
        ),
        throwsStateError,
      );
      final protectedContract = (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single;
      final protectedInstallments = await db.query(
        'contract_installments',
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );
      expect(protectedContract['status'], 'Active');
      expect(protectedInstallments, hasLength(12));

      final summary = await DatabaseHelper.instance.getDashboardSummary();
      expect((summary['outstanding_amount'] as num).toDouble(), 1065.0);
      final tenantFinancialSearch = await DatabaseHelper.instance
          .searchTenantsAndContracts('مستأجر الاختبار');
      final searchedContract = tenantFinancialSearch.singleWhere(
        (row) => row['contract_id'] == contractId,
      );
      expect(searchedContract['total_amount'], 1230.0);
      expect(searchedContract['paid_amount'], 165.0);
      final dueInstallments = await DatabaseHelper.instance.getDueInstallments(
        500,
      );
      final historicInvoiceDue = dueInstallments.singleWhere(
        (row) => row['installment_id'] == storedInstallments[1]['id'],
      );
      expect(historicInvoiceDue['installment_amount'], 100.0);
      expect(historicInvoiceDue['amount'], 115.0);
      expect(historicInvoiceDue['paid_amount'], 50.0);
      expect(historicInvoiceDue['remaining_amount'], 65.0);
      final before =
          (await db.rawQuery(
                'SELECT COUNT(*) AS count FROM journal_entries',
              )).single['count']
              as int;
      await expectLater(
        DatabaseHelper.instance.insertGeneralVoucher(
          {
            'voucher_type': 'قبض عام',
            'voucher_date': '2026-11-10',
            'amount': 10.0,
          },
          cashAccountId,
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4'],
              )).single['id']
              as int,
          null,
          'قبض عام',
        ),
        throwsArgumentError,
      );
      final after =
          (await db.rawQuery(
                'SELECT COUNT(*) AS count FROM journal_entries',
              )).single['count']
              as int;
      expect(after, before);
      final groupRevenueId =
          (await db.query(
                'accounts',
                where: 'code = ?',
                whereArgs: ['4'],
              )).single['id']
              as int;
      await expectLater(
        DatabaseHelper.instance.insertJournalEntryWithLines(
          {
            'entry_date': '2026-11-10',
            'description': 'قيد بحساب تجميعي',
            'is_posted': 1,
          },
          [
            {'account_id': cashAccountId, 'debit': 1.0, 'credit': 0.0},
            {'account_id': groupRevenueId, 'debit': 0.0, 'credit': 1.0},
          ],
        ),
        throwsArgumentError,
      );
      expect(
        (await db.rawQuery(
          'SELECT COUNT(*) AS count FROM journal_entries',
        )).single['count'],
        before,
      );
      await expectLater(
        DatabaseHelper.instance.insertContractWithInstallments({
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': '2026-11-10',
          'end_date': '2027-11-10',
          'rent_amount': 1200.0,
          'payment_method': 'شهري',
          'status': 'Active',
        }, installments),
        throwsStateError,
      );
    },
  );

  test('cancelling a contract preserves its installment history', () async {
    final db = await DatabaseHelper.instance.database;
    final tenant = (await db.query(
      'tenants',
      where: 'name = ?',
      whereArgs: ['مستأجر الاختبار'],
    )).single;
    final ownerId = await db.insert('owners', {'name': 'مالك عقد الإلغاء'});
    final propertyId = await db.insert('properties', {
      'name': 'عقار عقد الإلغاء',
      'owner_id': ownerId,
    });
    await DatabaseHelper.instance.updateProperty({
      'id': propertyId,
      'name': 'عقار عقد الإلغاء المعدل',
      'owner_id': ownerId,
      'city_id': null,
      'property_type_id': null,
      'cost_center_id': null,
      'address': 'عنوان اختباري',
      'deed_number': 'D-01',
    });
    final unitId = await db.insert('units', {
      'property_id': propertyId,
      'unit_number': 'CANCEL-01',
    });
    await DatabaseHelper.instance.updateUnit({
      'id': unitId,
      'unit_number': 'CANCEL-EDITED',
      'unit_type_id': null,
      'floor': 'الأول',
      'elec_meter': 'E-01',
      'water_meter': 'W-01',
      'default_rent': 100.0,
      'default_rent_period': 'monthly',
    });
    final editedUnit = (await db.query(
      'units',
      where: 'id = ?',
      whereArgs: [unitId],
    )).single;
    expect(editedUnit['unit_number'], 'CANCEL-EDITED');
    expect(editedUnit['status'], 'شاغرة');
    final contractId = await DatabaseHelper.instance
        .insertContractWithInstallments(
          {
            'tenant_id': tenant['id'],
            'unit_id': unitId,
            'start_date': '2026-11-10',
            'end_date': '2027-11-09',
            'rent_amount': 100,
            'payment_method': 'شهري',
            'status': 'Active',
          },
          [
            {
              'amount': 100,
              'paid_amount': 0,
              'due_date': '2026-12-10',
              'status': 'Unpaid',
            },
          ],
        );
    final contractBeforeMasterEdits = (await db.query(
      'contracts',
      where: 'id = ?',
      whereArgs: [contractId],
    )).single;
    final originalSnapshot = ContractPartySnapshot.decode(
      contractBeforeMasterEdits,
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'owner')['name'],
      'مالك عقد الإلغاء',
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'property')['name'],
      'عقار عقد الإلغاء المعدل',
    );
    expect(
      ContractPartySnapshot.section(originalSnapshot, 'unit')['unit_number'],
      'CANCEL-EDITED',
    );
    await DatabaseHelper.instance.updateProperty({
      ...((await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [propertyId],
      )).single),
      'name': 'عقار بعد العقد',
      'address': 'عنوان جديد',
    });
    await DatabaseHelper.instance.updateUnit({
      'id': unitId,
      'unit_number': 'CANCEL-RENAMED',
      'unit_type_id': null,
      'floor': 'الأول',
      'elec_meter': 'E-01',
      'water_meter': 'W-01',
      'default_rent': 100.0,
      'default_rent_period': 'monthly',
    });
    await DatabaseHelper.instance.updateOwner({
      'id': ownerId,
      'name': 'مالك بعد العقد',
      'commission_rate': 0.0,
    });
    final persistedSnapshot = ContractPartySnapshot.decode(
      (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single,
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'owner')['name'],
      'مالك عقد الإلغاء',
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'property')['name'],
      'عقار عقد الإلغاء المعدل',
    );
    expect(
      ContractPartySnapshot.section(persistedSnapshot, 'unit')['unit_number'],
      'CANCEL-EDITED',
    );
    final secondOwnerId = await db.insert('owners', {
      'name': 'مالك ثان للاختبار',
    });
    final savedProperty = (await db.query(
      'properties',
      where: 'id = ?',
      whereArgs: [propertyId],
    )).single;
    await expectLater(
      DatabaseHelper.instance.updateProperty({
        ...savedProperty,
        'owner_id': secondOwnerId,
      }),
      throwsStateError,
    );
    final installment = (await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    )).single;

    await expectLater(
      DatabaseHelper.instance.deleteUnit(unitId),
      throwsStateError,
    );

    await expectLater(
      DatabaseHelper.instance.cancelContract(contractId, reason: '  '),
      throwsArgumentError,
    );
    expect(
      (await db.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
      )).single['status'],
      'Active',
    );

    const cancellationReason = 'إنهاء العقد باتفاق الطرفين';
    await DatabaseHelper.instance.cancelContract(
      contractId,
      reason: cancellationReason,
    );

    final retainedInstallments = await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    );
    final cancelledContract = (await db.query(
      'contracts',
      where: 'id = ?',
      whereArgs: [contractId],
    )).single;
    final releasedUnit = (await db.query(
      'units',
      where: 'id = ?',
      whereArgs: [unitId],
    )).single;
    final dueInstallments = await DatabaseHelper.instance.getDueInstallments(
      3650,
    );
    expect(retainedInstallments, hasLength(1));
    expect(retainedInstallments.single['id'], installment['id']);
    expect(retainedInstallments.single['status'], 'Cancelled');
    expect(cancelledContract['status'], 'Cancelled');
    expect(cancelledContract['cancellation_reason'], cancellationReason);
    expect(cancelledContract['cancelled_at'], isNotEmpty);
    expect(releasedUnit['status'], 'شاغرة');
    final cancellationAudits = await db.query(
      'audit_logs',
      where: 'action = ?',
      whereArgs: ['contract_cancelled'],
    );
    final cancellationAudit = cancellationAudits.singleWhere((row) {
      final details = jsonDecode(row['details'] as String);
      return (details as Map<String, dynamic>)['contract_id'] == contractId;
    });
    final cancellationDetails =
        jsonDecode(cancellationAudit['details'] as String)
            as Map<String, dynamic>;
    expect(cancellationDetails['reason'], cancellationReason);
    expect(cancellationAudit['timestamp'], cancelledContract['cancelled_at']);
    await expectLater(
      DatabaseHelper.instance.deleteUnit(unitId),
      throwsStateError,
    );
    expect(
      dueInstallments.any((row) => row['installment_id'] == installment['id']),
      isFalse,
    );
  });

  testWidgets('tenant refund screen requires an original receipt source', (
    tester,
  ) async {
    final leasingProvider = _TestLeasingProvider();
    final accountingProvider = _TestAccountingProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LeasingProvider>.value(value: leasingProvider),
          ChangeNotifierProvider<AccountingProvider>.value(
            value: accountingProvider,
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: TenantPaymentScreen())),
      ),
    );
    await tester.pump();
    expect(find.text('استرداد مستأجر مرتبط بمصدر قبض'), findsOneWidget);
    expect(find.text('مصدر القبض الأصلي'), findsOneWidget);
    expect(find.text('يُصرف من حساب (الصندوق/البنك)'), findsOneWidget);
    expect(find.text('الحساب المقابل'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    leasingProvider.dispose();
    accountingProvider.dispose();
  });

  testWidgets('voucher history lists persisted tenant and general vouchers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VoucherHistoryScreen())),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump();
    expect(find.text('سجل السندات'), findsOneWidget);
    expect(find.textContaining('سند صرف مستأجر رقم'), findsWidgets);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.textContaining('سند قبض مستأجر رقم'), findsWidgets);
    expect(find.textContaining('سند قبض عام رقم'), findsOneWidget);
  });

  test(
    'updating a tenant keeps its account link and syncs account name',
    () async {
      final db = await DatabaseHelper.instance.database;
      final tenant = (await db.query(
        'tenants',
        where: 'name = ?',
        whereArgs: ['مستأجر الاختبار'],
      )).single;
      final tenantId = tenant['id'] as int;
      final accountId = tenant['account_id'] as int;
      final contract = (await db.query(
        'contracts',
        where: 'tenant_id = ?',
        whereArgs: [tenantId],
        limit: 1,
      )).single;
      expect(ContractPartySnapshot.tenantName(contract), 'مستأجر الاختبار');

      await DatabaseHelper.instance.updateTenant({
        'id': tenantId,
        'name': 'مستأجر معدل',
        'mobile': tenant['mobile'],
        'identity_number': tenant['identity_number'],
        'identity_issue_date': tenant['identity_issue_date'],
        'identity_source': tenant['identity_source'],
        'profession': tenant['profession'],
        'nationality_id': tenant['nationality_id'],
      });
      final updated = (await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      )).single;
      final account = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [accountId],
      )).single;
      expect(updated['name'], 'مستأجر معدل');
      expect(updated['account_id'], accountId);
      expect(account['name'], 'مستأجر معدل');
      expect(ContractPartySnapshot.tenantName(contract), 'مستأجر الاختبار');
    },
  );

  test(
    'updating an owner keeps its account link and syncs account name',
    () async {
      final db = await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.insertOwnerWithAccount({
        'name': 'مالك تعديل الاختبار',
        'mobile': '777111222',
        'commission_rate': 5.0,
      });
      final owner = (await db.query(
        'owners',
        where: 'name = ?',
        whereArgs: ['مالك تعديل الاختبار'],
      )).single;
      final ownerId = owner['id'] as int;
      final accountId = owner['account_id'] as int;

      await DatabaseHelper.instance.updateOwner({
        'id': ownerId,
        'name': 'مالك محدث للاختبار',
        'mobile': owner['mobile'],
        'identity_number': owner['identity_number'],
        'identity_issue_date': owner['identity_issue_date'],
        'identity_source': owner['identity_source'],
        'profession': owner['profession'],
        'iban': owner['iban'],
        'commission_rate': 7.5,
      });
      final updated = (await db.query(
        'owners',
        where: 'id = ?',
        whereArgs: [ownerId],
      )).single;
      final account = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [accountId],
      )).single;
      expect(updated['name'], 'مالك محدث للاختبار');
      expect(updated['account_id'], accountId);
      expect(updated['commission_rate'], 7.5);
      expect(account['name'], 'مالك محدث للاختبار');
    },
  );

  testWidgets('tenant row opens an edit form and updates displayed data', (
    tester,
  ) async {
    final provider = _TestLeasingProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<LeasingProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: TenantsScreen())),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('مستأجر الاختبار').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('تعديل بيانات المستأجر'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'مستأجر معدل');
    await tester.tap(find.text('حفظ التعديلات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('مستأجر معدل'), findsOneWidget);
    expect(provider.tenants.single['account_id'], 81);

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  test(
    'factory reset creates a verified rollback copy before reseeding',
    () async {
      final rollbackPath = await DatabaseHelper.instance.factoryReset();
      final rollback = File(rollbackPath);
      expect(await rollback.exists(), isTrue);
      expect(await rollback.length(), greaterThan(100));

      final company = await DatabaseHelper.instance.getCompanyInfo();
      expect(company?['name_ar'], isNotEmpty);
      final db = await DatabaseHelper.instance.database;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single.values.single,
        20,
      );
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      await rollback.delete();
    },
  );

  test(
    'chart of accounts and manual posting preserve ledger integrity',
    () async {
      PermissionRuntime.activate(
        userId: 1,
        role: 'SuperAdmin',
        permissionRows: const [],
      );
      final helper = DatabaseHelper.instance;
      final db = await helper.database;
      final equityId = await helper.insertAccount({
        'name': 'حقوق ملكية اختبارية',
        'parent_id': null,
        'account_type': 'Equity',
        'code': 'IGNORED',
        'balance': 99999.0,
      });
      var equity = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [equityId],
      )).single;
      expect(equity['code'], '3');
      expect(equity['account_type'], 'Equity');
      expect(equity['balance'], 0.0);
      await expectLater(
        helper.insertAccount({
          'name': 'جذر حقوق ملكية مكرر',
          'parent_id': null,
          'account_type': 'Equity',
        }),
        throwsStateError,
      );

      final assetGroup = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['11'],
      )).single;
      final assetGroupId = assetGroup['id'] as int;
      await expectLater(
        helper.insertAccount({
          'name': 'حساب بنوع موروث خاطئ',
          'parent_id': assetGroupId,
          'account_type': 'Expense',
        }),
        throwsArgumentError,
      );

      final leafId = await helper.insertAccount({
        'name': 'حساب نقدية اختباري',
        'parent_id': assetGroupId,
        'account_type': 'Asset',
        'code': 'IGNORED-CHILD-CODE',
        'balance': 200.0,
      });
      var leaf = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [leafId],
      )).single;
      expect(leaf['code'], '1103');
      expect(leaf['balance'], 0.0);
      await helper.updateAccount(leafId, 'حساب نقدية محدث');
      leaf = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [leafId],
      )).single;
      expect(leaf['name'], 'حساب نقدية محدث');
      expect(leaf['code'], '1103');
      expect(leaf['account_type'], 'Asset');

      final assetRoot = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1'],
      )).single;
      final assetRootChildId = await helper.insertAccount({
        'name': 'حساب أصول مباشر لاختبار البادئة',
        'parent_id': assetRoot['id'],
        'account_type': 'Asset',
      });
      final assetRootChild = (await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [assetRootChildId],
      )).single;
      expect(assetRootChild['code'], '13');
      final revenue = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['4101'],
      )).single;
      final revenueRoot = (await db.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['4'],
      )).single;
      final accountProvider = AccountingProvider();
      await accountProvider.loadAccounts();
      final detailAccountIds = accountProvider.detailAccounts
          .map((account) => account['id'])
          .toSet();
      expect(detailAccountIds, contains(leafId));
      expect(detailAccountIds, contains(revenue['id']));
      expect(detailAccountIds, isNot(contains(assetGroup['id'])));
      accountProvider.dispose();
      final beforeEntries = (await db.query('journal_entries')).length;
      await expectLater(
        helper.insertJournalEntryWithLines(
          {'entry_date': '2026-11-15 نص زائد', 'description': 'تاريخ غير صالح'},
          [
            {'account_id': leafId, 'debit': 1.0, 'credit': 0.0},
            {'account_id': revenue['id'], 'debit': 0.0, 'credit': 1.0},
          ],
        ),
        throwsArgumentError,
      );
      final entryId = await helper.insertJournalEntryWithLines(
        {
          'id': 999999,
          'entry_date': '2026-11-15',
          'description': 'قيد اختباري متوازن',
          'is_posted': 0,
        },
        [
          {
            'journal_entry_id': 999999,
            'account_id': leafId,
            'debit': 12.34,
            'credit': 0.0,
            'description': 'مدين',
          },
          {
            'account_id': revenue['id'],
            'debit': 0.0,
            'credit': 12.34,
            'description': 'دائن',
          },
        ],
      );
      final journalHeader = (await db.query(
        'journal_entries',
        where: 'id = ?',
        whereArgs: [entryId],
      )).single;
      expect(journalHeader['is_posted'], 1);
      expect(journalHeader['id'], isNot(999999));
      final balances = <Map<String, dynamic>>[];
      for (final account in [
        leaf,
        assetGroup,
        assetRoot,
        revenue,
        revenueRoot,
      ]) {
        balances.add(
          (await db.query(
            'accounts',
            where: 'id = ?',
            whereArgs: [account['id']],
          )).single,
        );
      }
      expect(balances.map((row) => row['balance']), [
        12.34,
        12.34,
        12.34,
        12.34,
        12.34,
      ]);

      await expectLater(
        helper.insertAccount({
          'name': 'فرع لحساب ذي حركة',
          'parent_id': leafId,
        }),
        throwsStateError,
      );
      await expectLater(helper.deleteAccount(leafId), throwsStateError);

      final entriesBeforeInvalid = (await db.query('journal_entries')).length;
      await expectLater(
        helper.insertJournalEntryWithLines(
          {
            'entry_date': '2026-11-15',
            'description': 'ترحيل إلى حساب تجميعي',
            'is_posted': 1,
          },
          [
            {'account_id': assetGroupId, 'debit': 1.0, 'credit': 0.0},
            {'account_id': revenue['id'], 'debit': 0.0, 'credit': 1.0},
          ],
        ),
        throwsArgumentError,
      );
      await expectLater(
        helper.insertJournalEntryWithLines(
          {
            'entry_date': '2026-11-15',
            'description': 'مركز تكلفة غير موجود',
            'is_posted': 0,
          },
          [
            {
              'account_id': leafId,
              'debit': 1.0,
              'credit': 0.0,
              'cost_center_id': 999999,
            },
            {'account_id': revenue['id'], 'debit': 0.0, 'credit': 1.0},
          ],
        ),
        throwsArgumentError,
      );
      expect((await db.query('journal_entries')).length, entriesBeforeInvalid);
      await expectLater(helper.deleteAccount(1), throwsStateError);
      expect(await helper.deleteAccount(equityId), 1);
      expect(await helper.deleteAccount(assetRootChildId), 1);
      final deletedEquity = await db.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [equityId],
      );
      expect(deletedEquity, isEmpty);
      expect((await db.query('journal_entries')).length, beforeEntries + 1);
    },
  );

  test(
    'tenant and owner accounts share the safe account code allocator',
    () async {
      PermissionRuntime.activate(
        userId: 1,
        role: 'SuperAdmin',
        permissionRows: const [],
      );
      final helper = DatabaseHelper.instance;
      final db = await helper.database;

      Future<void> verifyAllocator({
        required String table,
        required String parentCode,
        required String accountType,
        required Future<void> Function(String name, int ordinal) createEntity,
      }) async {
        final parent = (await db.query(
          'accounts',
          where: 'code = ?',
          whereArgs: [parentCode],
          limit: 1,
        )).single;
        final parentId = parent['id'] as int;
        final allCodes = (await db.query(
          'accounts',
          columns: ['code'],
        )).map((row) => row['code'].toString()).toSet();
        var legacySequence = 9000;
        while (allCodes.contains('$parentCode$legacySequence') ||
            allCodes.contains('$parentCode${legacySequence + 1}')) {
          legacySequence += 2;
        }
        final legacyCodes = [
          '$parentCode$legacySequence',
          '$parentCode${legacySequence + 1}',
        ];
        final legacyAccountIds = <int>[];
        for (var index = 0; index < legacyCodes.length; index++) {
          legacyAccountIds.add(
            await db.insert('accounts', {
              'code': legacyCodes[index],
              'name': 'حساب قديم ${table}_$index',
              'parent_id': parentId,
              'account_type': accountType,
              'balance': 0.0,
            }),
          );
        }

        final firstName = '__phase5_${table}_1';
        final firstExpectedCode = await helper.generateAccountCode(parentId);
        await createEntity(firstName, 1);
        final entities = await db.query(
          table,
          columns: ['id', 'account_id'],
          where: 'name = ?',
          whereArgs: [firstName],
          limit: 1,
        );
        final firstAccountId = entities.single['account_id'] as int;
        expect(
          (await db.query(
            'accounts',
            columns: ['code'],
            where: 'id = ?',
            whereArgs: [firstAccountId],
          )).single['code'],
          firstExpectedCode,
        );
        await expectLater(
          helper.insertAccount({
            'name': 'حساب فرعي لحساب مرتبط',
            'parent_id': firstAccountId,
          }),
          throwsStateError,
        );

        final manualExpectedCode = await helper.generateAccountCode(parentId);
        final manualAccountId = await helper.insertAccount({
          'name': 'حساب يدوي بين سجلات $table',
          'parent_id': parentId,
          'account_type': accountType,
        });
        expect(
          (await db.query(
            'accounts',
            columns: ['code'],
            where: 'id = ?',
            whereArgs: [manualAccountId],
          )).single['code'],
          manualExpectedCode,
        );

        final secondName = '__phase5_${table}_2';
        final secondExpectedCode = await helper.generateAccountCode(parentId);
        await createEntity(secondName, 2);
        final secondEntity = (await db.query(
          table,
          columns: ['id', 'account_id'],
          where: 'name = ?',
          whereArgs: [secondName],
          limit: 1,
        )).single;
        final secondAccountId = secondEntity['account_id'] as int;
        expect(
          (await db.query(
            'accounts',
            columns: ['code'],
            where: 'id = ?',
            whereArgs: [secondAccountId],
          )).single['code'],
          secondExpectedCode,
        );
        expect(
          {firstExpectedCode, manualExpectedCode, secondExpectedCode}.length,
          3,
        );

        await db.delete(
          table,
          where: 'name IN (?, ?)',
          whereArgs: [firstName, secondName],
        );
        for (final accountId in {
          firstAccountId,
          secondAccountId,
          manualAccountId,
          ...legacyAccountIds,
        }) {
          await helper.deleteAccount(accountId);
        }
      }

      await verifyAllocator(
        table: 'tenants',
        parentCode: '1201',
        accountType: 'Asset',
        createEntity: (name, ordinal) => helper.insertTenantWithAccount({
          'name': name,
          'mobile': '77790000$ordinal',
        }),
      );
      await verifyAllocator(
        table: 'owners',
        parentCode: '2101',
        accountType: 'Liability',
        createEntity: (name, ordinal) => helper.insertOwnerWithAccount({
          'name': name,
          'commission_rate': ordinal.toDouble(),
        }),
      );
    },
  );

  testWidgets('chart account screen creates a root using its standard code', (
    tester,
  ) async {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
    final provider = _TestAccountingProvider();
    await provider.loadAccounts();
    await tester.pumpWidget(
      ChangeNotifierProvider<AccountingProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: ChartOfAccountsScreen())),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('دليل الحسابات'), findsOneWidget);
    await tester.tap(find.text('إضافة حساب رئيسي'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('طبيعة الحساب الرئيسي'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).last,
      'حقوق ملكية من الواجهة',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'إنشاء الحساب'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final saved = provider.accounts.singleWhere(
      (account) => account['name'] == 'حقوق ملكية من الواجهة',
    );
    expect(saved['code'], '3');
    expect(find.text('حقوق ملكية من الواجهة'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    provider.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'v13 migration preserves old invoice totals without inventing tax or installment links',
    () async {
      final helper = DatabaseHelper.instance;
      final db = await helper.database;
      final tenantAccountId =
          (await db.query(
                'accounts',
                where:
                    "account_type = 'Asset' AND code NOT LIKE '11%' AND parent_id IS NOT NULL",
                limit: 1,
              )).single['id']
              as int;
      final cashAccountId =
          (await db.query(
                'accounts',
                where:
                    "account_type = 'Asset' AND code LIKE '11%' AND parent_id IS NOT NULL",
                limit: 1,
              )).single['id']
              as int;
      final expenseAccountId =
          (await db.query(
                'accounts',
                where: "account_type = 'Expense' AND parent_id IS NOT NULL",
                limit: 1,
              )).single['id']
              as int;
      final legacyTenantId = await db.insert('tenants', {
        'name': 'مستأجر صرف قديم للمراجعة',
        'account_id': tenantAccountId,
      });
      final legacyOwnerId = await db.insert('owners', {
        'name': 'مالك ترحيل الاسترداد',
      });
      final legacyPropertyId = await db.insert('properties', {
        'name': 'عقار ترحيل الاسترداد',
        'owner_id': legacyOwnerId,
      });
      final legacyUnitId = await db.insert('units', {
        'property_id': legacyPropertyId,
        'unit_number': 'MIG-1',
      });
      final legacyContractId = await db.insert('contracts', {
        'tenant_id': legacyTenantId,
        'unit_id': legacyUnitId,
        'start_date': '2025-01-01',
        'end_date': '2025-12-31',
        'rent_amount': 10.0,
      });
      final historicalCancelledUnitId = await db.insert('units', {
        'property_id': legacyPropertyId,
        'unit_number': 'MIG-CANCELLED',
      });
      final historicalCancelledContractId = await db.insert('contracts', {
        'tenant_id': legacyTenantId,
        'unit_id': historicalCancelledUnitId,
        'start_date': '2024-01-01',
        'end_date': '2024-12-31',
        'rent_amount': 1.0,
        'status': 'Cancelled',
      });
      final legacyInstallmentId = await db.insert('contract_installments', {
        'contract_id': legacyContractId,
        'amount': 10.0,
        'paid_amount': 10.0,
        'due_date': '2025-01-01',
        'status': 'Paid',
      });
      final excessInstallmentId = await db.insert('contract_installments', {
        'contract_id': legacyContractId,
        'amount': 2.0,
        'paid_amount': 2.0,
        'due_date': '2025-02-01',
        'status': 'Paid',
      });
      final legacyReceiptJournalId = await db.insert('journal_entries', {
        'entry_date': '2025-05-10',
        'description': 'قيد قبض تاريخي للاختبار',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': legacyReceiptJournalId,
        'account_id': cashAccountId,
        'debit': 11.5,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': legacyReceiptJournalId,
        'account_id': tenantAccountId,
        'debit': 0.0,
        'credit': 11.5,
      });
      final legacyReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2025-05-10',
        'amount': 11.5,
        'tenant_id': legacyTenantId,
        'journal_entry_id': legacyReceiptJournalId,
        'description': 'قبض قديم للقسط',
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': legacyReceiptId,
        'installment_id': legacyInstallmentId,
        'amount': 10.0,
      });
      final unverifiedReceiptJournalId = await db.insert('journal_entries', {
        'entry_date': '2025-05-09',
        'description': 'قيد قبض غير مطابق للمبلغ لاختبار الترحيل',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': unverifiedReceiptJournalId,
        'account_id': cashAccountId,
        'debit': 1.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': unverifiedReceiptJournalId,
        'account_id': tenantAccountId,
        'debit': 0.0,
        'credit': 1.0,
      });
      final unverifiedReceiptId = await db.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': '2025-05-09',
        'amount': 3.0,
        'tenant_id': legacyTenantId,
        'journal_entry_id': unverifiedReceiptJournalId,
        'description': 'سند استلام أقدم من قيده المثبت',
      });
      await db.insert('voucher_installment_allocations', {
        'voucher_id': unverifiedReceiptId,
        'installment_id': excessInstallmentId,
        'amount': 3.0,
      });
      final legacyRefundJournalId = await db.insert('journal_entries', {
        'entry_date': '2025-05-11',
        'description': 'رد تاريخي مصروف على حساب مصروف',
        'is_posted': 1,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': legacyRefundJournalId,
        'account_id': expenseAccountId,
        'debit': 5.0,
        'credit': 0.0,
      });
      await db.insert('journal_lines', {
        'journal_entry_id': legacyRefundJournalId,
        'account_id': cashAccountId,
        'debit': 0.0,
        'credit': 5.0,
      });
      final legacyRefundVoucherId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2025-05-11',
        'amount': 5.0,
        'tenant_id': legacyTenantId,
        'journal_entry_id': legacyRefundJournalId,
        'description': 'رد قديم يحتاج إعادة تصنيف',
      });
      final legacyPaymentVoucherId = await db.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': '2025-05-12',
        'amount': 42.25,
        'tenant_id': legacyTenantId,
        'description': 'صرف قديم غير مربوط بالمصدر',
      });
      await db.execute('PRAGMA foreign_keys = OFF');
      await db.execute('DROP VIEW collection_allocation_balances');
      await db.execute('DROP TABLE refund_allocations');
      await db.execute('DROP TABLE collection_allocations');
      await db.execute('DROP TABLE legacy_tenant_payment_reviews');
      await db.execute('DROP TABLE voucher_invoice_allocations');
      await db.execute('DROP INDEX tax_invoices_installment_unique');
      await db.execute('DROP TABLE tax_invoices');
      await db.execute('''
        CREATE TABLE tax_invoices (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          contract_id INTEGER,
          invoice_date TEXT NOT NULL,
          total_amount REAL NOT NULL,
          tax_amount REAL NOT NULL,
          FOREIGN KEY (contract_id) REFERENCES contracts (id)
        )
      ''');
      await db.execute('PRAGMA foreign_keys = ON');
      await db.execute('ALTER TABLE company_info DROP COLUMN tax_rate');
      await db.execute('ALTER TABLE contracts DROP COLUMN cancelled_at');
      await db.execute('ALTER TABLE contracts DROP COLUMN cancellation_reason');
      final companyId = await db.insert('company_info', {
        'name_ar': 'منشأة قديمة بلا نسبة محفوظة',
      });
      final invoiceId = await db.insert('tax_invoices', {
        'contract_id': legacyContractId,
        'invoice_date': '2025-05-10',
        'total_amount': 11.5,
        'tax_amount': 1.5,
      });
      await db.execute('''
        CREATE TABLE voucher_invoice_allocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voucher_id INTEGER NOT NULL,
          invoice_id INTEGER NOT NULL,
          amount REAL NOT NULL CHECK (amount > 0),
          FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
          FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
        )
      ''');
      await db.insert('voucher_invoice_allocations', {
        'voucher_id': legacyReceiptId,
        'invoice_id': invoiceId,
        'amount': 11.5,
      });
      await db.execute('PRAGMA user_version = 13');
      await helper.close();

      final upgraded = await helper.database;
      expect(
        (await upgraded.rawQuery('PRAGMA user_version')).single.values.single,
        20,
      );
      final migratedHistoricalCancellation = (await upgraded.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [historicalCancelledContractId],
      )).single;
      expect(migratedHistoricalCancellation['status'], 'Cancelled');
      expect(migratedHistoricalCancellation['cancellation_reason'], isNull);
      expect(migratedHistoricalCancellation['cancelled_at'], isNull);
      final migratedVoucherColumns = (await upgraded.rawQuery(
        "PRAGMA table_info('vouchers')",
      )).map((row) => row['name']).toSet();
      expect(
        migratedVoucherColumns,
        containsAll(['period_from_date', 'period_to_date']),
      );
      final migratedLegacyVoucher = (await upgraded.query(
        'vouchers',
        where: 'id = ?',
        whereArgs: [legacyReceiptId],
      )).single;
      expect(migratedLegacyVoucher['period_from_date'], isNull);
      expect(migratedLegacyVoucher['period_to_date'], isNull);
      final company = (await upgraded.query(
        'company_info',
        where: 'id = ?',
        whereArgs: [companyId],
      )).single;
      expect(company['tax_rate'], 0.0);
      final invoice = (await upgraded.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
      )).single;
      expect(invoice['net_amount'], 10.0);
      expect(invoice['tax_amount'], 1.5);
      expect(invoice['total_amount'], 11.5);
      expect(invoice['tax_rate'], isNull);
      expect(invoice['installment_id'], isNull);
      expect(invoice['journal_entry_id'], isNull);
      final legacyInvoiceReview = (await upgraded.query(
        'legacy_invoice_reviews',
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      )).single;
      expect(legacyInvoiceReview['contract_id'], legacyContractId);
      expect(legacyInvoiceReview['status'], 'pending');
      final legacyReview = (await upgraded.query(
        'legacy_tenant_payment_reviews',
        where: 'voucher_id = ?',
        whereArgs: [legacyPaymentVoucherId],
      )).single;
      expect(legacyReview['tenant_id'], legacyTenantId);
      expect(legacyReview['amount_minor'], 4225);
      expect(legacyReview['status'], 'pending');
      final legacyRefundReview = (await upgraded.query(
        'legacy_tenant_payment_reviews',
        where: 'voucher_id = ?',
        whereArgs: [legacyRefundVoucherId],
      )).single;
      expect(legacyRefundReview['amount_minor'], 500);
      expect(legacyRefundReview['status'], 'pending');
      final vouchersBeforeLegacyGuard = (await upgraded.query(
        'vouchers',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: legacyTenantId,
          amount: 1.0,
          voucherDate: '2025-05-13',
          cashAccountId: cashAccountId,
          installmentsToUpdate: [
            {'id': legacyInstallmentId, 'paid_amount': 10.0, 'status': 'Paid'},
          ],
        ),
        throwsStateError,
      );
      expect(
        (await upgraded.query('vouchers')).length,
        vouchersBeforeLegacyGuard,
      );
      expect(await upgraded.query('collection_allocations'), isNotEmpty);
      expect(
        await upgraded.query(
          'collection_allocations',
          where: 'voucher_id = ?',
          whereArgs: [unverifiedReceiptId],
        ),
        isEmpty,
      );
      expect(
        (await upgraded.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'view' AND name = ?",
          ['collection_allocation_balances'],
        )),
        hasLength(1),
      );
      final migratedSource = (await upgraded.query(
        'collection_allocations',
        where: 'voucher_id = ?',
        whereArgs: [legacyReceiptId],
      )).single;
      await upgraded.insert('voucher_installment_allocations', {
        'voucher_id': legacyReceiptId,
        'installment_id': excessInstallmentId,
        'amount': 2.0,
      });
      await expectLater(
        upgraded.insert('collection_allocations', {
          'voucher_id': legacyReceiptId,
          'installment_id': excessInstallmentId,
          'amount_minor': 200,
          'rent_amount_minor': 200,
          'tax_amount_minor': 0,
        }),
        throwsA(isA<Exception>()),
      );
      final migratedSourceId = migratedSource['id'] as int;
      await DatabaseHelper.instance.resolveLegacyTenantPaymentAsRefund(
        voucherId: legacyRefundVoucherId,
        allocations: [
          {'collection_allocation_id': migratedSourceId, 'amount_minor': 500},
        ],
        reason: 'مراجعة المستند أثبتت أنه رد من سند القبض التاريخي',
      );
      final resolvedRefund = (await upgraded.query(
        'legacy_tenant_payment_reviews',
        where: 'voucher_id = ?',
        whereArgs: [legacyRefundVoucherId],
      )).single;
      expect(resolvedRefund['status'], 'refund');
      expect(resolvedRefund['reclassification_journal_entry_id'], isNotNull);
      final adjustedInstallment = (await upgraded.query(
        'contract_installments',
        where: 'id = ?',
        whereArgs: [legacyInstallmentId],
      )).single;
      expect(adjustedInstallment['paid_amount'], 5.0);
      expect(
        (await upgraded.query(
          'refund_allocations',
          where: 'refund_voucher_id = ?',
          whereArgs: [legacyRefundVoucherId],
        )),
        hasLength(1),
      );
      await DatabaseHelper.instance.resolveLegacyTenantPaymentAsUnrelated(
        voucherId: legacyPaymentVoucherId,
        reason: 'تمت مراجعة المستند وتبين أنه صرف غير مرتبط بتحصيل إيجار',
      );
      final resolvedReview = (await upgraded.query(
        'legacy_tenant_payment_reviews',
        where: 'voucher_id = ?',
        whereArgs: [legacyPaymentVoucherId],
      )).single;
      expect(resolvedReview['status'], 'unrelated');
      expect(resolvedReview['reviewed_at'], isNotNull);
      expect(
        await upgraded.query(
          'audit_logs',
          where: "action = 'LEGACY_TENANT_PAYMENT_MARKED_UNRELATED'",
        ),
        isNotEmpty,
      );
      final vouchersBeforePendingInvoiceGuard = (await upgraded.query(
        'vouchers',
      )).length;
      await expectLater(
        DatabaseHelper.instance.insertTenantReceiptVoucher(
          tenantId: legacyTenantId,
          amount: 1.0,
          voucherDate: '2025-05-14',
          cashAccountId: cashAccountId,
          installmentsToUpdate: [
            {
              'id': legacyInstallmentId,
              'paid_amount': 6.0,
              'status': 'Partially Paid',
            },
          ],
        ),
        throwsStateError,
      );
      expect(
        (await upgraded.query('vouchers')).length,
        vouchersBeforePendingInvoiceGuard,
      );
      final legacySourceBeforeGuard = (await upgraded.query(
        'collection_allocations',
        where: 'voucher_id = ?',
        whereArgs: [legacyReceiptId],
      )).single;
      await expectLater(
        upgraded.transaction((txn) async {
          await txn.update(
            'tax_invoices',
            {'installment_id': legacyInstallmentId},
            where: 'id = ?',
            whereArgs: [invoiceId],
          );
          await txn.update(
            'collection_allocations',
            {'invoice_id': invoiceId},
            where: 'id = ?',
            whereArgs: [legacySourceBeforeGuard['id']],
          );
        }),
        throwsException,
      );
      expect(
        (await upgraded.query(
          'tax_invoices',
          where: 'id = ?',
          whereArgs: [invoiceId],
        )).single['installment_id'],
        isNull,
      );
      expect(
        (await upgraded.query(
          'collection_allocations',
          where: 'id = ?',
          whereArgs: [legacySourceBeforeGuard['id']],
        )).single['invoice_id'],
        isNull,
      );
      await DatabaseHelper.instance.resolveLegacyInvoiceAsInstallment(
        invoiceId: invoiceId,
        installmentId: legacyInstallmentId,
        reason:
            'تمت مطابقة أصل الفاتورة مع القسط وإيصال القبض بعد مراجعة السندات',
      );
      final linkedLegacyInvoice = (await upgraded.query(
        'tax_invoices',
        where: 'id = ?',
        whereArgs: [invoiceId],
      )).single;
      expect(linkedLegacyInvoice['installment_id'], legacyInstallmentId);
      final resolvedInvoiceReview = (await upgraded.query(
        'legacy_invoice_reviews',
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      )).single;
      expect(resolvedInvoiceReview['status'], 'linked');
      final linkedLegacySource = (await upgraded.query(
        'collection_allocations',
        where: 'voucher_id = ? AND invoice_id = ?',
        whereArgs: [legacyReceiptId, invoiceId],
      )).single;
      expect(linkedLegacySource['amount_minor'], 1150);
      expect(linkedLegacySource['rent_amount_minor'], 1000);
      expect(linkedLegacySource['tax_amount_minor'], 150);
      final openLegacyInvoice =
          (await DatabaseHelper.instance.getOpenTaxInvoicesForTenant(
            legacyTenantId,
          )).singleWhere((row) => row['id'] == invoiceId);
      expect(openLegacyInvoice['paid_amount'], 6.5);
      expect(openLegacyInvoice['remaining_amount'], 5.0);

      expect(
        await upgraded.query(
          'audit_logs',
          where: "action = 'LEGACY_TENANT_PAYMENT_RECONCILED_AS_REFUND'",
        ),
        isNotEmpty,
      );
    },
  );
}

class _TestAccountingProvider extends AccountingProvider {
  final List<Map<String, dynamic>> _accounts = [
    {
      'id': 1,
      'code': '1',
      'name': 'الأصول',
      'parent_id': null,
      'account_type': 'Asset',
      'balance': 0.0,
    },
    {
      'id': 2,
      'code': '2',
      'name': 'الخصوم',
      'parent_id': null,
      'account_type': 'Liability',
      'balance': 0.0,
    },
    {
      'id': 3,
      'code': '4',
      'name': 'الإيرادات',
      'parent_id': null,
      'account_type': 'Revenue',
      'balance': 0.0,
    },
    {
      'id': 4,
      'code': '5',
      'name': 'المصروفات',
      'parent_id': null,
      'account_type': 'Expense',
      'balance': 0.0,
    },
  ];

  @override
  List<Map<String, dynamic>> get accounts => _accounts;

  @override
  bool get isLoading => false;

  @override
  String? get errorMessage => null;

  @override
  Future<void> loadAccounts() async {}

  @override
  Future<int> addAccount(Map<String, dynamic> account) async {
    final rootCodes = {
      'Asset': '1',
      'Liability': '2',
      'Equity': '3',
      'Revenue': '4',
      'Expense': '5',
    };
    const id = 5;
    _accounts.add({
      'id': id,
      'code': rootCodes[account['account_type']],
      'name': account['name'],
      'parent_id': null,
      'account_type': account['account_type'],
      'balance': 0.0,
    });
    notifyListeners();
    return id;
  }
}

class _TestLeasingProvider extends LeasingProvider {
  final List<Map<String, dynamic>> _testTenants = [
    {
      'id': 17,
      'name': 'مستأجر الاختبار',
      'mobile': '777000000',
      'identity_number': '12345',
      'identity_issue_date': '2026-01-01',
      'identity_source': 'صنعاء',
      'profession': 'موظف',
      'nationality_id': null,
      'account_id': 81,
    },
  ];

  @override
  List<Map<String, dynamic>> get tenants => _testTenants;

  @override
  List<Map<String, dynamic>> get nationalities => const [];

  @override
  bool get isLoading => false;

  @override
  Future<void> loadInitialData() async {}

  @override
  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    final index = _testTenants.indexWhere((item) => item['id'] == tenant['id']);
    _testTenants[index] = {..._testTenants[index], ...tenant};
    notifyListeners();
  }
}
