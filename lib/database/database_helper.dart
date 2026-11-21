import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

import '../core/contract_term.dart';
import '../core/crypto_utils.dart';
import '../core/internal_tax.dart';
import '../core/lease_contract_terms.dart';
import '../core/permission_policy.dart';
import '../core/rent_period.dart';
import '../core/sms_credential_store.dart';
import '../models/account_balance_reconciliation_report_model.dart';
import '../models/account_statement_report_model.dart';
import '../models/financial_close_readiness_report_model.dart';
import '../models/financial_position_report_model.dart';
import '../models/income_expense_report_model.dart';
import '../models/internal_subledger_reconciliation_report_model.dart';
import '../models/invoice_ledger_reconciliation_report_model.dart';
import '../models/property_statement_report_model.dart';
import '../models/tenant_collection_report_model.dart';
import '../models/tenant_aging_report_model.dart';
import '../models/trial_balance_report_model.dart';
import '../models/accounting_period_model.dart';
import 'database_integrity_migrations.dart';
import 'credit_note_schema.dart';
import 'accounting_period_schema.dart';
import 'internal_subledger_reconciliation_service.dart';
import 'owner_settlement_schema.dart';
import 'property_sale_schema.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static const int _schemaVersion = 33;
  static const int _maxFailedLoginAttempts = 5;
  static const Duration _loginLockoutDuration = Duration(minutes: 15);
  @visibleForTesting
  static Future<void> Function()? restorePostReplacementHookForTesting;

  /// Current schema version, exposed so tests and diagnostics assert against a
  /// single source of truth instead of hardcoding a number that drifts.
  static int get schemaVersion => _schemaVersion;
  static const Set<String> _lookupTables = {
    'cities',
    'nationalities',
    'banks',
    'property_types',
    'unit_types',
    'cost_centers',
  };
  static const Map<String, String> _accountTypeRootCodes = {
    'Asset': '1',
    'Liability': '2',
    'Equity': '3',
    'Revenue': '4',
    'Expense': '5',
  };
  static const Set<String> _protectedSystemAccountCodes = {
    '1',
    '11',
    '1101',
    '1102',
    '1201',
    '2',
    '2101',
    '2102',
    '2103',
    '4',
    '4101',
    '4102',
    '5',
    '5101',
    '5102',
    '5103',
  };

  DatabaseHelper._init();
  Future<void> _smsSettingsWriteQueue = Future<void>.value();

  bool _hasCentPrecision(num value) {
    final scaled = value.toDouble() * 100;
    return scaled.isFinite && (scaled - scaled.round()).abs() < 0.000001;
  }

  bool _isIsoCalendarDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parts = value.split('-').map(int.tryParse).toList();
    if (parts.any((part) => part == null)) return false;
    final year = parts[0]!;
    final month = parts[1]!;
    final day = parts[2]!;
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
      return false;
    }
    final parsed = DateTime.utc(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day;
  }

  void _requireAnyView(Iterable<String> modules) {
    if (!modules.any(
      (module) => PermissionRuntime.allows(module, AppPermissionAction.view),
    )) {
      throw StateError('لا تملك صلاحية عرض هذه البيانات');
    }
  }

  void _validateLookupTable(String tableName) {
    if (!_lookupTables.contains(tableName)) {
      throw ArgumentError.value(tableName, 'tableName', 'جدول مرجعي غير مسموح');
    }
  }

  void _requireLookupReadPermission(String tableName) {
    final modules = switch (tableName) {
      'cities' || 'property_types' || 'unit_types' => ['lookups', 'properties'],
      'nationalities' => ['lookups', 'leasing', 'properties'],
      'cost_centers' => ['lookups', 'properties', 'accounting'],
      'banks' => ['lookups', 'accounting', 'tenant_financial'],
      _ => ['lookups'],
    };
    _requireAnyView(modules);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('desktop_erp.db');
    return _database!;
  }

  Future<String> getDbPath() async {
    final dbPath = await getApplicationDocumentsDirectory();
    return join(dbPath.path, 'AbdullahAlNaqeebERP', 'desktop_erp.db');
  }

  Future<void> backupToFile(String targetPath) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    await _createDatabaseSnapshot(targetPath, clearSmsSecretReference: true);
  }

  /// Creates a local snapshot for the app-managed automatic backup service.
  /// User-initiated backups must use [backupToFile] to enforce permissions.
  Future<void> createAutomaticBackupSnapshot(String targetPath) async {
    await _createDatabaseSnapshot(targetPath, clearSmsSecretReference: true);
  }

  Future<Map<int, String>> _captureSmsCredentialReferences(Database db) async {
    final rows = await db.query(
      'sms_settings',
      columns: ['id', 'api_key_secret_id'],
      orderBy: 'id ASC',
    );
    return {
      for (final row in rows)
        if (row['id'] is num &&
            row['api_key_secret_id']?.toString().isNotEmpty == true)
          (row['id'] as num).toInt(): row['api_key_secret_id'].toString(),
    };
  }

  Future<void> _restoreSmsCredentialReferences(
    Database db,
    Map<int, String> references,
  ) async {
    await db.transaction((txn) async {
      await txn.update('sms_settings', {
        'api_key': null,
        'api_key_secret_id': null,
      });
      for (final entry in references.entries) {
        final updated = await txn.update(
          'sms_settings',
          {'api_key_secret_id': entry.value},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
        if (updated != 1) {
          throw StateError('تعذر استعادة ربط مفتاح الرسائل بالقاعدة السابقة');
        }
      }
    });
  }

  Future<void> _createDatabaseSnapshot(
    String targetPath, {
    required bool clearSmsSecretReference,
  }) async {
    final target = File(targetPath).absolute;
    final livePath = File(await getDbPath()).absolute.path;
    if (target.path == livePath) {
      throw ArgumentError('لا يمكن اختيار قاعدة التشغيل كوجهة للنسخ');
    }
    if (await target.exists()) {
      throw FileSystemException(
        'ملف النسخة موجود مسبقًا؛ لن يُستبدل',
        target.path,
      );
    }
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.partial-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      final db = await database;
      final escapedPath = temporary.path.replaceAll("'", "''");
      await db.execute("VACUUM INTO '$escapedPath'");
      final snapshot = await databaseFactory.openDatabase(
        temporary.path,
        options: OpenDatabaseOptions(readOnly: false),
      );
      try {
        await snapshot.execute('PRAGMA secure_delete = ON');
        await snapshot.update('sms_settings', {
          'api_key': null,
          if (clearSmsSecretReference) 'api_key_secret_id': null,
        });
        await snapshot.execute('VACUUM');
      } finally {
        await snapshot.close();
      }
      await _validateDatabaseFile(
        temporary.path,
        requireCurrentSchema: true,
        requireSmsSecretsRemoved: clearSmsSecretReference,
      );
      if (await target.exists()) {
        throw FileSystemException(
          'ملف النسخة ظهر أثناء العملية؛ لم يتم استبداله',
          target.path,
        );
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<String> restoreFromFile(String sourcePath) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    final source = File(sourcePath).absolute;
    final livePath = File(await getDbPath()).absolute;
    if (source.path == livePath.path) {
      throw ArgumentError('اختر ملف نسخة احتياطية، وليس قاعدة التشغيل');
    }
    await _rejectUncheckpointedWal(source.path);
    final sourceVersion = await _validateDatabaseFile(source.path);
    if (sourceVersion > _schemaVersion) {
      throw StateError(
        'إصدار النسخة ($sourceVersion) أحدث من إصدار هذا البرنامج ($_schemaVersion)',
      );
    }

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staged = File('${livePath.path}.restore-$stamp');
    final rollback = File(
      join(livePath.parent.path, 'aqari_pre_restore_$stamp.db'),
    );
    var liveReplacementStarted = false;
    final stagedCredentialIds = <String>{};
    final newlyCreatedStagedCredentialIds = <String>{};
    final previousCredentialIds = <String>{};
    final previousCredentialReferences = <int, String>{};
    await livePath.parent.create(recursive: true);
    try {
      final sourceStatBefore = await source.stat();
      await source.copy(staged.path);
      await _rejectUncheckpointedWal(source.path);
      final sourceStatAfter = await source.stat();
      if (sourceStatBefore.size != sourceStatAfter.size ||
          sourceStatBefore.modified != sourceStatAfter.modified) {
        throw StateError(
          'تغير ملف النسخة أثناء قراءته؛ أوقف أي برنامج يستخدمه ثم أعد المحاولة',
        );
      }
      final candidate = await databaseFactory.openDatabase(
        staged.path,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
            await db.execute('PRAGMA secure_delete = ON');
          },
          onUpgrade: _upgradeDB,
        ),
      );
      try {
        final restoredCredentials = await _resolveAllSmsCredentials(candidate);
        for (final credential in restoredCredentials) {
          if (credential.id != null) stagedCredentialIds.add(credential.id!);
          if (credential.created && credential.id != null) {
            newlyCreatedStagedCredentialIds.add(credential.id!);
          }
        }
        await _validateOpenDatabase(candidate, requireCurrentSchema: true);
      } finally {
        await candidate.close();
      }

      final current = await database;
      final currentCredentials = await _resolveAllSmsCredentials(current);
      previousCredentialIds.addAll(
        currentCredentials
            .map((credential) => credential.id)
            .whereType<String>(),
      );
      previousCredentialReferences.addAll(
        await _captureSmsCredentialReferences(current),
      );
      // Rollback snapshots never contain secret values or vault references.
      // Keep the verified references in memory and reattach only on rollback.
      await _createDatabaseSnapshot(
        rollback.path,
        clearSmsSecretReference: true,
      );
      await current.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await current.close();
      _database = null;
      liveReplacementStarted = true;
      await _deleteSqliteSidecars(livePath.path);
      await staged.rename(livePath.path);
      await restorePostReplacementHookForTesting?.call();
      _database = await _initDB('desktop_erp.db');
      await _validateOpenDatabase(_database!, requireCurrentSchema: true);
      for (final oldId in previousCredentialIds.difference(
        stagedCredentialIds,
      )) {
        await _deleteSmsCredentialIgnoringFailure(oldId);
      }
      return rollback.path;
    } catch (error) {
      if (liveReplacementStarted) {
        Object? rollbackError;
        try {
          if (_database != null) await _database!.close();
          _database = null;
          if (await livePath.exists()) await livePath.delete();
          await _deleteSqliteSidecars(livePath.path);
          if (!await rollback.exists()) {
            throw StateError('ملف نسخة الرجوع غير موجود');
          }
          await rollback.copy(livePath.path);
          _database = await _initDB('desktop_erp.db');
          await _validateOpenDatabase(_database!, requireCurrentSchema: true);
          await _restoreSmsCredentialReferences(
            _database!,
            previousCredentialReferences,
          );
        } catch (failure) {
          rollbackError = failure;
        }
        if (rollbackError != null) {
          for (final stagedId in newlyCreatedStagedCredentialIds.difference(
            previousCredentialIds,
          )) {
            await _deleteSmsCredentialIgnoringFailure(stagedId);
          }
          throw StateError(
            'فشلت الاستعادة ($error)، وتعذرت الاستعادة التلقائية ($rollbackError). احتفظ بنسخة الرجوع إن وُجدت: ${rollback.path}',
          );
        }
        for (final stagedId in newlyCreatedStagedCredentialIds.difference(
          previousCredentialIds,
        )) {
          await _deleteSmsCredentialIgnoringFailure(stagedId);
        }
        throw StateError(
          'فشلت الاستعادة، لكن أُعيدت قاعدة التشغيل من نسخة الرجوع المحفوظة في ${rollback.path}. السبب: $error',
        );
      }
      for (final stagedId in newlyCreatedStagedCredentialIds.difference(
        previousCredentialIds,
      )) {
        await _deleteSmsCredentialIgnoringFailure(stagedId);
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<int> _validateDatabaseFile(
    String path, {
    bool requireCurrentSchema = false,
    bool requireSmsSecretsRemoved = false,
  }) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < 100) {
      throw StateError('ملف النسخة غير موجود أو غير مكتمل');
    }
    await _rejectUncheckpointedWal(file.absolute.path);
    Database? candidate;
    try {
      candidate = await databaseFactory.openDatabase(
        file.absolute.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      final version = (versionRows.first.values.first as num).toInt();
      if (version < 1 || version > _schemaVersion) {
        throw StateError('إصدار قاعدة البيانات غير مدعوم: $version');
      }
      final integrity = await candidate.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty ||
          integrity.any((row) => row.values.first != 'ok')) {
        throw StateError('فشل فحص سلامة ملف قاعدة البيانات');
      }
      final violations = await candidate.rawQuery('PRAGMA foreign_key_check');
      if (violations.isNotEmpty) {
        throw StateError('تحتوي النسخة على علاقات مرجعية غير سليمة');
      }
      if (requireCurrentSchema) {
        await _validateOpenDatabase(candidate, requireCurrentSchema: true);
      }
      if (requireSmsSecretsRemoved) {
        final smsRows = await candidate.query(
          'sms_settings',
          columns: ['api_key', 'api_key_secret_id'],
        );
        if (smsRows.any(
          (row) =>
              (row['api_key']?.toString().isNotEmpty ?? false) ||
              (row['api_key_secret_id']?.toString().isNotEmpty ?? false),
        )) {
          throw StateError('تحتوي النسخة الاحتياطية على بيانات اعتماد SMS');
        }
      }
      await _rejectUncheckpointedWal(file.absolute.path);
      return version;
    } on StateError {
      rethrow;
    } catch (error) {
      throw StateError('تعذر فتح/فحص ملف قاعدة البيانات: $error');
    } finally {
      await candidate?.close();
    }
  }

  Future<void> _validateOpenDatabase(
    DatabaseExecutor db, {
    required bool requireCurrentSchema,
  }) async {
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    if (integrity.isEmpty || integrity.any((row) => row.values.first != 'ok')) {
      throw StateError('فشل فحص سلامة قاعدة البيانات');
    }
    final violations = await db.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw StateError('تحتوي قاعدة البيانات على علاقات مرجعية غير سليمة');
    }
    if (!requireCurrentSchema) return;
    final versionRows = await db.rawQuery('PRAGMA user_version');
    final version = (versionRows.first.values.first as num).toInt();
    if (version != _schemaVersion) {
      throw StateError('إصدار مخطط قاعدة البيانات غير متوقع: $version');
    }
    const requiredColumns = <String, List<String>>{
      'company_info': [
        'id',
        'name_ar',
        'name_en',
        'activity',
        'address',
        'default_currency',
        'tax_number',
        'tax_rate',
        'commercial_register',
        'logo_path',
        'terms_conditions',
        'activity_name_ar',
        'activity_name_en',
        'address_ar',
        'address_en',
        'po_box',
        'telephone',
        'fax',
        'mobile',
      ],
      'users': [
        'id',
        'username',
        'password_hash',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
        'login_failed_attempts',
        'login_locked_until_ms',
      ],
      'user_permissions': [
        'id',
        'user_id',
        'screen_name',
        'can_view',
        'can_add',
        'can_edit',
        'can_delete',
        'can_print',
        'can_post',
        'can_review_approve',
        'can_lock_period',
        'can_close_period',
        'can_reopen_period',
      ],
      'accounting_periods': [
        'id',
        'start_date',
        'end_date',
        'status',
        'created_at',
        'created_by_user_id',
      ],
      'accounting_period_events': [
        'id',
        'period_id',
        'action',
        'actor_user_id',
        'actor_name',
        'reason',
        'readiness_summary',
        'created_at',
      ],
      'audit_logs': [
        'id',
        'user_id',
        'actor_name',
        'action',
        'details',
        'timestamp',
        'entity_type',
        'entity_id',
        'amount_minor',
      ],
      'cities': ['id', 'name'],
      'nationalities': ['id', 'name'],
      'banks': ['id', 'name', 'account_id'],
      'property_types': ['id', 'name'],
      'unit_types': ['id', 'name'],
      'cost_centers': ['id', 'code', 'name'],
      'accounts': [
        'id',
        'code',
        'name',
        'parent_id',
        'account_type',
        'balance',
      ],
      'owners': [
        'id',
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
        'iban',
        'account_id',
        'commission_rate',
      ],
      'properties': [
        'id',
        'name',
        'owner_id',
        'city_id',
        'property_type_id',
        'cost_center_id',
        'address',
        'deed_number',
      ],
      'units': [
        'id',
        'property_id',
        'owner_id',
        'unit_number',
        'unit_type_id',
        'floor',
        'elec_meter',
        'water_meter',
        'status',
        'default_rent',
        'default_rent_period',
      ],
      'tenants': [
        'id',
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
        'account_id',
        'nationality_id',
      ],
      'contracts': [
        'id',
        'tenant_id',
        'unit_id',
        'start_date',
        'end_date',
        'rent_amount',
        'unit_rent_amount',
        'unit_rent_period',
        'party_snapshot',
        'terms_conditions_snapshot',
        'payment_method',
        'purpose',
        'electricity_reading',
        'status',
        'cancellation_reason',
        'cancelled_at',
        'early_termination_date',
        'early_termination_reason',
      ],
      'contract_installments': [
        'id',
        'contract_id',
        'amount',
        'paid_amount',
        'due_date',
        'status',
      ],
      'tax_invoices': [
        'id',
        'contract_id',
        'installment_id',
        'journal_entry_id',
        'invoice_date',
        'net_amount',
        'total_amount',
        'tax_amount',
        'tax_rate',
      ],
      'credit_notes': [
        'id',
        'invoice_id',
        'note_date',
        'amount',
        'reason',
        'status',
        'net_amount_minor',
        'tax_amount_minor',
        'total_amount_minor',
        'tax_rate_snapshot',
        'tax_account_id',
        'journal_entry_id',
        'reversal_journal_entry_id',
        'reversal_reason',
        'created_by',
        'created_at',
        'posted_by',
        'posted_at',
        'reversed_by',
        'reversed_at',
      ],
      'vouchers': [
        'id',
        'voucher_type',
        'voucher_date',
        'amount',
        'tenant_id',
        'party_name',
        'journal_entry_id',
        'description',
        'period_from_date',
        'period_to_date',
      ],
      'voucher_installment_allocations': [
        'id',
        'voucher_id',
        'installment_id',
        'amount',
      ],
      'voucher_invoice_allocations': [
        'id',
        'voucher_id',
        'invoice_id',
        'amount',
      ],
      'collection_allocations': [
        'id',
        'voucher_id',
        'installment_id',
        'invoice_id',
        'amount_minor',
        'rent_amount_minor',
        'tax_amount_minor',
        'created_at',
        'created_by',
      ],
      'refund_allocations': [
        'id',
        'refund_voucher_id',
        'collection_allocation_id',
        'credit_note_id',
        'amount_minor',
        'rent_amount_minor',
        'tax_amount_minor',
        'created_at',
        'created_by',
      ],
      'legacy_tenant_payment_reviews': [
        'voucher_id',
        'tenant_id',
        'amount_minor',
        'status',
        'reason',
        'reviewed_by',
        'reviewed_at',
        'reclassification_journal_entry_id',
      ],
      'legacy_invoice_reviews': [
        'invoice_id',
        'contract_id',
        'status',
        'reason',
        'reviewed_by',
        'reviewed_at',
      ],
      'journal_entries': ['id', 'entry_date', 'description', 'is_posted'],
      'journal_lines': [
        'id',
        'journal_entry_id',
        'account_id',
        'debit',
        'credit',
        'cost_center_id',
        'description',
      ],
      'sms_settings': [
        'id',
        'api_url',
        'api_key',
        'api_key_secret_id',
        'sender_name',
        'reminder_template',
        'receipt_template',
      ],
      'sms_logs': [
        'id',
        'recipient_number',
        'message_text',
        'sent_at',
        'status',
      ],
      'tenant_notices': [
        'id',
        'tenant_id',
        'contract_id',
        'recipient_name_snapshot',
        'recipient_phone_snapshot',
        'contract_snapshot_json',
        'subject',
        'body',
        'notice_date',
        'status',
        'created_by',
        'created_at',
        'updated_by',
        'updated_at',
        'issued_by',
        'issued_at',
      ],
      'tenant_notice_events': [
        'id',
        'notice_id',
        'event_type',
        'user_id',
        'created_at',
        'details',
      ],
      'property_sale_reviews': [
        'id',
        'target_type',
        'property_id',
        'unit_id',
        'requested_by',
        'requested_at',
        'reason',
        'proposed_amount_minor',
        'proposed_sale_date',
        'proposed_buyer_owner_id',
        'target_snapshot_json',
        'active_contract_count_at_request',
        'status',
        'reviewed_by',
        'reviewed_at',
        'review_reason',
        'cancelled_by',
        'cancelled_at',
        'cancel_reason',
      ],
      'property_sale_review_events': [
        'id',
        'sale_review_id',
        'event_type',
        'user_id',
        'created_at',
        'reason',
        'details',
      ],
      'property_sale_executions': [
        'id',
        'sale_review_id',
        'target_type',
        'property_id',
        'unit_id',
        'seller_owner_id',
        'buyer_owner_id',
        'seller_name_snapshot',
        'buyer_name_snapshot',
        'sale_price_minor',
        'sale_date',
        'deed_reference',
        'execution_reason',
        'executed_by',
        'executed_at',
        'transfer_applied_at',
      ],
      'property_sale_execution_events': [
        'id',
        'sale_execution_id',
        'event_type',
        'user_id',
        'created_at',
        'reason',
        'details',
      ],
      'property_sale_accounting_records': [
        'id',
        'sale_execution_id',
        'supersedes_record_id',
        'book_value_minor',
        'manual_journal_entry_id',
        'accounting_note',
        'approved_by',
        'approved_at',
      ],
      'owner_settlements': [
        'id',
        'voucher_id',
        'owner_id',
        'owner_account_id',
        'cash_account_id',
        'journal_entry_id',
        'amount_minor',
        'settlement_date',
        'owner_name_snapshot',
        'description',
        'created_by',
        'created_at',
      ],
      'owner_settlement_journal_intents': [
        'journal_entry_id',
        'owner_id',
        'owner_account_id',
        'amount_minor',
      ],
    };
    final missingSchema = <String>[];
    for (final entry in requiredColumns.entries) {
      final columns = (await db.rawQuery(
        'PRAGMA table_info("${entry.key}")',
      )).map((row) => row['name']?.toString()).toSet();
      final missing = entry.value.where((column) => !columns.contains(column));
      missingSchema.addAll(missing.map((column) => '${entry.key}.$column'));
    }
    if (missingSchema.isNotEmpty) {
      throw StateError(
        'مخطط النسخة غير مكتمل؛ الجداول/الأعمدة المفقودة: ${missingSchema.join('، ')}',
      );
    }
    final triggers = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    )).map((row) => row['name']?.toString()).toSet();
    const requiredTriggers = [
      'units_unique_number_insert',
      'units_unique_number_update',
      'collection_allocations_voucher_valid',
      'collection_allocations_immutable_update',
      'collection_allocations_no_delete',
      'refund_allocations_voucher_match',
      'refund_allocations_source_cap',
      'refund_allocations_no_update',
      'refund_allocations_no_delete',
      'credit_notes_initial_draft',
      'credit_notes_valid_transition',
      'credit_notes_post_requires_journal',
      'credit_notes_reversal_requires_journal',
      'credit_notes_posted_immutable',
      'credit_notes_no_delete',
      'credit_notes_journal_entries_no_update',
      'credit_notes_journal_entries_no_delete',
      'credit_notes_journal_lines_no_update',
      'credit_notes_journal_lines_no_delete',
      'refund_allocations_credit_note_match',
      'refund_allocations_credit_note_cap',
      'tenant_notices_issued_immutable',
      'tenant_notices_no_delete',
      'tenant_notice_events_no_update',
      'tenant_notice_events_no_delete',
      'property_sale_reviews_target_valid_insert',
      'property_sale_reviews_target_valid_update',
      'property_sale_reviews_initial_pending',
      'property_sale_reviews_no_overlap_insert',
      'property_sale_reviews_no_overlap_update',
      'property_sale_reviews_identity_immutable',
      'property_sale_reviews_decision_immutable',
      'property_sale_reviews_valid_transition',
      'property_sale_reviews_no_delete',
      'property_sale_review_events_no_update',
      'property_sale_review_events_no_delete',
      'property_sale_reviews_terms_required_insert',
      'property_sale_reviews_buyer_not_seller_insert',
      'property_sale_reviews_accepted_terms_required',
      'property_sale_reviews_terms_immutable',
      'property_sale_reviews_cannot_cancel_executed',
      'property_sale_executions_valid_insert',
      'property_sale_executions_apply_transfer_once',
      'property_sale_executions_no_delete',
      'properties_owner_change_requires_sale',
      'units_owner_change_requires_sale',
      'property_sale_accounting_valid_insert',
      'property_sale_accounting_records_no_update',
      'property_sale_accounting_records_no_delete',
      'property_sale_execution_events_no_update',
      'property_sale_execution_events_no_delete',
      'owner_account_general_disbursement_block',
      'owner_settlement_journal_intent_valid_insert',
      'owner_settlement_journal_lines_owner_debit_requires_link',
      'owner_settlement_valid_insert',
      'owner_settlement_consume_journal_intent',
      'owner_settlements_no_update',
      'owner_settlements_no_delete',
      'owner_settlement_vouchers_no_update',
      'owner_settlement_vouchers_no_delete',
      'owner_settlement_journal_entries_no_update',
      'owner_settlement_journal_entries_no_delete',
      'owner_settlement_journal_lines_no_update',
      'owner_settlement_journal_lines_no_delete',
      'audit_logs_no_update',
      'audit_logs_no_delete',
      'accounting_periods_initially_open',
      'accounting_periods_no_overlap_insert',
      'accounting_periods_no_overlap_update',
      'accounting_periods_identity_immutable',
      'accounting_periods_valid_transition',
      'accounting_periods_transition_audited',
      'accounting_periods_no_delete',
      'accounting_period_events_state_valid',
      'accounting_period_events_no_update',
      'accounting_period_events_no_delete',
      'accounting_period_journal_insert_guard',
      'accounting_period_journal_update_guard',
      'accounting_period_journal_delete_guard',
      'accounting_period_lines_insert_guard',
      'accounting_period_lines_update_guard',
      'accounting_period_lines_delete_guard',
    ];
    final missingTriggers = requiredTriggers
        .where((trigger) => !triggers.contains(trigger))
        .toList();
    if (missingTriggers.isNotEmpty) {
      throw StateError(
        'مخطط النسخة يفتقد حواجز سلامة الوحدات والاستردادات والإشعارات: ${missingTriggers.join('، ')}',
      );
    }
    final triggerDefinitions = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'",
    );
    final triggerSqlByName = <String, String>{
      for (final row in triggerDefinitions)
        row['name'].toString(): (row['sql']?.toString() ?? '')
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
    };
    const requiredOwnerTriggerFragments = <String, List<String>>{
      'owner_account_general_disbursement_block': [
        'before insert on vouchers',
        "new.voucher_type = 'صرف عام'",
        'from journal_lines jl',
        'raise(abort',
      ],
      'owner_settlement_journal_intent_valid_insert': [
        'before insert on owner_settlement_journal_intents',
        'owner_parent.code = \'2101\'',
        'new.amount_minor > 0',
        'raise(abort',
      ],
      'owner_settlement_journal_lines_owner_debit_requires_link': [
        'before insert on journal_lines',
        'new.debit > 0',
        'from owner_settlement_journal_intents intent',
        'raise(abort',
      ],
      'owner_settlement_valid_insert': [
        'before insert on owner_settlements',
        "v.voucher_type = 'صرف مستحقات مالك'",
        'owner settlement exceeds the posted owner payable balance',
        'owner settlement exceeds the posted cash balance',
        'raise(abort',
      ],
      'owner_settlement_consume_journal_intent': [
        'after insert on owner_settlements',
        'delete from owner_settlement_journal_intents',
      ],
      'owner_settlements_no_update': [
        'before update on owner_settlements',
        'raise(abort',
      ],
      'owner_settlements_no_delete': [
        'before delete on owner_settlements',
        'raise(abort',
      ],
      'owner_settlement_vouchers_no_update': [
        'before update on vouchers',
        'from owner_settlements s where s.voucher_id = old.id',
        'raise(abort',
      ],
      'owner_settlement_vouchers_no_delete': [
        'before delete on vouchers',
        'from owner_settlements s where s.voucher_id = old.id',
        'raise(abort',
      ],
      'owner_settlement_journal_entries_no_update': [
        'before update on journal_entries',
        'from owner_settlements s where s.journal_entry_id = old.id',
        'raise(abort',
      ],
      'owner_settlement_journal_entries_no_delete': [
        'before delete on journal_entries',
        'from owner_settlements s where s.journal_entry_id = old.id',
        'raise(abort',
      ],
      'owner_settlement_journal_lines_no_update': [
        'before update on journal_lines',
        'from owner_settlements s where s.journal_entry_id = old.journal_entry_id',
        'raise(abort',
      ],
      'owner_settlement_journal_lines_no_delete': [
        'before delete on journal_lines',
        'from owner_settlements s where s.journal_entry_id = old.journal_entry_id',
        'raise(abort',
      ],
    };
    final invalidOwnerTriggerDefinitions = <String>[];
    for (final entry in requiredOwnerTriggerFragments.entries) {
      final definition = triggerSqlByName[entry.key] ?? '';
      if (entry.value.any((fragment) => !definition.contains(fragment))) {
        invalidOwnerTriggerDefinitions.add(entry.key);
      }
    }
    if (invalidOwnerTriggerDefinitions.isNotEmpty) {
      throw StateError(
        'تعريف حواجز سداد المالك في النسخة غير مطابق أو معطل: ${invalidOwnerTriggerDefinitions.join('، ')}',
      );
    }
    const requiredAccountingPeriodTriggerFragments = <String, List<String>>{
      'accounting_periods_transition_audited': [
        'before update of status on accounting_periods',
        'accounting_period_events',
        'raise(abort',
      ],
      'accounting_period_events_no_update': [
        'before update on accounting_period_events',
        'raise(abort',
      ],
      'accounting_period_journal_insert_guard': [
        'before insert on journal_entries',
        'date(substr(new.entry_date, 1, 10))',
        'p.status in (\'locked\', \'closed\')',
        'raise(abort',
      ],
      'accounting_period_journal_update_guard': [
        'before update on journal_entries',
        'old.entry_date',
        'new.entry_date',
        'raise(abort',
      ],
      'accounting_period_journal_delete_guard': [
        'before delete on journal_entries',
        'old.entry_date',
        'raise(abort',
      ],
      'accounting_period_lines_insert_guard': [
        'before insert on journal_lines',
        'join accounting_periods p',
        'raise(abort',
      ],
      'accounting_period_lines_update_guard': [
        'before update on journal_lines',
        'old.journal_entry_id, new.journal_entry_id',
        'raise(abort',
      ],
      'accounting_period_lines_delete_guard': [
        'before delete on journal_lines',
        'old.journal_entry_id',
        'raise(abort',
      ],
    };
    final invalidAccountingPeriodTriggerDefinitions = <String>[];
    for (final entry in requiredAccountingPeriodTriggerFragments.entries) {
      final definition = triggerSqlByName[entry.key] ?? '';
      if (entry.value.any((fragment) => !definition.contains(fragment))) {
        invalidAccountingPeriodTriggerDefinitions.add(entry.key);
      }
    }
    if (invalidAccountingPeriodTriggerDefinitions.isNotEmpty) {
      throw StateError(
        'تعريف حواجز الفترة المحاسبية في النسخة غير مطابق أو معطل: ${invalidAccountingPeriodTriggerDefinitions.join('، ')}',
      );
    }
    final views = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'view'",
    )).map((row) => row['name']?.toString()).toSet();
    if (!views.contains('collection_allocation_balances')) {
      throw StateError('مخطط النسخة يفتقد عرض رصيد التحصيلات بعد الاسترداد');
    }
    if (!views.contains('credit_note_refund_balances')) {
      throw StateError(
        'مخطط النسخة يفتقد عرض رصيد الإشعارات الدائنة القابل للاسترداد',
      );
    }
    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    )).map((row) => row['name']?.toString()).toSet();
    const requiredIndexes = [
      'tax_invoices_installment_unique',
      'voucher_invoice_unique',
      'collection_allocation_invoice_unique',
      'collection_allocation_installment_unique',
      'collection_allocation_installment_idx',
      'collection_allocation_voucher_idx',
      'refund_allocations_source_idx',
      'legacy_tenant_payment_review_status_idx',
      'legacy_invoice_review_status_idx',
      'property_sale_reviews_status_idx',
      'property_sale_review_events_review_idx',
      'property_sale_reviews_proposed_buyer_idx',
      'property_sale_executions_property_date_idx',
      'property_sale_executions_unit_date_idx',
      'property_sale_execution_events_execution_idx',
      'property_sale_accounting_root_unique',
      'property_sale_accounting_successor_unique',
      'owner_settlements_owner_date_idx',
      'owner_settlements_cash_date_idx',
      'accounting_period_events_period_idx',
    ];
    final missingIndexes = requiredIndexes
        .where((index) => !indexes.contains(index))
        .toList();
    if (missingIndexes.isNotEmpty) {
      throw StateError(
        'مخطط النسخة يفتقد فهارس الربط المالي: ${missingIndexes.join('، ')}',
      );
    }
  }

  Future<void> _rejectUncheckpointedWal(String databasePath) async {
    final walFile = File('$databasePath-wal');
    if (await walFile.exists() && await walFile.length() > 0) {
      throw StateError(
        'ملف قاعدة البيانات يحتوي على سجل WAL منفصل. أوقف البرنامج الذي يستخدمه وأنشئ نسخة مكتملة من داخل Aqari قبل الاستعادة.',
      );
    }
  }

  Future<void> _deleteSqliteSidecars(String path) async {
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$path$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
  }

  Future<String> factoryReset({required String currentPassword}) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    final currentUserId = PermissionRuntime.userId;
    if (currentUserId == null || currentPassword.isEmpty) {
      throw StateError('يلزم إدخال كلمة مرور المستخدم الحالي قبل التهيئة');
    }
    final path = await getDbPath();
    final rollbackPath = join(
      File(path).parent.path,
      'aqari_pre_reset_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final current = await database;
    final currentUserRows = await current.query(
      'users',
      columns: ['password_hash', 'role', 'is_active', 'login_locked_until_ms'],
      where: 'id = ?',
      whereArgs: [currentUserId],
      limit: 1,
    );
    if (currentUserRows.isEmpty ||
        (currentUserRows.first['is_active'] as num?)?.toInt() != 1 ||
        currentUserRows.first['role'] != PermissionRuntime.role) {
      throw StateError('جلسة المستخدم غير صالحة؛ سجّل الدخول مجددًا');
    }
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final loginLockUntil =
        (currentUserRows.first['login_locked_until_ms'] as num?)?.toInt();
    if (loginLockUntil != null && loginLockUntil > nowMs) {
      throw StateError('الحساب مقيد مؤقتًا؛ لم تُمسح أي بيانات');
    }
    final currentPasswordHash =
        currentUserRows.first['password_hash']?.toString() ?? '';
    if (!CryptoUtils.verifyPassword(currentPassword, currentPasswordHash)) {
      await recordFailedLoginAttempt(
        currentUserId,
        expectedPasswordHash: currentPasswordHash,
      );
      throw StateError('كلمة المرور الحالية غير صحيحة؛ لم تُمسح أي بيانات');
    }
    final previousCredentials = await _resolveAllSmsCredentials(current);
    final previousCredentialIds = previousCredentials
        .map((credential) => credential.id)
        .whereType<String>()
        .toSet();
    final previousCredentialReferences = await _captureSmsCredentialReferences(
      current,
    );
    await _createDatabaseSnapshot(rollbackPath, clearSmsSecretReference: true);
    await current.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    await current.close();
    _database = null;
    try {
      await _deleteSqliteSidecars(path);
      await databaseFactory.deleteDatabase(path);
      _database = await _initDB('desktop_erp.db');
      await _validateOpenDatabase(_database!, requireCurrentSchema: true);
      for (final credentialId in previousCredentialIds) {
        await _deleteSmsCredentialIgnoringFailure(credentialId);
      }
      return rollbackPath;
    } catch (error) {
      Object? rollbackError;
      try {
        if (_database != null) await _database!.close();
        _database = null;
        await _deleteSqliteSidecars(path);
        final live = File(path);
        if (await live.exists()) await live.delete();
        await File(rollbackPath).copy(path);
        _database = await _initDB('desktop_erp.db');
        await _validateOpenDatabase(_database!, requireCurrentSchema: true);
        await _restoreSmsCredentialReferences(
          _database!,
          previousCredentialReferences,
        );
      } catch (failure) {
        rollbackError = failure;
      }
      if (rollbackError != null) {
        throw StateError(
          'فشلت التهيئة ($error)، وتعذرت الاستعادة التلقائية. نسخة الرجوع: $rollbackPath. الخطأ: $rollbackError',
        );
      }
      throw StateError(
        'فشلت التهيئة، وأُعيدت قاعدة التشغيل من نسخة الرجوع المحفوظة في $rollbackPath. السبب: $error',
      );
    }
  }

  Future<Database> _initDB(String filePath) async {
    // Initialize FFI for Windows desktop
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, 'AbdullahAlNaqeebERP', filePath);

    // Ensure the directory exists
    await Directory(
      join(dbPath.path, 'AbdullahAlNaqeebERP'),
    ).create(recursive: true);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA secure_delete = ON');
        },
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _ensureColumn(db, 'owners', 'iban', 'TEXT');
    }
    if (oldVersion < 3) {
      await _ensureColumn(db, 'properties', 'property_type_id', 'INTEGER');
      await _ensureColumn(db, 'units', 'floor', 'TEXT');
      await _ensureColumn(db, 'units', 'elec_meter', 'TEXT');
      await _ensureColumn(db, 'units', 'water_meter', 'TEXT');
    }
    if (oldVersion < 4) {
      await _ensureColumn(db, 'sms_settings', 'reminder_template', 'TEXT');
      await _ensureColumn(db, 'sms_settings', 'receipt_template', 'TEXT');
    }
    if (oldVersion < 5) {
      await _ensureColumn(db, 'company_info', 'logo_path', 'TEXT');
      await _ensureColumn(db, 'company_info', 'terms_conditions', 'TEXT');
    }
    if (oldVersion < 6) {
      final columnsToAdd = [
        'activity_name_ar',
        'activity_name_en',
        'address_ar',
        'address_en',
        'po_box',
        'telephone',
        'fax',
        'mobile',
      ];
      for (final col in columnsToAdd) {
        await _ensureColumn(db, 'company_info', col, 'TEXT');
      }
    }
    if (oldVersion < 7) {
      await _ensureColumn(
        db,
        'users',
        'must_change_password',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(db, 'vouchers', 'description', 'TEXT');
      await db.execute(
        "UPDATE users SET must_change_password = 1 WHERE username = 'admin' AND password_hash = '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92';",
      );
    }
    if (oldVersion < 8) {
      for (final column in [
        'identity_issue_date',
        'identity_source',
        'profession',
      ]) {
        await _ensureColumn(db, 'owners', column, 'TEXT');
        await _ensureColumn(db, 'tenants', column, 'TEXT');
      }
      await _ensureColumn(db, 'contracts', 'purpose', 'TEXT');
      await _ensureColumn(db, 'contracts', 'electricity_reading', 'TEXT');
    }
    if (oldVersion < 9) {
      await _ensureColumn(db, 'vouchers', 'party_name', 'TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS voucher_installment_allocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voucher_id INTEGER NOT NULL,
          installment_id INTEGER NOT NULL,
          amount REAL NOT NULL CHECK (amount > 0),
          UNIQUE (voucher_id, installment_id),
          FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
          FOREIGN KEY (installment_id) REFERENCES contract_installments (id)
        )
      ''');
    }
    if (oldVersion < 10) {
      const legacySeed =
          '1. يلتزم المستأجر بسداد الإيجار في المواعيد المحددة.\n'
          '2. لا يحق للمستأجر تأجير العين بالباطن.';
      await db.update(
        'company_info',
        {'terms_conditions': LeaseContractTerms.defaultText},
        where:
            'terms_conditions IS NULL OR TRIM(terms_conditions) = ? OR terms_conditions = ?',
        whereArgs: ['', legacySeed],
      );
    }
    if (oldVersion < 11) {
      await _ensureColumn(
        db,
        'units',
        'default_rent_period',
        "TEXT CHECK (default_rent_period IN ('monthly', 'annual') OR default_rent_period IS NULL)",
      );
      await _ensureColumn(db, 'contracts', 'unit_rent_amount', 'REAL');
      await _ensureColumn(
        db,
        'contracts',
        'unit_rent_period',
        "TEXT CHECK (unit_rent_period IN ('monthly', 'annual') OR unit_rent_period IS NULL)",
      );
    }
    if (oldVersion < 12) {
      await DatabaseIntegrityMigrations.upgradeToV12(db);
    }
    if (oldVersion < 13) {
      await _ensureColumn(
        db,
        'users',
        'is_active',
        'INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldVersion < 14) {
      await _ensureColumn(
        db,
        'company_info',
        'tax_rate',
        'REAL NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100)',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'net_amount',
        'REAL NOT NULL DEFAULT 0',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'tax_rate',
        'REAL CHECK (tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100))',
      );
      // Historical invoices did not retain a rate. Preserve their recorded
      // gross/tax and derive only the net; leave tax_rate NULL rather than
      // inventing the setting that was in effect at the time.
      await db.execute('''
        UPDATE tax_invoices
        SET net_amount = ROUND(MAX(total_amount - tax_amount, 0), 2)
      ''');
    }
    if (oldVersion < 15) {
      await _ensureColumn(
        db,
        'tax_invoices',
        'installment_id',
        'INTEGER REFERENCES contract_installments(id)',
      );
      await _ensureColumn(
        db,
        'tax_invoices',
        'journal_entry_id',
        'INTEGER REFERENCES journal_entries(id)',
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS voucher_invoice_allocations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voucher_id INTEGER NOT NULL,
          invoice_id INTEGER NOT NULL,
          amount REAL NOT NULL CHECK (amount > 0),
          FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
          FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
        )
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS tax_invoices_installment_unique
        ON tax_invoices(installment_id)
        WHERE installment_id IS NOT NULL
      ''');
      await db.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS voucher_invoice_unique
        ON voucher_invoice_allocations(voucher_id, invoice_id)
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS voucher_invoice_invoice_idx
        ON voucher_invoice_allocations(invoice_id)
      ''');
    }
    if (oldVersion < 16) {
      await _createRefundSchema(db);
      await db.execute('''
        INSERT OR IGNORE INTO legacy_invoice_reviews (
          invoice_id, contract_id, status
        )
        SELECT id, contract_id, 'pending'
        FROM tax_invoices
        WHERE contract_id IS NOT NULL AND installment_id IS NULL
      ''');
      await db.execute('''
        INSERT OR IGNORE INTO collection_allocations (
          voucher_id, installment_id, invoice_id, amount_minor,
          rent_amount_minor, tax_amount_minor
        )
        SELECT
          via.voucher_id,
          ti.installment_id,
          ti.id,
          CAST(ROUND(via.amount * 100) AS INTEGER),
          MIN(
            CAST(ROUND(via.amount * 100) AS INTEGER),
            COALESCE((
              SELECT SUM(CAST(ROUND(via2.amount * 100) AS INTEGER))
              FROM voucher_installment_allocations via2
              WHERE via2.voucher_id = via.voucher_id
                AND via2.installment_id = ti.installment_id
            ), 0)
          ),
          CAST(ROUND(via.amount * 100) AS INTEGER) - MIN(
            CAST(ROUND(via.amount * 100) AS INTEGER),
            COALESCE((
              SELECT SUM(CAST(ROUND(via2.amount * 100) AS INTEGER))
              FROM voucher_installment_allocations via2
              WHERE via2.voucher_id = via.voucher_id
                AND via2.installment_id = ti.installment_id
            ), 0)
          )
        FROM voucher_invoice_allocations via
        JOIN vouchers v ON v.id = via.voucher_id
        JOIN tax_invoices ti ON ti.id = via.invoice_id
        JOIN contracts c ON c.id = ti.contract_id AND c.tenant_id = v.tenant_id
        JOIN contract_installments ci
          ON ci.id = ti.installment_id AND ci.contract_id = c.id
        JOIN journal_entries je ON je.id = v.journal_entry_id AND je.is_posted = 1
        WHERE v.voucher_type = 'قبض مستأجر'
          AND v.tenant_id IS NOT NULL
          AND ti.installment_id IS NOT NULL
          AND ROUND(via.amount * 100) > 0
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit) FROM journal_lines line
            WHERE line.journal_entry_id = je.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.credit) FROM journal_lines line
            WHERE line.journal_entry_id = je.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = je.id
              AND cash.code LIKE '11%'
              AND line.credit = 0
          ), 0) * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1 FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = je.id
              AND cash.code LIKE '11%' AND line.credit > 0
          )
          AND CAST(ROUND(COALESCE((
            SELECT SUM(via2.amount)
            FROM voucher_invoice_allocations via2
            WHERE via2.voucher_id = via.voucher_id
          ), 0) * 100) AS INTEGER) <= CAST(ROUND(v.amount * 100) AS INTEGER)
      ''');
      await db.execute('''
        INSERT OR IGNORE INTO collection_allocations (
          voucher_id, installment_id, invoice_id, amount_minor,
          rent_amount_minor, tax_amount_minor
        )
        SELECT
          via.voucher_id,
          via.installment_id,
          NULL,
          CAST(ROUND(via.amount * 100) AS INTEGER),
          CAST(ROUND(via.amount * 100) AS INTEGER),
          0
        FROM voucher_installment_allocations via
        JOIN vouchers v ON v.id = via.voucher_id
        JOIN contract_installments ci ON ci.id = via.installment_id
        JOIN contracts c ON c.id = ci.contract_id AND c.tenant_id = v.tenant_id
        JOIN journal_entries je ON je.id = v.journal_entry_id AND je.is_posted = 1
        WHERE v.voucher_type = 'قبض مستأجر'
          AND v.tenant_id IS NOT NULL
          AND ROUND(via.amount * 100) > 0
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit) FROM journal_lines line
            WHERE line.journal_entry_id = je.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.credit) FROM journal_lines line
            WHERE line.journal_entry_id = je.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = je.id
              AND cash.code LIKE '11%'
              AND line.credit = 0
          ), 0) * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1 FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = je.id
              AND cash.code LIKE '11%' AND line.credit > 0
          )
          AND CAST(ROUND(COALESCE((
            SELECT SUM(via2.amount)
            FROM voucher_installment_allocations via2
            WHERE via2.voucher_id = via.voucher_id
          ), 0) * 100) AS INTEGER) <= CAST(ROUND(v.amount * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1
            FROM voucher_invoice_allocations via2
            JOIN tax_invoices ti2 ON ti2.id = via2.invoice_id
            WHERE via2.voucher_id = via.voucher_id
              AND ti2.installment_id = via.installment_id
          )
      ''');
      await db.execute('''
        INSERT OR IGNORE INTO legacy_tenant_payment_reviews (
          voucher_id, tenant_id, amount_minor, status
        )
        SELECT
          v.id,
          v.tenant_id,
          CAST(ROUND(v.amount * 100) AS INTEGER),
          'pending'
        FROM vouchers v
        WHERE v.voucher_type = 'صرف مستأجر'
          AND v.tenant_id IS NOT NULL
          AND ROUND(v.amount * 100) > 0
      ''');
    }
    if (oldVersion < 17) {
      // Reinstall stricter source-validation triggers for databases upgraded
      // to v16 before the ledger checks were introduced.
      await _createRefundSchema(db);
    }
    if (oldVersion < 18) {
      await _ensureColumn(db, 'vouchers', 'period_from_date', 'TEXT');
      await _ensureColumn(db, 'vouchers', 'period_to_date', 'TEXT');
    }
    if (oldVersion < 19) {
      await _ensureColumn(db, 'contracts', 'cancellation_reason', 'TEXT');
      await _ensureColumn(db, 'contracts', 'cancelled_at', 'TEXT');
    }
    if (oldVersion < 20) {
      await _createTenantNoticeSchema(db);
    }
    if (oldVersion < 21) {
      await _ensureColumn(
        db,
        'user_permissions',
        'can_review_approve',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _createPropertySaleReviewSchema(db);
    }
    if (oldVersion < 22) {
      await _ensureColumn(
        db,
        'tax_invoices',
        'tax_account_id',
        'INTEGER REFERENCES accounts (id)',
      );
    }
    if (oldVersion < 23) {
      await _ensureColumn(db, 'audit_logs', 'entity_type', 'TEXT');
      await _ensureColumn(db, 'audit_logs', 'entity_id', 'INTEGER');
      await _ensureColumn(db, 'audit_logs', 'amount_minor', 'INTEGER');
      await _rebuildAuditLogsTable(db);
      await _createAuditTrailSchema(db);
    }
    if (oldVersion < 24) {
      await _ensureColumn(
        db,
        'contracts',
        'renewed_from_contract_id',
        'INTEGER REFERENCES contracts (id)',
      );
      await _createContractRenewalSchema(db);
    }
    if (oldVersion < 25) {
      await _ensureColumn(
        db,
        'units',
        'owner_id',
        'INTEGER REFERENCES owners (id) ON DELETE RESTRICT',
      );
      await createPropertySaleExecutionSchema(db);
    }
    if (oldVersion < 26) {
      await _ensureColumn(
        db,
        'property_sale_reviews',
        'proposed_buyer_owner_id',
        'INTEGER REFERENCES owners (id) ON DELETE RESTRICT',
      );
      await db.execute('''
        CREATE INDEX IF NOT EXISTS property_sale_reviews_proposed_buyer_idx
        ON property_sale_reviews(proposed_buyer_owner_id)
        WHERE proposed_buyer_owner_id IS NOT NULL
      ''');
      await createPropertySaleExecutionSchema(db);
    }
    if (oldVersion < 27) {
      await createOwnerSettlementSchema(db);
    }
    if (oldVersion < 28) {
      await _ensureColumn(db, 'sms_settings', 'api_key_secret_id', 'TEXT');
    }
    if (oldVersion < 29) {
      await _ensureColumn(db, 'contracts', 'terms_conditions_snapshot', 'TEXT');
    }
    if (oldVersion < 30) {
      await CreditNoteSchema.upgradeToV30(db);
    }
    if (oldVersion < 31) {
      await _ensureColumn(
        db,
        'user_permissions',
        'can_lock_period',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(
        db,
        'user_permissions',
        'can_close_period',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(
        db,
        'user_permissions',
        'can_reopen_period',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await AccountingPeriodSchema.install(db);
    }
    if (oldVersion < 32) {
      await _ensureColumn(
        db,
        'users',
        'login_failed_attempts',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _ensureColumn(db, 'users', 'login_locked_until_ms', 'INTEGER');
    }
    if (oldVersion < 33) {
      await _ensureColumn(db, 'contracts', 'early_termination_date', 'TEXT');
      await _ensureColumn(db, 'contracts', 'early_termination_reason', 'TEXT');
    }
  }

  /// Rebuilds `audit_logs` without a foreign key on `user_id`.
  ///
  /// The trail must outlive the user it names. The original plain foreign key
  /// aborted user deletion, and `ON DELETE SET NULL` fires an UPDATE that the
  /// append-only trigger rejects — so no FK action is viable. The rebuild also
  /// adds the `entity_*`/`amount_minor` columns and the actor snapshot.
  Future<void> _rebuildAuditLogsTable(DatabaseExecutor db) async {
    final existing = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'audit_logs'",
    );
    if (existing.isEmpty) return;
    final definition = (existing.first['sql'] as String?) ?? '';
    if (!definition.contains('REFERENCES users')) return;
    await db.execute('''
      CREATE TABLE audit_logs_rebuilt (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        actor_name TEXT,
        action TEXT NOT NULL,
        details TEXT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        entity_type TEXT,
        entity_id INTEGER,
        amount_minor INTEGER
      )
    ''');
    await db.execute('''
      INSERT INTO audit_logs_rebuilt
        (id, user_id, actor_name, action, details, timestamp,
         entity_type, entity_id, amount_minor)
      SELECT
        a.id,
        a.user_id,
        COALESCE(u.full_name, u.username),
        a.action,
        a.details,
        a.timestamp,
        a.entity_type,
        a.entity_id,
        a.amount_minor
      FROM audit_logs a
      LEFT JOIN users u ON u.id = a.user_id
    ''');
    await db.execute('DROP TABLE audit_logs');
    await db.execute('ALTER TABLE audit_logs_rebuilt RENAME TO audit_logs');
  }

  /// Append-only enforcement for [audit_logs].
  ///
  /// This is application/SQLite-level protection: it stops the app and any SQL
  /// executed through this database connection from rewriting history. It does
  /// not protect the file from someone with direct filesystem access who opens
  /// it with another tool and drops the triggers.
  Future<void> _createAuditTrailSchema(DatabaseExecutor db) async {
    await _ensureColumn(db, 'audit_logs', 'entity_type', 'TEXT');
    await _ensureColumn(db, 'audit_logs', 'entity_id', 'INTEGER');
    await _ensureColumn(db, 'audit_logs', 'amount_minor', 'INTEGER');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp
      ON audit_logs (timestamp, id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_audit_logs_action
      ON audit_logs (action)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_audit_logs_entity
      ON audit_logs (entity_type, entity_id)
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS audit_logs_no_update
      BEFORE UPDATE ON audit_logs
      BEGIN
        SELECT RAISE(ABORT, 'audit log records are append-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS audit_logs_no_delete
      BEFORE DELETE ON audit_logs
      BEGIN
        SELECT RAISE(ABORT, 'audit log records are append-only');
      END
    ''');
  }

  Future<void> _ensureColumn(
    DatabaseExecutor db,
    String table,
    String column,
    String declaration,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info("$table")');
    if (columns.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE "$table" ADD COLUMN "$column" $declaration');
  }

  Future<void> _createRefundSchema(DatabaseExecutor db) async {
    await db.execute(
      'DROP TRIGGER IF EXISTS collection_allocations_voucher_valid',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collection_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_id INTEGER NOT NULL,
        installment_id INTEGER NOT NULL,
        invoice_id INTEGER,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        rent_amount_minor INTEGER NOT NULL CHECK (rent_amount_minor >= 0),
        tax_amount_minor INTEGER NOT NULL CHECK (tax_amount_minor >= 0),
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by INTEGER,
        CHECK (rent_amount_minor + tax_amount_minor = amount_minor),
        CHECK (invoice_id IS NOT NULL OR tax_amount_minor = 0),
        FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (installment_id) REFERENCES contract_installments (id),
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS collection_allocations_voucher_valid
      BEFORE INSERT ON collection_allocations
      WHEN NOT EXISTS (
        SELECT 1
        FROM vouchers receipt
        JOIN journal_entries journal ON journal.id = receipt.journal_entry_id
        JOIN contract_installments ci ON ci.id = NEW.installment_id
        JOIN contracts c ON c.id = ci.contract_id
        WHERE receipt.id = NEW.voucher_id
          AND receipt.voucher_type = 'قبض مستأجر'
          AND receipt.tenant_id IS NOT NULL
          AND receipt.tenant_id = c.tenant_id
          AND journal.is_posted = 1
          AND CAST(ROUND(receipt.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit) FROM journal_lines line
            WHERE line.journal_entry_id = journal.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(receipt.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.credit) FROM journal_lines line
            WHERE line.journal_entry_id = journal.id
          ), 0) * 100) AS INTEGER)
          AND CAST(ROUND(receipt.amount * 100) AS INTEGER) = CAST(ROUND(COALESCE((
            SELECT SUM(line.debit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = journal.id
              AND cash.code LIKE '11%'
              AND line.credit = 0
          ), 0) * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = journal.id
              AND cash.code LIKE '11%'
              AND line.credit > 0
          )
          AND COALESCE((
            SELECT SUM(existing.amount_minor)
            FROM collection_allocations existing
            WHERE existing.voucher_id = receipt.id
          ), 0) + NEW.amount_minor <= CAST(ROUND(receipt.amount * 100) AS INTEGER)
          AND (
            (
              NEW.invoice_id IS NULL
              AND EXISTS (
                SELECT 1
                FROM voucher_installment_allocations installment_allocation
                WHERE installment_allocation.voucher_id = receipt.id
                  AND installment_allocation.installment_id = NEW.installment_id
                  AND CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
                    = NEW.amount_minor
              )
            ) OR (
              NEW.invoice_id IS NOT NULL
              AND EXISTS (
                SELECT 1
                FROM tax_invoices ti
                JOIN contracts invoice_contract ON invoice_contract.id = ti.contract_id
                JOIN contract_installments invoice_installment
                  ON invoice_installment.id = ti.installment_id
                  AND invoice_installment.contract_id = invoice_contract.id
                JOIN voucher_invoice_allocations invoice_allocation
                  ON invoice_allocation.invoice_id = ti.id
                  AND invoice_allocation.voucher_id = receipt.id
                JOIN voucher_installment_allocations installment_allocation
                  ON installment_allocation.voucher_id = receipt.id
                  AND installment_allocation.installment_id = NEW.installment_id
                WHERE ti.id = NEW.invoice_id
                  AND ti.installment_id = NEW.installment_id
                  AND invoice_contract.tenant_id = receipt.tenant_id
                  AND invoice_installment.id = NEW.installment_id
                  AND CAST(ROUND(invoice_allocation.amount * 100) AS INTEGER)
                    = NEW.amount_minor
                  AND CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
                    = NEW.rent_amount_minor
              )
            )
          )
          AND (
            NEW.invoice_id IS NULL OR EXISTS (
              SELECT 1
              FROM tax_invoices ti
              JOIN contracts invoice_contract ON invoice_contract.id = ti.contract_id
              JOIN contract_installments invoice_installment
                ON invoice_installment.id = ti.installment_id
                AND invoice_installment.contract_id = invoice_contract.id
              WHERE ti.id = NEW.invoice_id
                AND ti.installment_id = NEW.installment_id
                AND invoice_installment.id = NEW.installment_id
                AND invoice_contract.tenant_id = receipt.tenant_id
            )
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'collection must reference a posted receipt for the same tenant');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS collection_allocations_immutable_update
      BEFORE UPDATE ON collection_allocations
      WHEN NEW.voucher_id IS NOT OLD.voucher_id
        OR NEW.installment_id IS NOT OLD.installment_id
        OR NEW.created_at IS NOT OLD.created_at
        OR NEW.created_by IS NOT OLD.created_by
        OR (OLD.invoice_id IS NOT NULL AND NEW.invoice_id IS NOT OLD.invoice_id)
        OR (
          NEW.invoice_id IS NOT NULL AND NOT (
            EXISTS (
              SELECT 1
              FROM legacy_invoice_reviews review
              JOIN tax_invoices ti ON ti.id = review.invoice_id
              JOIN contracts invoice_contract ON invoice_contract.id = ti.contract_id
              JOIN contract_installments ci
                ON ci.id = NEW.installment_id
                AND ci.contract_id = invoice_contract.id
              JOIN vouchers receipt ON receipt.id = OLD.voucher_id
              JOIN voucher_installment_allocations installment_allocation
                ON installment_allocation.voucher_id = OLD.voucher_id
                AND installment_allocation.installment_id = NEW.installment_id
              WHERE review.invoice_id = NEW.invoice_id
                AND review.status = 'pending'
                AND review.contract_id = ti.contract_id
                AND OLD.invoice_id IS NULL
                AND ti.installment_id = NEW.installment_id
                AND invoice_contract.tenant_id = receipt.tenant_id
                AND (
                  (
                    NOT EXISTS (
                      SELECT 1
                      FROM voucher_invoice_allocations invoice_allocation
                      WHERE invoice_allocation.invoice_id = ti.id
                        AND invoice_allocation.voucher_id = OLD.voucher_id
                    )
                    AND NEW.amount_minor = CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
                    AND NEW.rent_amount_minor = NEW.amount_minor
                    AND NEW.tax_amount_minor = 0
                  )
                  OR EXISTS (
                    SELECT 1
                    FROM voucher_invoice_allocations invoice_allocation
                    WHERE invoice_allocation.invoice_id = ti.id
                      AND invoice_allocation.voucher_id = OLD.voucher_id
                      AND NEW.amount_minor = CAST(ROUND(invoice_allocation.amount * 100) AS INTEGER)
                      AND NEW.rent_amount_minor = CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
                      AND NEW.tax_amount_minor = NEW.amount_minor - NEW.rent_amount_minor
                  )
                )
            )
            OR EXISTS (
              SELECT 1
              FROM tax_invoices ti
              JOIN journal_entries je ON je.id = ti.journal_entry_id
              JOIN contracts invoice_contract ON invoice_contract.id = ti.contract_id
              JOIN contract_installments ci
                ON ci.id = NEW.installment_id
                AND ci.contract_id = invoice_contract.id
              JOIN vouchers receipt ON receipt.id = OLD.voucher_id
              JOIN voucher_installment_allocations installment_allocation
                ON installment_allocation.voucher_id = OLD.voucher_id
                AND installment_allocation.installment_id = NEW.installment_id
              WHERE ti.id = NEW.invoice_id
                AND ti.installment_id = NEW.installment_id
                AND ti.journal_entry_id IS NOT NULL
                AND je.is_posted = 1
                AND OLD.invoice_id IS NULL
                AND invoice_contract.tenant_id = receipt.tenant_id
                AND NEW.amount_minor = CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
                AND NEW.rent_amount_minor = NEW.amount_minor
                AND NEW.tax_amount_minor = 0
                AND NOT EXISTS (
                  SELECT 1 FROM legacy_invoice_reviews review
                  WHERE review.invoice_id = ti.id
                )
            )
          )
        )
        OR (
          (
            NEW.amount_minor IS NOT OLD.amount_minor
            OR NEW.rent_amount_minor IS NOT OLD.rent_amount_minor
            OR NEW.tax_amount_minor IS NOT OLD.tax_amount_minor
          )
          AND NOT EXISTS (
            SELECT 1
            FROM legacy_invoice_reviews review
            JOIN tax_invoices ti ON ti.id = review.invoice_id
            JOIN voucher_invoice_allocations invoice_allocation
              ON invoice_allocation.invoice_id = ti.id
              AND invoice_allocation.voucher_id = OLD.voucher_id
            JOIN voucher_installment_allocations installment_allocation
              ON installment_allocation.voucher_id = OLD.voucher_id
              AND installment_allocation.installment_id = NEW.installment_id
            WHERE review.invoice_id = NEW.invoice_id
              AND review.status = 'pending'
              AND OLD.invoice_id IS NULL
              AND ti.contract_id = review.contract_id
              AND ti.installment_id = NEW.installment_id
              AND NEW.amount_minor = CAST(ROUND(invoice_allocation.amount * 100) AS INTEGER)
              AND NEW.rent_amount_minor = CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
              AND NEW.tax_amount_minor = NEW.amount_minor - NEW.rent_amount_minor
              AND OLD.amount_minor = CAST(ROUND(installment_allocation.amount * 100) AS INTEGER)
              AND OLD.rent_amount_minor = OLD.amount_minor
              AND OLD.tax_amount_minor = 0
              AND COALESCE((
                SELECT SUM(amount_minor) FROM refund_allocations
                WHERE collection_allocation_id = OLD.id
              ), 0) <= NEW.amount_minor
              AND COALESCE((
                SELECT SUM(rent_amount_minor) FROM refund_allocations
                WHERE collection_allocation_id = OLD.id
              ), 0) <= NEW.rent_amount_minor
              AND COALESCE((
                SELECT SUM(tax_amount_minor) FROM refund_allocations
                WHERE collection_allocation_id = OLD.id
              ), 0) <= NEW.tax_amount_minor
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'collection allocations are immutable except for a validated legacy invoice reconciliation');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS collection_allocations_no_delete
      BEFORE DELETE ON collection_allocations
      BEGIN
        SELECT RAISE(ABORT, 'posted collection allocations are immutable');
      END
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS collection_allocation_invoice_unique
      ON collection_allocations(voucher_id, invoice_id)
      WHERE invoice_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS collection_allocation_installment_unique
      ON collection_allocations(voucher_id, installment_id)
      WHERE invoice_id IS NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS collection_allocation_installment_idx
      ON collection_allocations(installment_id, invoice_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS collection_allocation_voucher_idx
      ON collection_allocations(voucher_id, id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS refund_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        refund_voucher_id INTEGER NOT NULL,
        collection_allocation_id INTEGER NOT NULL,
        credit_note_id INTEGER REFERENCES credit_notes (id),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        rent_amount_minor INTEGER NOT NULL CHECK (rent_amount_minor >= 0),
        tax_amount_minor INTEGER NOT NULL CHECK (tax_amount_minor >= 0),
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by INTEGER,
        CHECK (rent_amount_minor + tax_amount_minor = amount_minor),
        UNIQUE (refund_voucher_id, collection_allocation_id),
        FOREIGN KEY (refund_voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (collection_allocation_id)
          REFERENCES collection_allocations (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS refund_allocations_source_idx
      ON refund_allocations(collection_allocation_id)
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_voucher_match
      BEFORE INSERT ON refund_allocations
      WHEN NOT EXISTS (
        SELECT 1
        FROM vouchers refund
        JOIN journal_entries refund_journal
          ON refund_journal.id = refund.journal_entry_id
        JOIN collection_allocations ca
          ON ca.id = NEW.collection_allocation_id
        JOIN vouchers receipt ON receipt.id = ca.voucher_id
        JOIN journal_entries receipt_journal
          ON receipt_journal.id = receipt.journal_entry_id
        WHERE refund.id = NEW.refund_voucher_id
          AND refund.voucher_type = 'صرف مستأجر'
          AND refund.tenant_id = receipt.tenant_id
          AND refund_journal.is_posted = 1
          AND receipt.voucher_type = 'قبض مستأجر'
          AND receipt_journal.is_posted = 1
      )
      BEGIN
        SELECT RAISE(ABORT, 'refund must reference posted vouchers for the same tenant');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_source_cap
      BEFORE INSERT ON refund_allocations
      WHEN NEW.amount_minor > COALESCE((
        SELECT ca.amount_minor - COALESCE((
          SELECT SUM(ra.amount_minor)
          FROM refund_allocations ra
          WHERE ra.collection_allocation_id = ca.id
        ), 0)
        FROM collection_allocations ca
        WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      OR NEW.rent_amount_minor > COALESCE((
        SELECT ca.rent_amount_minor - COALESCE((
          SELECT SUM(ra.rent_amount_minor)
          FROM refund_allocations ra
          WHERE ra.collection_allocation_id = ca.id
        ), 0)
        FROM collection_allocations ca
        WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      OR NEW.tax_amount_minor > COALESCE((
        SELECT ca.tax_amount_minor - COALESCE((
          SELECT SUM(ra.tax_amount_minor)
          FROM refund_allocations ra
          WHERE ra.collection_allocation_id = ca.id
        ), 0)
        FROM collection_allocations ca
        WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      BEGIN
        SELECT RAISE(ABORT, 'refund exceeds unrefunded collection allocation');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_no_update
      BEFORE UPDATE ON refund_allocations
      BEGIN
        SELECT RAISE(ABORT, 'posted refund allocations are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_no_delete
      BEFORE DELETE ON refund_allocations
      BEGIN
        SELECT RAISE(ABORT, 'posted refund allocations are immutable');
      END
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS legacy_tenant_payment_reviews (
        voucher_id INTEGER PRIMARY KEY,
        tenant_id INTEGER NOT NULL,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'refund', 'unrelated')),
        reason TEXT,
        reviewed_by INTEGER,
        reviewed_at TEXT,
        reclassification_journal_entry_id INTEGER,
        FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (reviewed_by) REFERENCES users (id),
        FOREIGN KEY (reclassification_journal_entry_id)
          REFERENCES journal_entries (id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS legacy_tenant_payment_review_status_idx
      ON legacy_tenant_payment_reviews(tenant_id, status, voucher_id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS legacy_invoice_reviews (
        invoice_id INTEGER PRIMARY KEY,
        contract_id INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'linked', 'non_billable')),
        reason TEXT,
        reviewed_by INTEGER,
        reviewed_at TEXT,
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id),
        FOREIGN KEY (contract_id) REFERENCES contracts (id),
        FOREIGN KEY (reviewed_by) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS legacy_invoice_review_status_idx
      ON legacy_invoice_reviews(contract_id, status, invoice_id)
    ''');
    await db.execute('''
      CREATE VIEW IF NOT EXISTS collection_allocation_balances AS
      SELECT
        ca.id,
        ca.voucher_id,
        ca.installment_id,
        ca.invoice_id,
        ca.amount_minor,
        ca.rent_amount_minor,
        ca.tax_amount_minor,
        ca.amount_minor - COALESCE(SUM(ra.amount_minor), 0) AS remaining_minor,
        ca.rent_amount_minor - COALESCE(SUM(ra.rent_amount_minor), 0)
          AS remaining_rent_minor,
        ca.tax_amount_minor - COALESCE(SUM(ra.tax_amount_minor), 0)
          AS remaining_tax_minor
      FROM collection_allocations ca
      LEFT JOIN refund_allocations ra ON ra.collection_allocation_id = ca.id
      GROUP BY ca.id
    ''');
  }

  Future<void> _createTenantNoticeSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tenant_notices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tenant_id INTEGER NOT NULL,
        contract_id INTEGER,
        recipient_name_snapshot TEXT NOT NULL CHECK (length(trim(recipient_name_snapshot)) > 0),
        recipient_phone_snapshot TEXT,
        contract_snapshot_json TEXT,
        subject TEXT NOT NULL CHECK (length(trim(subject)) BETWEEN 1 AND 160),
        body TEXT NOT NULL CHECK (length(trim(body)) BETWEEN 1 AND 10000),
        notice_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'Draft' CHECK (status IN ('Draft', 'Issued')),
        created_by INTEGER,
        created_at TEXT NOT NULL,
        updated_by INTEGER,
        updated_at TEXT NOT NULL,
        issued_by INTEGER,
        issued_at TEXT,
        FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE RESTRICT,
        FOREIGN KEY (contract_id) REFERENCES contracts (id) ON DELETE RESTRICT,
        FOREIGN KEY (created_by) REFERENCES users (id),
        FOREIGN KEY (updated_by) REFERENCES users (id),
        FOREIGN KEY (issued_by) REFERENCES users (id),
        CHECK ((status = 'Draft' AND issued_by IS NULL AND issued_at IS NULL)
          OR (status = 'Issued' AND issued_at IS NOT NULL))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS tenant_notices_tenant_date_idx
      ON tenant_notices(tenant_id, notice_date DESC, id DESC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tenant_notice_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        notice_id INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        user_id INTEGER,
        created_at TEXT NOT NULL,
        details TEXT,
        FOREIGN KEY (notice_id) REFERENCES tenant_notices (id) ON DELETE RESTRICT,
        FOREIGN KEY (user_id) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS tenant_notice_events_notice_idx
      ON tenant_notice_events(notice_id, id)
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_notices_issued_immutable
      BEFORE UPDATE ON tenant_notices
      WHEN OLD.status = 'Issued'
      BEGIN
        SELECT RAISE(ABORT, 'issued tenant notices are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_notices_no_delete
      BEFORE DELETE ON tenant_notices
      BEGIN
        SELECT RAISE(ABORT, 'tenant notices cannot be deleted');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_notice_events_no_update
      BEFORE UPDATE ON tenant_notice_events
      BEGIN
        SELECT RAISE(ABORT, 'tenant notice events are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_notice_events_no_delete
      BEFORE DELETE ON tenant_notice_events
      BEGIN
        SELECT RAISE(ABORT, 'tenant notice events cannot be deleted');
      END
    ''');
  }

  Future<void> _createPropertySaleReviewSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS property_sale_reviews (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target_type TEXT NOT NULL CHECK (target_type IN ('property', 'unit')),
        property_id INTEGER NOT NULL,
        unit_id INTEGER,
        requested_by INTEGER NOT NULL,
        requested_at TEXT NOT NULL,
        reason TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 1000),
        proposed_amount_minor INTEGER
          CHECK (proposed_amount_minor IS NULL OR proposed_amount_minor > 0),
        proposed_sale_date TEXT,
        proposed_buyer_owner_id INTEGER
          REFERENCES owners (id) ON DELETE RESTRICT,
        target_snapshot_json TEXT NOT NULL,
        active_contract_count_at_request INTEGER NOT NULL DEFAULT 0
          CHECK (active_contract_count_at_request >= 0),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled')),
        reviewed_by INTEGER,
        reviewed_at TEXT,
        review_reason TEXT,
        cancelled_by INTEGER,
        cancelled_at TEXT,
        cancel_reason TEXT,
        FOREIGN KEY (property_id) REFERENCES properties (id) ON DELETE RESTRICT,
        FOREIGN KEY (unit_id) REFERENCES units (id) ON DELETE RESTRICT,
        FOREIGN KEY (requested_by) REFERENCES users (id) ON DELETE RESTRICT,
        FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE RESTRICT,
        FOREIGN KEY (cancelled_by) REFERENCES users (id) ON DELETE RESTRICT,
        CHECK ((target_type = 'property' AND unit_id IS NULL)
          OR (target_type = 'unit' AND unit_id IS NOT NULL)),
        CHECK (
          (status = 'pending' AND reviewed_by IS NULL AND reviewed_at IS NULL
            AND review_reason IS NULL AND cancelled_by IS NULL
            AND cancelled_at IS NULL AND cancel_reason IS NULL)
          OR
          (status IN ('accepted', 'rejected') AND reviewed_by IS NOT NULL
            AND reviewed_at IS NOT NULL AND review_reason IS NOT NULL
            AND length(trim(review_reason)) > 0
            AND cancelled_by IS NULL AND cancelled_at IS NULL
            AND cancel_reason IS NULL)
          OR
          (status = 'cancelled' AND cancelled_by IS NOT NULL
            AND cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL
            AND length(trim(cancel_reason)) > 0
            AND ((reviewed_by IS NULL AND reviewed_at IS NULL
                AND review_reason IS NULL)
              OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
                AND review_reason IS NOT NULL
                AND length(trim(review_reason)) > 0)))
        )
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS property_sale_review_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_review_id INTEGER NOT NULL,
        event_type TEXT NOT NULL
          CHECK (event_type IN ('requested', 'accepted', 'rejected', 'cancelled')),
        user_id INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        details TEXT,
        FOREIGN KEY (sale_review_id) REFERENCES property_sale_reviews (id)
          ON DELETE RESTRICT,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE RESTRICT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS property_sale_reviews_status_idx
      ON property_sale_reviews(status, requested_at DESC, id DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS property_sale_reviews_proposed_buyer_idx
      ON property_sale_reviews(proposed_buyer_owner_id)
      WHERE proposed_buyer_owner_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS property_sale_reviews_property_open_unique
      ON property_sale_reviews(property_id)
      WHERE target_type = 'property' AND status IN ('pending', 'accepted')
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS property_sale_reviews_unit_open_unique
      ON property_sale_reviews(unit_id)
      WHERE target_type = 'unit' AND status IN ('pending', 'accepted')
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS property_sale_review_events_review_idx
      ON property_sale_review_events(sale_review_id, id)
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_target_valid_insert
      BEFORE INSERT ON property_sale_reviews
      WHEN (NEW.target_type = 'property' AND NEW.unit_id IS NOT NULL)
        OR (NEW.target_type = 'unit' AND NOT EXISTS (
          SELECT 1 FROM units
          WHERE id = NEW.unit_id AND property_id = NEW.property_id
        ))
      BEGIN
        SELECT RAISE(ABORT, 'property sale target does not match property/unit');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_target_valid_update
      BEFORE UPDATE OF target_type, property_id, unit_id
      ON property_sale_reviews
      WHEN (NEW.target_type = 'property' AND NEW.unit_id IS NOT NULL)
        OR (NEW.target_type = 'unit' AND NOT EXISTS (
          SELECT 1 FROM units
          WHERE id = NEW.unit_id AND property_id = NEW.property_id
        ))
      BEGIN
        SELECT RAISE(ABORT, 'property sale target does not match property/unit');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_initial_pending
      BEFORE INSERT ON property_sale_reviews
      WHEN NEW.status != 'pending'
      BEGIN
        SELECT RAISE(ABORT, 'property sale review must start pending');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_no_overlap_insert
      BEFORE INSERT ON property_sale_reviews
      WHEN NEW.status IN ('pending', 'accepted') AND EXISTS (
        SELECT 1 FROM property_sale_reviews old
        WHERE old.property_id = NEW.property_id
          AND old.status IN ('pending', 'accepted')
          AND (old.target_type = 'property' OR NEW.target_type = 'property'
            OR old.unit_id = NEW.unit_id)
      )
      BEGIN
        SELECT RAISE(ABORT, 'overlapping open property sale review exists');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_no_overlap_update
      BEFORE UPDATE OF status ON property_sale_reviews
      WHEN NEW.status IN ('pending', 'accepted') AND EXISTS (
        SELECT 1 FROM property_sale_reviews old
        WHERE old.id != NEW.id AND old.property_id = NEW.property_id
          AND old.status IN ('pending', 'accepted')
          AND (old.target_type = 'property' OR NEW.target_type = 'property'
            OR old.unit_id = NEW.unit_id)
      )
      BEGIN
        SELECT RAISE(ABORT, 'overlapping open property sale review exists');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_identity_immutable
      BEFORE UPDATE ON property_sale_reviews
      WHEN OLD.target_type IS NOT NEW.target_type
        OR OLD.property_id IS NOT NEW.property_id
        OR OLD.unit_id IS NOT NEW.unit_id
        OR OLD.requested_by IS NOT NEW.requested_by
        OR OLD.requested_at IS NOT NEW.requested_at
        OR OLD.reason IS NOT NEW.reason
        OR OLD.proposed_amount_minor IS NOT NEW.proposed_amount_minor
        OR OLD.proposed_sale_date IS NOT NEW.proposed_sale_date
        OR OLD.target_snapshot_json IS NOT NEW.target_snapshot_json
        OR OLD.active_contract_count_at_request IS NOT NEW.active_contract_count_at_request
      BEGIN
        SELECT RAISE(ABORT, 'property sale request details are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_valid_transition
      BEFORE UPDATE OF status ON property_sale_reviews
      WHEN NOT ((OLD.status = 'pending'
          AND NEW.status IN ('accepted', 'rejected', 'cancelled'))
        OR (OLD.status = 'accepted' AND NEW.status = 'cancelled'))
      BEGIN
        SELECT RAISE(ABORT, 'invalid property sale review transition');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_decision_immutable
      BEFORE UPDATE ON property_sale_reviews
      WHEN (
        NOT (OLD.status = 'pending'
          AND NEW.status IN ('accepted', 'rejected'))
        AND (
          OLD.reviewed_by IS NOT NEW.reviewed_by
          OR OLD.reviewed_at IS NOT NEW.reviewed_at
          OR OLD.review_reason IS NOT NEW.review_reason
        )
      ) OR (
        OLD.status = NEW.status AND (
          OLD.cancelled_by IS NOT NEW.cancelled_by
          OR OLD.cancelled_at IS NOT NEW.cancelled_at
          OR OLD.cancel_reason IS NOT NEW.cancel_reason
        )
      )
      BEGIN
        SELECT RAISE(ABORT, 'property sale review decisions are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_reviews_no_delete
      BEFORE DELETE ON property_sale_reviews
      BEGIN
        SELECT RAISE(ABORT, 'property sale reviews cannot be deleted');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_review_events_no_update
      BEFORE UPDATE ON property_sale_review_events
      BEGIN
        SELECT RAISE(ABORT, 'property sale review events are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS property_sale_review_events_no_delete
      BEFORE DELETE ON property_sale_review_events
      BEGIN
        SELECT RAISE(ABORT, 'property sale review events cannot be deleted');
      END
    ''');
  }

  Future<void> _createContractRenewalSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS contracts_live_renewal_source_unique
      ON contracts(renewed_from_contract_id)
      WHERE renewed_from_contract_id IS NOT NULL AND status != 'Cancelled'
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS contracts_renewal_link_valid_insert
      BEFORE INSERT ON contracts
      WHEN NEW.renewed_from_contract_id IS NOT NULL
      BEGIN
        SELECT CASE WHEN NOT EXISTS (
          SELECT 1 FROM contracts source
          WHERE source.id = NEW.renewed_from_contract_id
            AND source.status = 'Active'
            AND source.unit_id = NEW.unit_id
            AND source.tenant_id = NEW.tenant_id
            AND DATE(NEW.start_date) = DATE(source.end_date, '+1 day')
        ) THEN RAISE(ABORT, 'invalid contract renewal link') END;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS contracts_renewal_link_immutable
      BEFORE UPDATE OF renewed_from_contract_id ON contracts
      WHEN OLD.renewed_from_contract_id IS NOT NEW.renewed_from_contract_id
      BEGIN
        SELECT RAISE(ABORT, 'contract renewal links are immutable');
      END
    ''');
  }

  Future _createDB(Database db, int version) async {
    // 1. Company Info
    await db.execute('''
      CREATE TABLE company_info (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name_ar TEXT NOT NULL,
        name_en TEXT,
        activity TEXT,
        address TEXT,
        default_currency TEXT,
        tax_number TEXT,
        tax_rate REAL NOT NULL DEFAULT 0 CHECK (tax_rate >= 0 AND tax_rate <= 100),
        commercial_register TEXT,
        logo_path TEXT,
        terms_conditions TEXT,
        activity_name_ar TEXT,
        activity_name_en TEXT,
        address_ar TEXT,
        address_en TEXT,
        po_box TEXT,
        telephone TEXT,
        fax TEXT,
        mobile TEXT
      )
    ''');

    // 2. Users and Permissions
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL,
        cash_box_account_id INTEGER,
        must_change_password INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        login_failed_attempts INTEGER NOT NULL DEFAULT 0,
        login_locked_until_ms INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE user_permissions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        screen_name TEXT NOT NULL,
        can_view INTEGER DEFAULT 0,
        can_add INTEGER DEFAULT 0,
        can_edit INTEGER DEFAULT 0,
        can_delete INTEGER DEFAULT 0,
        can_print INTEGER DEFAULT 0,
        can_post INTEGER DEFAULT 0,
        can_review_approve INTEGER NOT NULL DEFAULT 0,
        can_lock_period INTEGER NOT NULL DEFAULT 0,
        can_close_period INTEGER NOT NULL DEFAULT 0,
        can_reopen_period INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    // 3. Audit Logs
    //
    // Deliberately no foreign key on user_id: an append-only trail must survive
    // user deletion, and any FK action would either block the delete or fire an
    // UPDATE that the append-only trigger rejects. actor_name snapshots the
    // acting user so the trail stays readable after the user is gone.
    await db.execute('''
      CREATE TABLE audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        actor_name TEXT,
        action TEXT NOT NULL,
        details TEXT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        entity_type TEXT,
        entity_id INTEGER,
        amount_minor INTEGER
      )
    ''');

    // 4. Lookups
    await db.execute('''
      CREATE TABLE cities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE nationalities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE banks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        account_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE property_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE unit_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE cost_centers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL
      )
    ''');

    // 5. Chart of Accounts
    await db.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        parent_id INTEGER,
        account_type TEXT,
        balance REAL DEFAULT 0.0,
        FOREIGN KEY (parent_id) REFERENCES accounts (id)
      )
    ''');

    // 6. Owners, Properties, Units
    await db.execute('''
      CREATE TABLE owners (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        identity_number TEXT,
        identity_issue_date TEXT,
        identity_source TEXT,
        profession TEXT,
        mobile TEXT,
        iban TEXT,
        account_id INTEGER,
        commission_rate REAL,
        FOREIGN KEY (account_id) REFERENCES accounts (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE properties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        owner_id INTEGER NOT NULL,
        city_id INTEGER,
        property_type_id INTEGER,
        cost_center_id INTEGER,
        address TEXT,
        deed_number TEXT,
        FOREIGN KEY (owner_id) REFERENCES owners (id),
        FOREIGN KEY (city_id) REFERENCES cities (id),
        FOREIGN KEY (property_type_id) REFERENCES property_types (id),
        FOREIGN KEY (cost_center_id) REFERENCES cost_centers (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER NOT NULL,
        owner_id INTEGER,
        unit_number TEXT NOT NULL,
        unit_type_id INTEGER,
        floor TEXT,
        elec_meter TEXT,
        water_meter TEXT,
        status TEXT DEFAULT 'شاغرة',
        default_rent REAL,
        default_rent_period TEXT CHECK (default_rent_period IN ('monthly', 'annual') OR default_rent_period IS NULL),
        FOREIGN KEY (property_id) REFERENCES properties (id),
        FOREIGN KEY (unit_type_id) REFERENCES unit_types (id),
        FOREIGN KEY (owner_id) REFERENCES owners (id) ON DELETE RESTRICT
      )
    ''');
    await DatabaseIntegrityMigrations.installUnitNumberGuards(db);

    // 7. Tenants and Contracts
    await db.execute('''
      CREATE TABLE tenants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        identity_number TEXT,
        identity_issue_date TEXT,
        identity_source TEXT,
        profession TEXT,
        mobile TEXT,
        account_id INTEGER,
        nationality_id INTEGER,
        FOREIGN KEY (account_id) REFERENCES accounts (id),
        FOREIGN KEY (nationality_id) REFERENCES nationalities (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE contracts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tenant_id INTEGER NOT NULL,
        unit_id INTEGER NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        rent_amount REAL NOT NULL,
        unit_rent_amount REAL,
        unit_rent_period TEXT CHECK (unit_rent_period IN ('monthly', 'annual') OR unit_rent_period IS NULL),
        party_snapshot TEXT,
        terms_conditions_snapshot TEXT,
        payment_method TEXT,
        purpose TEXT,
        electricity_reading TEXT,
        status TEXT DEFAULT 'Active',
        cancellation_reason TEXT,
        cancelled_at TEXT,
        early_termination_date TEXT,
        early_termination_reason TEXT,
        renewed_from_contract_id INTEGER REFERENCES contracts (id),
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (unit_id) REFERENCES units (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE contract_installments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        paid_amount REAL DEFAULT 0.0,
        due_date TEXT NOT NULL,
        status TEXT DEFAULT 'Unpaid',
        FOREIGN KEY (contract_id) REFERENCES contracts (id)
      )
    ''');

    // 8. Invoices and Vouchers
    await db.execute('''
      CREATE TABLE tax_invoices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contract_id INTEGER,
        installment_id INTEGER,
        journal_entry_id INTEGER,
        invoice_date TEXT NOT NULL,
        net_amount REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL,
        tax_amount REAL NOT NULL,
        tax_rate REAL CHECK (tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100)),
        tax_account_id INTEGER REFERENCES accounts (id),
        FOREIGN KEY (contract_id) REFERENCES contracts (id),
        FOREIGN KEY (installment_id) REFERENCES contract_installments (id),
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX tax_invoices_installment_unique
      ON tax_invoices(installment_id)
      WHERE installment_id IS NOT NULL
    ''');

    await CreditNoteSchema.createTable(db);

    await db.execute('''
      CREATE TABLE vouchers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_type TEXT NOT NULL,
        voucher_date TEXT NOT NULL,
        amount REAL NOT NULL,
        tenant_id INTEGER,
        party_name TEXT,
        journal_entry_id INTEGER,
        description TEXT,
        period_from_date TEXT,
        period_to_date TEXT,
        FOREIGN KEY (tenant_id) REFERENCES tenants (id),
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE voucher_installment_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        voucher_id INTEGER NOT NULL,
        installment_id INTEGER NOT NULL,
        amount REAL NOT NULL CHECK (amount > 0),
        UNIQUE (voucher_id, installment_id),
        FOREIGN KEY (voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (installment_id) REFERENCES contract_installments (id)
      )
    ''');

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
    await db.execute('''
      CREATE UNIQUE INDEX voucher_invoice_unique
      ON voucher_invoice_allocations(voucher_id, invoice_id)
    ''');
    await db.execute('''
      CREATE INDEX voucher_invoice_invoice_idx
      ON voucher_invoice_allocations(invoice_id)
    ''');

    // 9. General Accounting (Journal Entries)
    await db.execute('''
      CREATE TABLE journal_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entry_date TEXT NOT NULL,
        description TEXT,
        is_posted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE journal_lines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        journal_entry_id INTEGER NOT NULL,
        account_id INTEGER NOT NULL,
        debit REAL DEFAULT 0.0,
        credit REAL DEFAULT 0.0,
        cost_center_id INTEGER,
        description TEXT,
        FOREIGN KEY (journal_entry_id) REFERENCES journal_entries (id),
        FOREIGN KEY (account_id) REFERENCES accounts (id),
        FOREIGN KEY (cost_center_id) REFERENCES cost_centers (id)
      )
    ''');

    // 10. SMS
    await db.execute('''
      CREATE TABLE sms_settings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        api_url TEXT,
        api_key TEXT,
        api_key_secret_id TEXT,
        sender_name TEXT,
        reminder_template TEXT,
        receipt_template TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sms_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipient_number TEXT NOT NULL,
        message_text TEXT NOT NULL,
        sent_at TEXT,
        status TEXT
      )
    ''');

    await _createRefundSchema(db);
    await CreditNoteSchema.installGuards(db);
    await _createTenantNoticeSchema(db);
    await _createPropertySaleReviewSchema(db);
    await createPropertySaleExecutionSchema(db);
    await _createContractRenewalSchema(db);
    await _createAuditTrailSchema(db);
    await createOwnerSettlementSchema(db);
    await AccountingPeriodSchema.install(db);
    await _insertSeedData(db);
  }

  Future _insertSeedData(Database db) async {
    // Seed Company Info
    await db.insert('company_info', {
      'name_ar': 'مؤسسة عبدالله النقيب التجارية',
      'name_en': 'Abdullah Al-Naqeeb Trading Est.',
      'activity': 'إدارة وتطوير العقارات والتأجير',
      'address': 'اليمن',
      'default_currency': 'ريال يمني (YER)',
      'terms_conditions': LeaseContractTerms.defaultText,
    });

    // Seed Admin User (password: 123456 encrypted in SHA-256 in production logic, here we place the pre-hashed string for 123456)
    // SHA-256 for '123456' is '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
    await db.insert('users', {
      'username': 'admin',
      'password_hash':
          '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
      'full_name': 'مدير النظام',
      'role': 'SuperAdmin',
      'must_change_password': 1,
    });

    // Seed Lookups
    final cities = ['صنعاء', 'الحديدة', 'عدن', 'تعز', 'إب'];
    for (var city in cities) {
      await db.insert('cities', {'name': city});
    }

    final propertyTypes = [
      'عمارة سكنية',
      'مجمع تجاري',
      'فيلا',
      'مستودع',
      'أرض',
    ];
    for (var pType in propertyTypes) {
      await db.insert('property_types', {'name': pType});
    }

    final unitTypes = ['شقة', 'محل تجاري', 'مكتب', 'معرض', 'ملحق', 'مستودع'];
    for (var uType in unitTypes) {
      await db.insert('unit_types', {'name': uType});
    }

    // Seed Chart of Accounts
    final accounts = [
      {
        'code': '1',
        'name': 'الأصول',
        'parent_id': null,
        'account_type': 'Asset',
      },
      {
        'code': '11',
        'name': 'النقدية والبنوك',
        'parent_id': 1,
        'account_type': 'Asset',
      },
      {
        'code': '1101',
        'name': 'الصندوق الرئيسي',
        'parent_id': 2,
        'account_type': 'Asset',
      },
      {
        'code': '1102',
        'name': 'البنك',
        'parent_id': 2,
        'account_type': 'Asset',
      },
      {
        'code': '1201',
        'name': 'ذمم المستأجرين',
        'parent_id': 1,
        'account_type': 'Asset',
      },
      {
        'code': '2',
        'name': 'الخصوم',
        'parent_id': null,
        'account_type': 'Liability',
      },
      {
        'code': '2101',
        'name': 'حسابات الملاك الجارية',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '2102',
        'name': 'تأمينات المستأجرين المستردة',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '2103',
        'name': 'ضريبة القيمة المضافة',
        'parent_id': 6,
        'account_type': 'Liability',
      },
      {
        'code': '4',
        'name': 'الإيرادات',
        'parent_id': null,
        'account_type': 'Revenue',
      },
      {
        'code': '4101',
        'name': 'إيرادات إيجارات العقارات',
        'parent_id': 10,
        'account_type': 'Revenue',
      },
      {
        'code': '4102',
        'name': 'إيرادات عمولات السعي والإدارة',
        'parent_id': 10,
        'account_type': 'Revenue',
      },
      {
        'code': '5',
        'name': 'المصروفات',
        'parent_id': null,
        'account_type': 'Expense',
      },
      {
        'code': '5101',
        'name': 'المصروفات الإدارية والنثرية',
        'parent_id': 13,
        'account_type': 'Expense',
      },
      {
        'code': '5102',
        'name': 'رواتب وأجور الموظفين',
        'parent_id': 13,
        'account_type': 'Expense',
      },
      {
        'code': '5103',
        'name': 'مصاريف صيانة العقارات',
        'parent_id': 13,
        'account_type': 'Expense',
      },
    ];

    for (var acc in accounts) {
      await db.insert('accounts', acc);
    }
  }

  // --- CRUD Operations for Authentication and Users ---

  /// Credential lookup for AuthProvider only; this is not a UI user model.
  Future<Map<String, dynamic>?> getAuthenticationRecordByUsername(
    String username,
  ) async {
    if (PermissionRuntime.hasSession) {
      throw StateError('واجهة بيانات الاعتماد مخصصة لما قبل تسجيل الدخول');
    }
    final db = await instance.database;
    final result = await db.query(
      'users',
      columns: [
        'id',
        'username',
        'password_hash',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
        'login_failed_attempts',
        'login_locked_until_ms',
      ],
      where: 'username = ?',
      whereArgs: [username],
    );
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<void> recordFailedLoginAttempt(
    int userId, {
    required String expectedPasswordHash,
  }) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: [
          'password_hash',
          'is_active',
          'login_failed_attempts',
          'login_locked_until_ms',
        ],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      if (row['password_hash'] != expectedPasswordHash ||
          (row['is_active'] as num?)?.toInt() != 1) {
        return;
      }
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final currentLockUntil = (row['login_locked_until_ms'] as num?)?.toInt();
      if (currentLockUntil != null && currentLockUntil > nowMs) return;

      var failedAttempts = (row['login_failed_attempts'] as num?)?.toInt() ?? 0;
      if (currentLockUntil != null && currentLockUntil <= nowMs) {
        failedAttempts = 0;
      }
      failedAttempts = failedAttempts
          .clamp(0, _maxFailedLoginAttempts - 1)
          .toInt();
      failedAttempts++;
      final shouldLock = failedAttempts >= _maxFailedLoginAttempts;
      await txn.update(
        'users',
        {
          'login_failed_attempts': failedAttempts,
          'login_locked_until_ms': shouldLock
              ? nowMs + _loginLockoutDuration.inMilliseconds
              : null,
        },
        where: 'id = ? AND password_hash = ? AND is_active = 1',
        whereArgs: [userId, expectedPasswordHash],
      );
    });
  }

  Future<bool> clearFailedLoginAttemptsAfterAuthentication(
    int userId, {
    required String expectedPasswordHash,
  }) async {
    if (PermissionRuntime.hasSession) {
      throw StateError('تحديث حالة الدخول مخصص لما قبل تسجيل الدخول');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: ['password_hash', 'is_active', 'login_locked_until_ms'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty ||
          rows.first['password_hash'] != expectedPasswordHash ||
          (rows.first['is_active'] as num?)?.toInt() != 1) {
        return false;
      }
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final lockUntil = (rows.first['login_locked_until_ms'] as num?)?.toInt();
      if (lockUntil != null && lockUntil > nowMs) return false;
      final updated = await txn.update(
        'users',
        {'login_failed_attempts': 0, 'login_locked_until_ms': null},
        where: 'id = ? AND password_hash = ? AND is_active = 1',
        whereArgs: [userId, expectedPasswordHash],
      );
      return updated == 1;
    });
  }

  Future<bool> isUserSessionValid({
    required int userId,
    required String expectedRole,
    required String expectedPasswordHash,
  }) async {
    if (PermissionRuntime.userId != userId) return false;
    final db = await instance.database;
    final rows = await db.query(
      'users',
      columns: ['role', 'is_active', 'password_hash'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    return (row['is_active'] as num?)?.toInt() == 1 &&
        row['role'] == expectedRole &&
        row['password_hash'] == expectedPasswordHash;
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    PermissionRuntime.require('system_settings', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query(
      'users',
      columns: [
        'id',
        'username',
        'full_name',
        'role',
        'cash_box_account_id',
        'must_change_password',
        'is_active',
      ],
      orderBy: 'full_name COLLATE NOCASE',
    );
  }

  Future<int> insertUser(Map<String, dynamic> user) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.add);
    final username = user['username']?.toString().trim() ?? '';
    final fullName = user['full_name']?.toString().trim() ?? '';
    final passwordHash = user['password_hash']?.toString() ?? '';
    final role = user['role']?.toString() ?? '';
    if (username.isEmpty || fullName.isEmpty || passwordHash.isEmpty) {
      throw ArgumentError('اسم المستخدم والاسم الكامل وكلمة المرور مطلوبة');
    }
    if (!const {
      'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    }.contains(role)) {
      throw ArgumentError('الدور المحدد غير صالح');
    }
    if (role == 'SuperAdmin' && PermissionRuntime.role != 'SuperAdmin') {
      throw StateError('إنشاء مدير نظام أعلى يتطلب صلاحية مدير النظام الأعلى');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final id = await txn.insert('users', {
        'username': username,
        'full_name': fullName,
        'password_hash': passwordHash,
        'role': role,
        'cash_box_account_id': user['cash_box_account_id'],
        'must_change_password': user['must_change_password'] ?? 1,
      });
      await _recordAuditTx(
        txn,
        action: 'USER_CREATE',
        entityType: 'user',
        entityId: id,
        details: {'username': username, 'role': role},
      );
      return id;
    });
  }

  Future<int> updateUser(Map<String, dynamic> user) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    final id = (user['id'] as num?)?.toInt();
    if (id == null) throw ArgumentError('معرف المستخدم مطلوب');
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('المستخدم غير موجود');
      final currentRole = rows.first['role']?.toString() ?? '';
      final nextRole = user['role']?.toString() ?? currentRole;
      if (currentRole == 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تعديل حساب مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (!const {
        'SuperAdmin',
        'Admin',
        'Accountant',
        'DataEntry',
      }.contains(nextRole)) {
        throw ArgumentError('الدور المحدد غير صالح');
      }
      if (id == PermissionRuntime.userId && nextRole != currentRole) {
        throw StateError('لا يمكن تغيير دور المستخدم المسجل دخوله');
      }
      if (currentRole == 'SuperAdmin' &&
          nextRole != 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تخفيض مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (nextRole == 'SuperAdmin' &&
          currentRole != 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('ترقية مستخدم إلى مدير نظام أعلى تتطلب صلاحية خاصة');
      }
      if (currentRole == 'SuperAdmin' && nextRole != 'SuperAdmin') {
        final countRows = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin'",
        );
        final count = (countRows.first['count'] as num).toInt();
        if (count <= 1) throw StateError('لا يمكن تخفيض آخر مدير نظام أعلى');
      }
      final changes = <String, Object?>{};
      if (user.containsKey('username')) {
        final value = user['username']?.toString().trim() ?? '';
        if (value.isEmpty) throw ArgumentError('اسم المستخدم مطلوب');
        changes['username'] = value;
      }
      if (user.containsKey('full_name')) {
        final value = user['full_name']?.toString().trim() ?? '';
        if (value.isEmpty) throw ArgumentError('الاسم الكامل مطلوب');
        changes['full_name'] = value;
      }
      if (user.containsKey('role')) changes['role'] = nextRole;
      if (user.containsKey('cash_box_account_id')) {
        changes['cash_box_account_id'] = user['cash_box_account_id'];
      }
      if (changes.isEmpty) return 0;
      final updated = await txn.update(
        'users',
        changes,
        where: 'id = ?',
        whereArgs: [id],
      );
      if (updated > 0) {
        await _recordAuditTx(
          txn,
          action: 'USER_UPDATE',
          entityType: 'user',
          entityId: id,
          details: {'user_id': id},
        );
      }
      return updated;
    });
  }

  Future<int> updateUserPassword(
    int userId,
    String passwordHash, {
    bool mustChangePassword = false,
  }) async {
    if (PermissionRuntime.userId != userId) {
      PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    }
    final db = await instance.database;
    if (PermissionRuntime.userId != userId) {
      final target = await db.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (target.isNotEmpty &&
          target.first['role'] == 'SuperAdmin' &&
          PermissionRuntime.role != 'SuperAdmin') {
        throw StateError(
          'إعادة تعيين كلمة مرور مدير النظام الأعلى تتطلب صلاحية خاصة',
        );
      }
    }
    return db.update(
      'users',
      {
        'password_hash': passwordHash,
        'must_change_password': mustChangePassword ? 1 : 0,
        'login_failed_attempts': 0,
        'login_locked_until_ms': null,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<int> setUserActive(int userId, bool isActive) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    if (!isActive && userId == PermissionRuntime.userId) {
      throw StateError('لا يمكن إيقاف حساب المستخدم المسجل دخوله');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      final role = rows.first['role']?.toString() ?? '';
      final currentlyActive = (rows.first['is_active'] as num?)?.toInt() == 1;
      if (currentlyActive == isActive) return 0;
      if (role == 'SuperAdmin' && PermissionRuntime.role != 'SuperAdmin') {
        throw StateError('تغيير حالة مدير النظام الأعلى يتطلب صلاحية خاصة');
      }
      if (!isActive && role == 'SuperAdmin') {
        final activeSuperAdmins = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin' AND is_active = 1",
        );
        if ((activeSuperAdmins.first['count'] as num).toInt() <= 1) {
          throw StateError('لا يمكن إيقاف آخر مدير نظام أعلى نشط');
        }
      }
      final updated = await txn.update(
        'users',
        {
          'is_active': isActive ? 1 : 0,
          'login_failed_attempts': 0,
          'login_locked_until_ms': null,
        },
        where: 'id = ?',
        whereArgs: [userId],
      );
      if (updated > 0) {
        await _recordAuditTx(
          txn,
          action: isActive ? 'USER_ACTIVATE' : 'USER_DEACTIVATE',
          entityType: 'user',
          entityId: userId,
          details: {'user_id': userId, 'is_active': isActive ? 1 : 0},
        );
      }
      return updated;
    });
  }

  Future<int> deleteUser(int id) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.delete);
    if (id == PermissionRuntime.userId) {
      throw StateError('لا يمكن حذف حساب المستخدم المسجل دخوله');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      if (rows.first['role'] == 'SuperAdmin') {
        if (PermissionRuntime.role != 'SuperAdmin') {
          throw StateError('حذف مدير النظام الأعلى يتطلب صلاحية خاصة');
        }
        final countRows = await txn.rawQuery(
          "SELECT COUNT(*) AS count FROM users WHERE role = 'SuperAdmin'",
        );
        if ((countRows.first['count'] as num).toInt() <= 1) {
          throw StateError('لا يمكن حذف آخر مدير نظام أعلى');
        }
      }
      return txn.delete('users', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Map<String, dynamic>>> getUserPermissions(int userId) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.view);
    return _readUserPermissions(userId);
  }

  /// Used only after successful credential verification to establish the
  /// authenticated user's session before protected routes are shown.
  Future<List<Map<String, dynamic>>> getUserPermissionsForAuthentication(
    int userId,
  ) async {
    if (PermissionRuntime.userId != userId) {
      throw StateError('يمكن تحميل صلاحيات جلسة المستخدم الحالي فقط');
    }
    return _readUserPermissions(userId);
  }

  Future<List<Map<String, dynamic>>> _readUserPermissions(int userId) async {
    final db = await instance.database;
    return db.query(
      'user_permissions',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'screen_name',
    );
  }

  Future<void> replaceUserPermissions(
    int userId,
    List<Map<String, dynamic>> permissions,
  ) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    if (userId == PermissionRuntime.userId) {
      throw StateError('لا يمكن للمستخدم تعديل صلاحيات حسابه بنفسه');
    }
    final normalized = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final permission in permissions) {
      final code = permission['screen_name']?.toString() ?? '';
      if (AppPermissionCatalog.module(code) == null || !seen.add(code)) {
        throw ArgumentError('مجموعة الصلاحيات تحتوي قسمًا غير معروف أو مكررًا');
      }
      final normalizedRow = <String, Object?>{
        'screen_name': code,
        for (final action in AppPermissionAction.values)
          action.databaseColumn: _permissionValue(
            permission[action.databaseColumn],
          ),
      };
      if (normalizedRow['can_view'] == 0 &&
          AppPermissionAction.values
              .where((action) => action != AppPermissionAction.view)
              .any((action) => normalizedRow[action.databaseColumn] == 1)) {
        throw ArgumentError('لا يمكن منح إجراء دون منح صلاحية عرض القسم');
      }
      normalized.add(normalizedRow);
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final users = await txn.query(
        'users',
        columns: ['role'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty) throw StateError('المستخدم غير موجود');
      if (users.first['role'] == 'SuperAdmin') {
        if (PermissionRuntime.role != 'SuperAdmin') {
          throw StateError(
            'لا يمكن إلا لمدير نظام أعلى إدارة استثناء إعادة الفتح لحساب أعلى',
          );
        }
        if (normalized.any((permission) {
          return permission['screen_name'] != 'accounting_periods' ||
              permission['can_view'] != 1 ||
              permission['can_reopen_period'] != 1 ||
              AppPermissionAction.values
                  .where(
                    (action) =>
                        action != AppPermissionAction.view &&
                        action != AppPermissionAction.reopenPeriod,
                  )
                  .any((action) => permission[action.databaseColumn] != 0);
        })) {
          throw StateError(
            'لا يسمح لمدير النظام الأعلى إلا بتخصيص إعادة فتح الفترات بصورة مستقلة',
          );
        }
      }
      await txn.delete(
        'user_permissions',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      for (final permission in normalized) {
        await txn.insert('user_permissions', {
          'user_id': userId,
          ...permission,
        });
      }
      await _recordAuditTx(
        txn,
        action: 'USER_PERMISSIONS_UPDATE',
        entityType: 'user',
        entityId: userId,
        details: {'user_id': userId},
      );
    });
  }

  int _permissionValue(Object? value) =>
      value == true || (value is num && value.toInt() == 1) ? 1 : 0;

  // --- CRUD Operations for Audit Logs ---

  Future<int> recordAuthenticationAudit({
    required int expectedUserId,
    required bool isLogin,
  }) async {
    final userId = PermissionRuntime.userId;
    if (userId == null || userId != expectedUserId) {
      throw StateError('لا توجد جلسة مطابقة لتسجيل حدث التدقيق');
    }
    final db = await instance.database;
    return db.transaction(
      (txn) => _recordAuditTx(
        txn,
        action: isLogin ? 'LOGIN' : 'LOGOUT',
        entityType: 'session',
        entityId: userId,
        details: {'user_id': userId},
      ),
    );
  }

  // --- CRUD Operations for Company Info ---

  Future<Map<String, dynamic>?> getCompanyInfo() async {
    final db = await instance.database;
    final result = await db.query('company_info');
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<int> updateCompanyInfo(Map<String, dynamic> info) async {
    PermissionRuntime.require('system_settings', AppPermissionAction.edit);
    final db = await instance.database;
    final rows = await db.query('company_info', columns: ['id'], limit: 1);
    final values = Map<String, dynamic>.from(info)..remove('id');
    if (values.containsKey('tax_rate')) {
      final rawRate = values['tax_rate'];
      final rate = rawRate is num
          ? rawRate.toDouble()
          : double.tryParse(rawRate?.toString() ?? '') ?? double.nan;
      if (!InternalTax.isValidRate(rate)) {
        throw ArgumentError('نسبة الضريبة يجب أن تكون بين 0 و100');
      }
      values['tax_rate'] = rate;
    }
    if (rows.isEmpty) return db.insert('company_info', values);
    final id = info['id'] ?? rows.first['id'];
    return db.update('company_info', values, where: 'id = ?', whereArgs: [id]);
  }

  // --- Generic CRUD Operations for Lookups ---

  Future<List<Map<String, dynamic>>> getLookupData(String tableName) async {
    _validateLookupTable(tableName);
    _requireLookupReadPermission(tableName);
    final db = await instance.database;
    return await db.query(tableName);
  }

  Future<int> insertLookupData(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.add);
    final db = await instance.database;

    // Auto-generate code for cost_centers
    if (tableName == 'cost_centers' &&
        (!data.containsKey('code') ||
            data['code'] == null ||
            data['code'].toString().isEmpty)) {
      final List<Map<String, dynamic>> maps = await db.rawQuery(
        'SELECT code FROM cost_centers ORDER BY id DESC LIMIT 1',
      );
      String newCode = 'CC001';
      if (maps.isNotEmpty && maps.first['code'] != null) {
        final lastCode = maps.first['code'] as String;
        if (lastCode.startsWith('CC') && lastCode.length > 2) {
          final numericPart = int.tryParse(lastCode.substring(2));
          if (numericPart != null) {
            newCode = 'CC${(numericPart + 1).toString().padLeft(3, '0')}';
          }
        }
      }
      data['code'] = newCode;
    }

    return await db.insert(tableName, data);
  }

  Future<int> updateLookupData(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.edit);
    final db = await instance.database;
    return await db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [data['id']],
    );
  }

  Future<int> deleteLookupData(String tableName, int id) async {
    _validateLookupTable(tableName);
    PermissionRuntime.require('lookups', AppPermissionAction.delete);
    final db = await instance.database;
    return await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  // --- Accounting Operations ---

  Future<List<Map<String, dynamic>>> getAllAccounts() async {
    final canViewAccounting = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.view,
    );
    final canViewFinancial = PermissionRuntime.allows(
      'tenant_financial',
      AppPermissionAction.view,
    );
    final canViewReports = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    if (!canViewAccounting && !canViewFinancial && !canViewReports) {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    }
    final db = await instance.database;
    if (canViewAccounting) return db.query('accounts');
    return db.query(
      'accounts',
      columns: ['id', 'code', 'name', 'parent_id', 'account_type'],
    );
  }

  Future<Map<String, dynamic>?> getAccountById(int id) async {
    final canViewAccounting = PermissionRuntime.allows(
      'accounting',
      AppPermissionAction.view,
    );
    final canViewFinancial = PermissionRuntime.allows(
      'tenant_financial',
      AppPermissionAction.view,
    );
    final canViewReports = PermissionRuntime.allows(
      'reports',
      AppPermissionAction.view,
    );
    if (!canViewAccounting && !canViewFinancial && !canViewReports) {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    }
    final db = await instance.database;
    final result = await db.query(
      'accounts',
      columns: canViewAccounting
          ? null
          : ['id', 'code', 'name', 'parent_id', 'account_type'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<String> generateAccountCode(int parentId) async {
    PermissionRuntime.require('accounting', AppPermissionAction.add);
    final db = await instance.database;
    return _nextAccountCodeTx(db, parentId);
  }

  Future<String> _nextAccountCodeTx(
    DatabaseExecutor executor,
    int parentId, {
    bool allowDirectLegacyTenantLinks = false,
  }) async {
    final parentRows = await executor.query(
      'accounts',
      columns: ['id', 'code', 'parent_id', 'account_type', 'balance'],
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (parentRows.isEmpty) throw StateError('الحساب الأعلى غير موجود');
    final parent = parentRows.first;
    final parentCode = parent['code']?.toString() ?? '';
    final accountType = parent['account_type']?.toString();
    if (parentCode.isEmpty || !_accountTypeRootCodes.containsKey(accountType)) {
      throw StateError('نوع أو رمز الحساب الأعلى غير صالح');
    }

    final children = await executor.query(
      'accounts',
      columns: ['code'],
      where: 'parent_id = ?',
      whereArgs: [parentId],
    );
    const linkedEntityColumns = {
      'owners': 'account_id',
      'tenants': 'account_id',
      'banks': 'account_id',
      'users': 'cash_box_account_id',
    };
    for (final reference in linkedEntityColumns.entries) {
      if (allowDirectLegacyTenantLinks && reference.key == 'tenants') continue;
      final linkedRows = await executor.query(
        reference.key,
        columns: ['id'],
        where: '${reference.value} = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (linkedRows.isNotEmpty) {
        final linkedRecord = switch (reference.key) {
          'owners' => 'ملف مالك',
          'tenants' => 'ملف مستأجر قديم',
          'banks' => 'سجل بنك',
          'users' => 'حساب صندوق مستخدم',
          _ => 'سجل تشغيلي',
        };
        throw StateError(
          'لا يمكن إضافة حساب فرعي: الحساب $parentCode مرتبط مباشرةً بـ$linkedRecord. لم يتم تعديل أي بيانات؛ يلزم مراجعة الربط يدويًا.',
        );
      }
    }
    if (children.isEmpty) {
      final activity = await executor.query(
        'journal_lines',
        columns: ['id'],
        where: 'account_id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      final balance = (parent['balance'] as num?)?.toDouble() ?? 0.0;
      if (activity.isNotEmpty || !balance.isFinite || balance.abs() >= 0.005) {
        throw StateError('لا يمكن تحويل حساب له رصيد أو حركة إلى حساب تجميعي');
      }
    }

    final suffixLength = parent['parent_id'] == null ? 1 : 2;
    final maximumSequence = suffixLength == 1 ? 9 : 99;
    final allCodes = (await executor.query(
      'accounts',
      columns: ['code'],
    )).map((account) => account['code']?.toString() ?? '').toList();
    var sequence = 0;
    for (final child in children) {
      final childCode = child['code']?.toString() ?? '';
      if (!childCode.startsWith(parentCode) ||
          childCode.length <= parentCode.length) {
        continue;
      }
      final suffix = childCode.substring(parentCode.length);
      if (suffix.length > suffixLength) continue;
      final parsed = int.tryParse(suffix);
      if (parsed != null && parsed > sequence) sequence = parsed;
    }

    while (sequence < maximumSequence) {
      sequence++;
      final code =
          '$parentCode${sequence.toString().padLeft(suffixLength, '0')}';
      final isAmbiguousPrefix = allCodes.any(
        (existingCode) =>
            existingCode.length > code.length && existingCode.startsWith(code),
      );
      if (!allCodes.contains(code) && !isAmbiguousPrefix) return code;
    }
    throw StateError('اكتمل عدد الحسابات الفرعية المتاح لهذا الحساب');
  }

  /// Repairs only legacy tenant-to-control-account links that have no ledger
  /// activity and no balance. This is called within the new-tenant transaction
  /// so either all links and audit rows are committed or none are.
  Future<void> _repairUnusedLegacyTenantLinksTx(
    DatabaseExecutor txn,
    int parentId,
  ) async {
    final legacyTenants = await txn.query(
      'tenants',
      columns: ['id', 'name'],
      where: 'account_id = ?',
      whereArgs: [parentId],
      orderBy: 'id',
    );
    if (legacyTenants.isEmpty) return;

    final parentRows = await txn.query(
      'accounts',
      columns: ['code', 'balance'],
      where: 'id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    if (parentRows.isEmpty) throw StateError('الحساب الأعلى غير موجود');
    final parent = parentRows.first;
    final parentCode = parent['code']?.toString() ?? parentId.toString();

    const otherOperationalLinks = <String, (String, String)>{
      'owners': ('account_id', 'ملف مالك'),
      'banks': ('account_id', 'سجل بنك'),
      'users': ('cash_box_account_id', 'حساب صندوق مستخدم'),
    };
    for (final reference in otherOperationalLinks.entries) {
      final linkedRows = await txn.query(
        reference.key,
        columns: ['id'],
        where: '${reference.value.$1} = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (linkedRows.isNotEmpty) {
        throw StateError(
          'لا يمكن إضافة المستأجر: الحساب $parentCode مرتبط مباشرةً بـ${reference.value.$2}. لم يتم تعديل أي بيانات؛ يلزم مراجعة الربط يدويًا.',
        );
      }
    }

    final activity = await txn.query(
      'journal_lines',
      columns: ['id'],
      where: 'account_id = ?',
      whereArgs: [parentId],
      limit: 1,
    );
    final balance = (parent['balance'] as num?)?.toDouble() ?? 0.0;
    if (activity.isNotEmpty || !balance.isFinite || balance.abs() >= 0.005) {
      throw StateError(
        'لا يمكن إضافة المستأجر بأمان: الحساب $parentCode مرتبط بمستأجر قديم وله قيود أو رصيد. لم يتم تغيير الرابط أو أي حركة مالية؛ تلزم مراجعة محاسبية يدوية.',
      );
    }

    for (final tenant in legacyTenants) {
      final tenantId = (tenant['id'] as num).toInt();
      final tenantName = tenant['name']?.toString().trim() ?? '';
      final code = await _nextAccountCodeTx(
        txn,
        parentId,
        allowDirectLegacyTenantLinks: true,
      );
      final accountId = await txn.insert('accounts', {
        'code': code,
        'name': tenantName.isEmpty ? 'مستأجر قديم $tenantId' : tenantName,
        'parent_id': parentId,
        'account_type': 'Asset',
        'balance': 0.0,
      });
      final updated = await txn.update(
        'tenants',
        {'account_id': accountId},
        where: 'id = ? AND account_id = ?',
        whereArgs: [tenantId, parentId],
      );
      if (updated != 1) {
        throw StateError(
          'تعذر إصلاح ربط المستأجر القديم؛ أُلغيت العملية دون حفظ جزئي.',
        );
      }
      await _recordAuditTx(
        txn,
        action: 'LEGACY_TENANT_ACCOUNT_LINK_REPAIRED',
        entityType: 'tenant',
        entityId: tenantId,
        details: {
          'source_account_id': parentId,
          'source_account_code': parentCode,
          'destination_account_id': accountId,
          'destination_account_code': code,
          'reason': 'unused_legacy_control_account_link',
        },
      );
    }
  }

  Future<int> insertAccount(Map<String, dynamic> account) async {
    PermissionRuntime.require('accounting', AppPermissionAction.add);
    final name = (account['name'] as String?)?.trim() ?? '';
    final parentValue = account['parent_id'];
    if (name.isEmpty) throw ArgumentError('اسم الحساب مطلوب');
    if (parentValue != null && (parentValue is! int || parentValue <= 0)) {
      throw ArgumentError('الحساب الأعلى غير صالح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      late final String code;
      late final String accountType;
      if (parentValue == null) {
        accountType = account['account_type']?.toString() ?? '';
        final rootCode = _accountTypeRootCodes[accountType];
        if (rootCode == null)
          throw ArgumentError('نوع الحساب الرئيسي غير صالح');
        final existingType = await txn.query(
          'accounts',
          columns: ['id'],
          where: 'parent_id IS NULL AND account_type = ?',
          whereArgs: [accountType],
          limit: 1,
        );
        if (existingType.isNotEmpty) {
          throw StateError('يوجد حساب رئيسي لهذا النوع بالفعل');
        }
        code = rootCode;
      } else {
        final parentId = parentValue as int;
        final parentRows = await txn.query(
          'accounts',
          columns: ['id', 'account_type'],
          where: 'id = ?',
          whereArgs: [parentId],
          limit: 1,
        );
        if (parentRows.isEmpty) throw StateError('الحساب الأعلى غير موجود');
        accountType = parentRows.first['account_type']?.toString() ?? '';
        if (!_accountTypeRootCodes.containsKey(accountType)) {
          throw StateError('نوع الحساب الأعلى غير صالح');
        }
        final requestedType = account['account_type']?.toString();
        if (requestedType != null && requestedType != accountType) {
          throw ArgumentError('الحساب الفرعي يرث نوع الحساب الأعلى');
        }
        code = await _nextAccountCodeTx(txn, parentId);
      }

      final codeCollision = await txn.query(
        'accounts',
        columns: ['id'],
        where: 'code = ?',
        whereArgs: [code],
        limit: 1,
      );
      if (codeCollision.isNotEmpty)
        throw StateError('رمز الحساب مستخدم بالفعل');

      final id = await txn.insert('accounts', {
        'code': code,
        'name': name,
        'parent_id': parentValue,
        'account_type': accountType,
        'balance': 0.0,
      });
      await _recordAuditTx(
        txn,
        action: 'ACCOUNT_CREATE',
        entityType: 'account',
        entityId: id,
        details: {'code': code, 'name': name, 'account_type': accountType},
      );
      return id;
    });
  }

  Future<int> updateAccount(int accountId, String accountName) async {
    PermissionRuntime.require('accounting', AppPermissionAction.edit);
    final name = accountName.trim();
    if (accountId <= 0 || name.isEmpty) {
      throw ArgumentError('معرف الحساب والاسم حقول مطلوبة');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        columns: ['id', 'code', 'name'],
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الحساب غير موجود');
      final oldName = rows.first['name']?.toString() ?? '';
      final changed = await txn.update(
        'accounts',
        {'name': name},
        where: 'id = ?',
        whereArgs: [accountId],
      );
      if (changed != 1) throw StateError('تعذر تحديث الحساب');
      await _recordAuditTx(
        txn,
        action: 'ACCOUNT_RENAME',
        entityType: 'account',
        entityId: accountId,
        details: {
          'code': rows.first['code'],
          'old_name': oldName,
          'new_name': name,
        },
      );
      return changed;
    });
  }

  Future<int> deleteAccount(int accountId) async {
    PermissionRuntime.require('accounting', AppPermissionAction.delete);
    if (accountId <= 0) throw ArgumentError('معرف الحساب غير صالح');
    final db = await instance.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        columns: ['id', 'code', 'name', 'balance'],
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الحساب غير موجود');
      final account = rows.first;
      final code = account['code']?.toString() ?? '';
      final balance = (account['balance'] as num?)?.toDouble() ?? 0.0;
      if (_protectedSystemAccountCodes.contains(code)) {
        throw StateError('لا يمكن حذف حساب أساسي يستخدمه النظام');
      }
      if (!balance.isFinite || balance.abs() >= 0.005) {
        throw StateError('لا يمكن حذف حساب له رصيد');
      }

      const references = {
        'accounts': 'parent_id',
        'journal_lines': 'account_id',
        'owners': 'account_id',
        'tenants': 'account_id',
        'banks': 'account_id',
        'users': 'cash_box_account_id',
      };
      for (final entry in references.entries) {
        final linkedRows = await txn.query(
          entry.key,
          columns: ['id'],
          where: '${entry.value} = ?',
          whereArgs: [accountId],
          limit: 1,
        );
        if (linkedRows.isNotEmpty) {
          throw StateError('لا يمكن حذف حساب مرتبط بحركات أو بيانات أخرى');
        }
      }

      await _recordAuditTx(
        txn,
        action: 'ACCOUNT_DELETE',
        entityType: 'account',
        entityId: accountId,
        details: {'code': code, 'name': account['name']},
      );
      return txn.delete('accounts', where: 'id = ?', whereArgs: [accountId]);
    });
  }

  // Journal Entries with Transactions
  Future<int> insertJournalEntryWithLines(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> lines,
  ) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    final rawDate = header['entry_date']?.toString().trim() ?? '';
    final dateText = rawDate.length >= 10 ? rawDate.substring(0, 10) : '';
    final parsedDate = DateTime.tryParse(rawDate);
    final parsedDay = DateTime.tryParse(dateText);
    if (parsedDate == null ||
        parsedDay == null ||
        parsedDay.toIso8601String().substring(0, 10) != dateText ||
        (rawDate.length > 10 && rawDate[10] != 'T' && rawDate[10] != ' ')) {
      throw ArgumentError('تاريخ القيد غير صحيح');
    }
    final description = (header['description'] as String?)?.trim() ?? '';
    if (description.isEmpty) throw ArgumentError('بيان القيد مطلوب');
    if (lines.length < 2) {
      throw ArgumentError('يجب أن يحتوي القيد على سطرين على الأقل');
    }
    int debitCents = 0;
    int creditCents = 0;
    final validatedLines = <Map<String, dynamic>>[];
    for (final line in lines) {
      final accountId = line['account_id'];
      final debit = (line['debit'] as num? ?? 0).toDouble();
      final credit = (line['credit'] as num? ?? 0).toDouble();
      final costCenterId = line['cost_center_id'];
      if (accountId is! int || accountId <= 0) {
        throw ArgumentError('اختر حساباً صالحاً لكل سطر');
      }
      if (costCenterId != null && (costCenterId is! int || costCenterId <= 0)) {
        throw ArgumentError('مركز تكلفة أحد الأسطر غير صالح');
      }
      if (!_hasCentPrecision(debit) ||
          !_hasCentPrecision(credit) ||
          debit < 0 ||
          credit < 0 ||
          (debit > 0 && credit > 0) ||
          (debit == 0 && credit == 0)) {
        throw ArgumentError('قيمة أحد أسطر القيد غير صحيحة');
      }
      debitCents += (debit * 100).round();
      creditCents += (credit * 100).round();
      validatedLines.add({
        'account_id': accountId,
        'debit': debit,
        'credit': credit,
        'cost_center_id': costCenterId,
        'description': (line['description'] as String?)?.trim(),
      });
    }
    if (debitCents != creditCents || debitCents == 0) {
      throw ArgumentError(
        'القيد غير متوازن: يجب أن يتساوى إجمالي المدين والدائن',
      );
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      final journalId = await txn.insert('journal_entries', {
        'entry_date': dateText,
        'description': description,
        'is_posted': 1,
      });

      for (final line in validatedLines) {
        final accountId = line['account_id'] as int;
        await _requireLeafAccountTx(txn, accountId);
        await _requireCostCenterTx(txn, line['cost_center_id']);
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': accountId,
          'debit': line['debit'],
          'credit': line['credit'],
          'cost_center_id': line['cost_center_id'],
          'description': line['description'],
        });
        final debit = (line['debit'] as num? ?? 0).toDouble();
        final credit = (line['credit'] as num? ?? 0).toDouble();
        await _updateBalanceTx(txn, accountId, debit, credit);
      }
      await _recordAuditTx(
        txn,
        action: 'JOURNAL_ENTRY_POSTED',
        entityType: 'journal_entry',
        entityId: journalId,
        amountMinor: debitCents,
        details: {
          'entry_date': dateText,
          'description': description,
          'line_count': validatedLines.length,
          'debit_minor': debitCents,
          'credit_minor': creditCents,
          'is_posted': true,
        },
      );
      return journalId;
    });
  }

  // General Vouchers (Receipts/Payments) with Auto-Posting
  Future<int> insertGeneralVoucher(
    Map<String, dynamic> voucher,
    int cashAccountId,
    int oppositeAccountId,
    int? costCenterId,
    String voucherType,
  ) => insertGeneralVoucherWithLines(voucher, cashAccountId, [
    {
      'account_id': oppositeAccountId,
      'amount': voucher['amount'],
      'cost_center_id': costCenterId,
      'description': voucher['description'],
    },
  ], voucherType);

  Future<int> insertGeneralVoucherWithLines(
    Map<String, dynamic> voucher,
    int cashAccountId,
    List<Map<String, dynamic>> counterpartLines,
    String voucherType,
  ) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    if (voucherType != 'قبض عام' && voucherType != 'صرف عام') {
      throw ArgumentError('نوع السند غير معروف');
    }
    if (voucher['voucher_type'] != voucherType) {
      throw ArgumentError('نوع السند المخزن لا يطابق نوع الترحيل');
    }
    final amountValue = voucher['amount'];
    if (amountValue is! num ||
        amountValue <= 0 ||
        !_hasCentPrecision(amountValue) ||
        DateTime.tryParse(voucher['voucher_date']?.toString() ?? '') == null) {
      throw ArgumentError('مبلغ أو تاريخ السند غير صحيح');
    }
    if (counterpartLines.isEmpty) {
      throw ArgumentError('أضف حسابًا واحدًا على الأقل للسند');
    }
    var counterpartTotalCents = 0;
    final validatedLines = <Map<String, dynamic>>[];
    for (final line in counterpartLines) {
      final accountId = line['account_id'];
      final lineAmount = line['amount'];
      final rawCostCenterId = line['cost_center_id'];
      if (accountId is! int ||
          accountId <= 0 ||
          lineAmount is! num ||
          lineAmount <= 0 ||
          !_hasCentPrecision(lineAmount) ||
          (rawCostCenterId != null &&
              (rawCostCenterId is! int || rawCostCenterId <= 0))) {
        throw ArgumentError('تحقق من الحساب والمبلغ ومركز التكلفة لكل بند');
      }
      final lineDescription = (line['description'] as String?)?.trim() ?? '';
      if (lineDescription.isEmpty) {
        throw ArgumentError('البيان مطلوب لكل بند من بنود السند');
      }
      final cents = (lineAmount.toDouble() * 100).round();
      counterpartTotalCents += cents;
      validatedLines.add({
        'account_id': accountId,
        'amount': cents / 100.0,
        'amount_minor': cents,
        'cost_center_id': rawCostCenterId,
        'description': lineDescription,
      });
    }
    if (counterpartTotalCents !=
        InternalTax.toMinorUnits(amountValue.toDouble())) {
      throw ArgumentError('إجمالي البنود لا يساوي مبلغ السند');
    }
    String? optionalVoucherDate(String key) {
      final value = voucher[key];
      if (value == null) return null;
      if (value is! String) throw ArgumentError('تاريخ الفترة غير صحيح');
      final normalized = value.trim();
      return normalized.isEmpty ? null : normalized;
    }

    final periodFromDate = optionalVoucherDate('period_from_date');
    final periodToDate = optionalVoucherDate('period_to_date');
    if ((periodFromDate == null) != (periodToDate == null)) {
      throw ArgumentError('يجب إدخال تاريخي بداية ونهاية الفترة معاً');
    }
    if (periodFromDate != null && periodToDate != null) {
      final from = DateTime.tryParse(periodFromDate);
      final to = DateTime.tryParse(periodToDate);
      if (from == null || to == null || from.isAfter(to)) {
        throw ArgumentError('تاريخ الفترة غير صحيح؛ راجع البداية والنهاية');
      }
    }
    voucher['period_from_date'] = periodFromDate;
    voucher['period_to_date'] = periodToDate;
    final db = await instance.database;
    return db.transaction((txn) async {
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('حساب النقدية يجب أن يكون صندوقاً أو بنكاً');
      }
      final allowedCounterpartTypes = voucherType == 'قبض عام'
          ? ['Asset', 'Liability', 'Equity', 'Revenue']
          : ['Asset', 'Liability', 'Equity', 'Expense'];
      for (final line in validatedLines) {
        final accountId = line['account_id'] as int;
        final counterpart = await _requireLeafAccountTx(txn, accountId);
        if (accountId == cashAccountId ||
            !allowedCounterpartTypes.contains(counterpart['account_type'])) {
          throw ArgumentError('أحد الحسابات المقابلة غير صالح');
        }
        if (voucherType == 'صرف عام') {
          final linkedOwners = await txn.query(
            'owners',
            columns: ['id'],
            where: 'account_id = ?',
            whereArgs: [accountId],
            limit: 1,
          );
          if (linkedOwners.isNotEmpty) {
            throw StateError(
              'سداد حساب المالك يتم من تبويب «سداد مستحقات المالك» لضبط الرصيد والربط المحاسبي',
            );
          }
        }
        await _requireCostCenterTx(txn, line['cost_center_id']);
      }
      final amount = (voucher['amount'] as num).toDouble();
      final date = voucher['voucher_date'];
      final description =
          (voucher['description'] as String?)?.trim().isNotEmpty == true
          ? (voucher['description'] as String).trim()
          : 'سند $voucherType';
      final partyName = (voucher['party_name'] as String?)?.trim();
      voucher['party_name'] = partyName?.isNotEmpty == true
          ? partyName
          : description;

      // 1. Insert Journal Entry Header
      final journalHeader = {
        'entry_date': date,
        'description': description,
        'is_posted': 1,
      };
      final journalId = await txn.insert('journal_entries', journalHeader);

      // 2. Insert the cash control line and each separately described account.
      final isReceipt = voucherType == 'قبض عام';
      final cashLine = <String, dynamic>{
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': isReceipt ? amount : 0.0,
        'credit': isReceipt ? 0.0 : amount,
        'description': description,
      };
      await txn.insert('journal_lines', cashLine);
      await _updateBalanceTx(
        txn,
        cashAccountId,
        cashLine['debit'],
        cashLine['credit'],
      );
      for (final counterpart in validatedLines) {
        final counterpartLine = <String, dynamic>{
          'journal_entry_id': journalId,
          'account_id': counterpart['account_id'],
          'debit': isReceipt ? 0.0 : counterpart['amount'],
          'credit': isReceipt ? counterpart['amount'] : 0.0,
          'cost_center_id': counterpart['cost_center_id'],
          'description': counterpart['description'],
        };
        await txn.insert('journal_lines', counterpartLine);
        await _updateBalanceTx(
          txn,
          counterpartLine['account_id'],
          counterpartLine['debit'],
          counterpartLine['credit'],
        );
      }

      // 3. Insert Voucher
      voucher['journal_entry_id'] = journalId;
      final voucherId = await txn.insert('vouchers', voucher);
      await _recordAuditTx(
        txn,
        action: 'GENERAL_VOUCHER_POSTED',
        entityType: 'voucher',
        entityId: voucherId,
        amountMinor: InternalTax.toMinorUnits(amount),
        details: {
          'voucher_type': voucherType,
          'voucher_date': date,
          'journal_entry_id': journalId,
          'cash_account_id': cashAccountId,
          'counterpart_lines': validatedLines,
          'line_count': validatedLines.length,
        },
      );
      return voucherId;
    });
  }

  Future<Map<String, dynamic>> _requireOwnerSettlementOwnerTx(
    DatabaseExecutor executor,
    int ownerId,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT o.id AS owner_id, o.name AS owner_name, o.account_id,
             a.code AS owner_account_code, a.name AS owner_account_name,
             a.parent_id, parent.code AS parent_code
      FROM owners o
      LEFT JOIN accounts a ON a.id = o.account_id
      LEFT JOIN accounts parent ON parent.id = a.parent_id
      WHERE o.id = ?
      LIMIT 1
      ''',
      [ownerId],
    );
    if (rows.isEmpty) throw StateError('المالك المحدد غير موجود');
    final owner = rows.first;
    final accountId = (owner['account_id'] as num?)?.toInt();
    if (accountId == null || owner['parent_code'] != '2101') {
      throw StateError('المالك لا يملك حساب التزامات صالحًا تحت الحساب 2101');
    }
    final linkedOwners = await executor.query(
      'owners',
      columns: ['id'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
    if (linkedOwners.length != 1 ||
        (linkedOwners.single['id'] as num).toInt() != ownerId) {
      throw StateError('حساب المالك مرتبط بأكثر من مالك؛ أوقف السداد للمراجعة');
    }
    await _requireLeafAccountTx(executor, accountId, expectedType: 'Liability');
    return owner;
  }

  Future<int> _postedAccountBalanceMinorTx(
    DatabaseExecutor executor,
    int accountId, {
    required bool creditNormal,
    String? throughDate,
  }) async {
    final rows = await executor.rawQuery(
      '''
      SELECT
        je.id AS journal_entry_id,
        je.entry_date,
        COUNT(jl.id) AS line_count,
        SUM(CAST(ROUND(COALESCE(jl.debit, 0) * 100) AS INTEGER))
          AS journal_debit_minor,
        SUM(CAST(ROUND(COALESCE(jl.credit, 0) * 100) AS INTEGER))
          AS journal_credit_minor,
        MAX(CASE WHEN COALESCE(jl.debit, 0) < 0
          OR COALESCE(jl.credit, 0) < 0
          OR (COALESCE(jl.debit, 0) > 0 AND COALESCE(jl.credit, 0) > 0)
          OR (COALESCE(jl.debit, 0) = 0 AND COALESCE(jl.credit, 0) = 0)
          OR ABS(COALESCE(jl.debit, 0) * 100 - ROUND(COALESCE(jl.debit, 0) * 100)) > 0.000001
          OR ABS(COALESCE(jl.credit, 0) * 100 - ROUND(COALESCE(jl.credit, 0) * 100)) > 0.000001
          THEN 1 ELSE 0 END) AS invalid_line,
        SUM(CASE WHEN jl.account_id = ?
          THEN CAST(ROUND(COALESCE(jl.debit, 0) * 100) AS INTEGER)
          ELSE 0 END) AS account_debit_minor,
        SUM(CASE WHEN jl.account_id = ?
          THEN CAST(ROUND(COALESCE(jl.credit, 0) * 100) AS INTEGER)
          ELSE 0 END) AS account_credit_minor
      FROM journal_entries je
      JOIN journal_lines jl ON jl.journal_entry_id = je.id
      WHERE je.is_posted = 1
        AND EXISTS (
          SELECT 1 FROM journal_lines focus
          WHERE focus.journal_entry_id = je.id AND focus.account_id = ?
        )
      GROUP BY je.id, je.entry_date
      ORDER BY je.entry_date, je.id
      ''',
      [accountId, accountId, accountId],
    );
    var balanceMinor = 0;
    for (final row in rows) {
      final lineCount = (row['line_count'] as num?)?.toInt() ?? 0;
      final debitMinor = (row['journal_debit_minor'] as num?)?.toInt() ?? 0;
      final creditMinor = (row['journal_credit_minor'] as num?)?.toInt() ?? 0;
      final invalidLine = (row['invalid_line'] as num?)?.toInt() == 1;
      final dateValue = row['entry_date']?.toString() ?? '';
      final parsedDate = DateTime.tryParse(dateValue);
      final dateOnly = dateValue.length >= 10 ? dateValue.substring(0, 10) : '';
      if (lineCount < 2 ||
          debitMinor <= 0 ||
          debitMinor != creditMinor ||
          invalidLine ||
          parsedDate == null ||
          parsedDate.toIso8601String().substring(0, 10) != dateOnly) {
        throw StateError(
          'يوجد قيد مرحّل غير سليم على الحساب؛ أوقف السداد حتى تتم مراجعته',
        );
      }
      if (throughDate != null && dateOnly.compareTo(throughDate) > 0) {
        continue;
      }
      final accountDebit = (row['account_debit_minor'] as num?)?.toInt() ?? 0;
      final accountCredit = (row['account_credit_minor'] as num?)?.toInt() ?? 0;
      balanceMinor += creditNormal
          ? accountCredit - accountDebit
          : accountDebit - accountCredit;
    }
    return balanceMinor;
  }

  Future<List<Map<String, dynamic>>> getOwnerSettlementOwners() async {
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT o.id, o.name, o.account_id,
             a.code AS owner_account_code, a.name AS owner_account_name
      FROM owners o
      JOIN accounts a ON a.id = o.account_id
      JOIN accounts parent ON parent.id = a.parent_id
      WHERE a.account_type = 'Liability'
        AND parent.code = '2101'
        AND NOT EXISTS (SELECT 1 FROM accounts child WHERE child.parent_id = a.id)
        AND (SELECT COUNT(*) FROM owners linked WHERE linked.account_id = a.id) = 1
      ORDER BY o.name COLLATE NOCASE, o.id
    ''');
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    return rows;
  }

  Future<List<Map<String, dynamic>>> getOwnerSettlementCashAccounts() async {
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT id, code, name
      FROM accounts
      WHERE account_type = 'Asset'
        AND code LIKE '11%'
        AND parent_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM accounts child WHERE child.parent_id = accounts.id)
      ORDER BY code, id
    ''');
    final validRows = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final account = await _requireOwnerSettlementCashAccountTx(
          db,
          (row['id'] as num).toInt(),
        );
        validRows.add({
          'id': account['id'],
          'code': account['code'],
          'name': account['name'],
        });
      } on ArgumentError {
        continue;
      } on StateError {
        continue;
      }
    }
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    return validRows;
  }

  Future<int> getOwnerSettlementBalanceMinor(int ownerId) async {
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    final db = await instance.database;
    final owner = await _requireOwnerSettlementOwnerTx(db, ownerId);
    final accountId = (owner['account_id'] as num).toInt();
    final balance = await _postedAccountBalanceMinorTx(
      db,
      accountId,
      creditNormal: true,
    );
    PermissionRuntime.require('accounting', AppPermissionAction.view);
    return balance;
  }

  Future<Map<String, dynamic>> _requireOwnerSettlementCashAccountTx(
    DatabaseExecutor executor,
    int cashAccountId,
  ) async {
    var account = await _requireLeafAccountTx(
      executor,
      cashAccountId,
      expectedType: 'Asset',
    );
    var parentId = account['parent_id'] as int?;
    var foundCashRoot = account['code']?.toString() == '11';
    final visited = <int>{cashAccountId};
    while (parentId != null) {
      if (!visited.add(parentId)) {
        throw StateError('تسلسل حساب النقدية يحتوي دورة');
      }
      final parentRows = await executor.query(
        'accounts',
        columns: ['id', 'code', 'parent_id', 'account_type'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (parentRows.isEmpty || parentRows.single['account_type'] != 'Asset') {
        throw StateError('تسلسل حساب النقدية غير صالح');
      }
      account = parentRows.single;
      foundCashRoot = foundCashRoot || account['code']?.toString() == '11';
      parentId = account['parent_id'] as int?;
    }
    if (!foundCashRoot) {
      throw ArgumentError('حساب الصندوق أو البنك يجب أن يقع تحت الأصل 11');
    }
    return await _requireLeafAccountTx(
      executor,
      cashAccountId,
      expectedType: 'Asset',
    );
  }

  Future<int> insertOwnerSettlementVoucher({
    required int ownerId,
    required int amountMinor,
    required String settlementDate,
    required int cashAccountId,
    required String description,
  }) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    final reason = description.trim();
    if (ownerId <= 0 || cashAccountId <= 0 || amountMinor <= 0) {
      throw ArgumentError('اختر المالك وحساب الصندوق وأدخل مبلغًا موجبًا');
    }
    if (reason.isEmpty || reason.length > 1000) {
      throw ArgumentError('بيان سند السداد مطلوب ولا يتجاوز 1000 حرف');
    }
    final date = settlementDate.trim();
    final parsedDate = DateTime.tryParse(date);
    if (date.length != 10 ||
        parsedDate == null ||
        parsedDate.toIso8601String().substring(0, 10) != date) {
      throw ArgumentError('تاريخ سند السداد غير صحيح');
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (parsedDate.isAfter(today)) {
      throw ArgumentError('لا يمكن ترحيل سند سداد بتاريخ مستقبلي');
    }
    final actorId = PermissionRuntime.userId;
    final actorRole = PermissionRuntime.role;
    if (actorId == null || actorId <= 0) {
      throw StateError('لا توجد جلسة مستخدم صالحة لترحيل السند');
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('accounting', AppPermissionAction.post);
      if (PermissionRuntime.userId != actorId ||
          PermissionRuntime.role != actorRole) {
        throw StateError('تغيرت الجلسة أثناء الترحيل؛ أُلغيت العملية');
      }
      final owner = await _requireOwnerSettlementOwnerTx(txn, ownerId);
      final ownerAccountId = (owner['account_id'] as num).toInt();
      final cashAccount = await _requireOwnerSettlementCashAccountTx(
        txn,
        cashAccountId,
      );
      final cashCode = cashAccount['code']?.toString() ?? '';
      if (!cashCode.startsWith('11') || cashAccountId == ownerAccountId) {
        throw ArgumentError('اختر حساب صندوق أو بنك تفصيليًا صالحًا');
      }

      final ownerBalanceNow = await _postedAccountBalanceMinorTx(
        txn,
        ownerAccountId,
        creditNormal: true,
      );
      final ownerBalanceAtDate = await _postedAccountBalanceMinorTx(
        txn,
        ownerAccountId,
        creditNormal: true,
        throughDate: date,
      );
      if (amountMinor > ownerBalanceNow || amountMinor > ownerBalanceAtDate) {
        throw StateError(
          'مبلغ السداد يتجاوز الرصيد الدائن المتاح للمالك في دفتر الأستاذ',
        );
      }

      final cashBalanceNow = await _postedAccountBalanceMinorTx(
        txn,
        cashAccountId,
        creditNormal: false,
      );
      final cashBalanceAtDate = await _postedAccountBalanceMinorTx(
        txn,
        cashAccountId,
        creditNormal: false,
        throughDate: date,
      );
      if (amountMinor > cashBalanceNow || amountMinor > cashBalanceAtDate) {
        throw StateError(
          'مبلغ السداد يتجاوز الرصيد المرحّل المتاح في حساب الصندوق أو البنك',
        );
      }

      final amount = amountMinor / 100.0;
      final ownerName = owner['owner_name']?.toString().trim() ?? '';
      if (ownerName.isEmpty) throw StateError('اسم المالك غير صالح');
      final journalId = await txn.insert('journal_entries', {
        'entry_date': date,
        'description': reason,
        'is_posted': 1,
      });
      await txn.insert('owner_settlement_journal_intents', {
        'journal_entry_id': journalId,
        'owner_id': ownerId,
        'owner_account_id': ownerAccountId,
        'amount_minor': amountMinor,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': ownerAccountId,
        'debit': amount,
        'credit': 0.0,
        'cost_center_id': null,
        'description': reason,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': 0.0,
        'credit': amount,
        'cost_center_id': null,
        'description': reason,
      });
      await _updateBalanceTx(txn, ownerAccountId, amount, 0.0);
      await _updateBalanceTx(txn, cashAccountId, 0.0, amount);

      final voucherId = await txn.insert('vouchers', {
        'voucher_type': 'صرف مستحقات مالك',
        'voucher_date': date,
        'amount': amount,
        'tenant_id': null,
        'party_name': ownerName,
        'journal_entry_id': journalId,
        'description': reason,
        'period_from_date': null,
        'period_to_date': null,
      });
      final settlementId = await txn.insert('owner_settlements', {
        'voucher_id': voucherId,
        'owner_id': ownerId,
        'owner_account_id': ownerAccountId,
        'cash_account_id': cashAccountId,
        'journal_entry_id': journalId,
        'amount_minor': amountMinor,
        'settlement_date': date,
        'owner_name_snapshot': ownerName,
        'description': reason,
        'created_by': actorId,
        'created_at': DateTime.now().toIso8601String(),
      });
      await _recordAuditTx(
        txn,
        action: 'OWNER_SETTLEMENT_POSTED',
        entityType: 'owner_settlement',
        entityId: settlementId,
        amountMinor: amountMinor,
        details: {
          'voucher_id': voucherId,
          'journal_entry_id': journalId,
          'owner_id': ownerId,
          'owner_account_id': ownerAccountId,
          'cash_account_id': cashAccountId,
          'settlement_date': date,
        },
      );
      PermissionRuntime.require('accounting', AppPermissionAction.post);
      if (PermissionRuntime.userId != actorId ||
          PermissionRuntime.role != actorRole) {
        throw StateError('تغيرت الجلسة أثناء الترحيل؛ أُلغيت العملية');
      }
      return voucherId;
    });
  }

  Future<void> _updateBalanceTx(
    Transaction txn,
    int accountId,
    double debit,
    double credit,
  ) async {
    if (!_hasCentPrecision(debit) ||
        !_hasCentPrecision(credit) ||
        debit < 0 ||
        credit < 0 ||
        (debit > 0 && credit > 0)) {
      throw ArgumentError('قيمة حركة الحساب غير صحيحة');
    }
    final debitCents = (debit * 100).round();
    final creditCents = (credit * 100).round();
    int? currentAccountId = accountId;

    while (currentAccountId != null) {
      final accountResult = await txn.query(
        'accounts',
        where: 'id = ?',
        whereArgs: [currentAccountId],
      );
      if (accountResult.isEmpty) {
        throw StateError('تعذر تحديث رصيد حساب غير موجود');
      }
      final accountMap = accountResult.first;
      final accountType = accountMap['account_type']?.toString();
      final currentBalance = (accountMap['balance'] as num?)?.toDouble() ?? 0.0;
      if (!currentBalance.isFinite ||
          !_accountTypeRootCodes.containsKey(accountType)) {
        throw StateError('رصيد أو نوع الحساب غير صالح');
      }
      final currentCents = (currentBalance * 100).round();
      final deltaCents = accountType == 'Asset' || accountType == 'Expense'
          ? debitCents - creditCents
          : creditCents - debitCents;
      final nextBalance = (currentCents + deltaCents) / 100.0;
      await txn.update(
        'accounts',
        {'balance': nextBalance},
        where: 'id = ?',
        whereArgs: [currentAccountId],
      );
      currentAccountId = accountMap['parent_id'] as int?;
    }
  }

  Future<Map<String, dynamic>> _requireLeafAccountTx(
    DatabaseExecutor executor,
    int accountId, {
    String? expectedType,
  }) async {
    final rows = await executor.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['parent_id'] == null) {
      throw ArgumentError('اختر حساباً تفصيلياً صالحاً');
    }
    final account = rows.first;
    final accountType = account['account_type']?.toString();
    if (!_accountTypeRootCodes.containsKey(accountType) ||
        (expectedType != null && accountType != expectedType)) {
      throw ArgumentError('نوع الحساب لا يناسب هذه الحركة');
    }
    final children = await executor.query(
      'accounts',
      columns: ['id'],
      where: 'parent_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (children.isNotEmpty)
      throw ArgumentError('لا يمكن الترحيل على حساب تجميعي');

    final visited = <int>{accountId};
    var parentId = account['parent_id'] as int?;
    while (parentId != null) {
      if (!visited.add(parentId)) throw StateError('تسلسل الحسابات يحتوي دورة');
      final parentRows = await executor.query(
        'accounts',
        columns: ['parent_id', 'account_type'],
        where: 'id = ?',
        whereArgs: [parentId],
        limit: 1,
      );
      if (parentRows.isEmpty ||
          parentRows.first['account_type'] != accountType) {
        throw StateError('نوع الحساب لا يطابق سلسلة الحسابات الأعلى');
      }
      parentId = parentRows.first['parent_id'] as int?;
    }
    return account;
  }

  Future<void> _requireCostCenterTx(
    DatabaseExecutor executor,
    Object? costCenterId,
  ) async {
    if (costCenterId == null) return;
    if (costCenterId is! int || costCenterId <= 0) {
      throw ArgumentError('مركز التكلفة غير صالح');
    }
    final rows = await executor.query(
      'cost_centers',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [costCenterId],
      limit: 1,
    );
    if (rows.isEmpty) throw ArgumentError('مركز التكلفة المحدد غير موجود');
  }

  /// Resolves the cost centre a leasing movement belongs to by following
  /// installment -> contract -> unit -> property.
  ///
  /// Returns null when the chain has no assigned cost centre. Callers must
  /// leave the journal line unattributed in that case rather than guess: a
  /// historical movement with no proven source stays unallocated.
  Future<int?> _installmentCostCenterTx(
    DatabaseExecutor executor,
    Object? installmentId,
  ) async {
    if (installmentId is! int || installmentId <= 0) return null;
    final rows = await executor.rawQuery(
      '''
      SELECT p.cost_center_id AS cost_center_id
      FROM contract_installments ci
      JOIN contracts c ON c.id = ci.contract_id
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE ci.id = ?
      LIMIT 1
      ''',
      [installmentId],
    );
    return rows.isEmpty
        ? null
        : (rows.first['cost_center_id'] as num?)?.toInt();
  }

  /// Same resolution as [_installmentCostCenterTx] but starting from a
  /// contract, used when the movement is recorded per contract, not per
  /// installment.
  Future<int?> _contractCostCenterTx(
    DatabaseExecutor executor,
    Object? contractId,
  ) async {
    if (contractId is! int || contractId <= 0) return null;
    final rows = await executor.rawQuery(
      '''
      SELECT p.cost_center_id AS cost_center_id
      FROM contracts c
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE c.id = ?
      LIMIT 1
      ''',
      [contractId],
    );
    return rows.isEmpty
        ? null
        : (rows.first['cost_center_id'] as num?)?.toInt();
  }

  /// Merges per-source amounts into one bucket per cost centre, keeping the
  /// total exact to the cent. A null centre forms its own bucket so that
  /// unattributed sources are never folded into a property's centre.
  List<Map<String, Object?>> _groupMinorByCostCenter(
    List<({int? costCenterId, int amountMinor})> parts,
  ) {
    final totals = <int?, int>{};
    for (final part in parts) {
      totals[part.costCenterId] =
          (totals[part.costCenterId] ?? 0) + part.amountMinor;
    }
    final totalMinor = totals.values.fold<int>(0, (sum, value) => sum + value);
    final sourceMinor = parts.fold<int>(
      0,
      (sum, part) => sum + part.amountMinor,
    );
    if (totalMinor != sourceMinor) {
      throw StateError('تعذر توزيع المبلغ على مراكز التكلفة دون فقدان قروش');
    }
    return totals.entries
        .where((entry) => entry.value != 0)
        .map(
          (entry) => <String, Object?>{
            'cost_center_id': entry.key,
            'amount_minor': entry.value,
          },
        )
        .toList();
  }

  // --- Owner & Property Operations ---

  Future<void> _requireOptionalLookup(
    DatabaseExecutor executor,
    String table,
    Object? id,
    String label,
  ) async {
    if (id == null) return;
    if (id is! int || id <= 0) throw ArgumentError('$label غير صالح');
    final rows = await executor.query(
      table,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw ArgumentError('$label المحدد غير موجود');
  }

  Future<void> insertOwnerWithAccount(Map<String, dynamic> owner) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final name = (owner['name'] as String?)?.trim() ?? '';
    final commission = (owner['commission_rate'] as num?)?.toDouble() ?? 0;
    if (name.isEmpty) throw ArgumentError('اسم المالك مطلوب');
    if (!commission.isFinite || commission < 0 || commission > 100) {
      throw ArgumentError('نسبة العمولة يجب أن تكون بين صفر و100');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      // 1. Find the parent account for Owners (code: '2101')
      final parentResult = await txn.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['2101'],
      );
      if (parentResult.isEmpty)
        throw Exception('حساب الملاك الرئيسي غير موجود (2101)');

      final parentId = parentResult.first['id'] as int;
      final newCode = await _nextAccountCodeTx(txn, parentId);

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': name,
        'parent_id': parentId,
        'account_type': 'Liability', // Since '2101' is a liability
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Owner linked to the new account
      final ownerValues = Map<String, dynamic>.from(owner)
        ..remove('id')
        ..remove('account_id')
        ..['name'] = name
        ..['commission_rate'] = commission
        ..['account_id'] = accountId;
      await txn.insert('owners', ownerValues);
    });
  }

  Future<List<Map<String, dynamic>>> getAllOwners() async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('owners');
  }

  Future<void> updateOwner(Map<String, dynamic> owner) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final ownerId = owner['id'];
    final name = (owner['name'] as String?)?.trim() ?? '';
    final commission = (owner['commission_rate'] as num?)?.toDouble() ?? 0;
    if (ownerId is! int || ownerId <= 0 || name.isEmpty) {
      throw ArgumentError('معرف المالك والاسم حقول مطلوبة');
    }
    if (!commission.isFinite || commission < 0 || commission > 100) {
      throw ArgumentError('نسبة العمولة يجب أن تكون بين صفر و100');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'owners',
        columns: ['id', 'account_id'],
        where: 'id = ?',
        whereArgs: [ownerId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('المالك المطلوب غير موجود');

      final changed = await txn.update(
        'owners',
        {
          'name': name,
          'identity_number': owner['identity_number'],
          'identity_issue_date': owner['identity_issue_date'],
          'identity_source': owner['identity_source'],
          'profession': owner['profession'],
          'mobile': owner['mobile'],
          'iban': owner['iban'],
          'commission_rate': commission,
        },
        where: 'id = ?',
        whereArgs: [ownerId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات المالك');

      final accountId = existing.first['account_id'] as int?;
      if (accountId != null) {
        final changedAccount = await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
        if (changedAccount != 1) {
          throw StateError('الحساب المحاسبي المرتبط بالمالك غير موجود');
        }
      }
    });
  }

  Future<int> insertProperty(Map<String, dynamic> property) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final name = (property['name'] as String?)?.trim() ?? '';
    final ownerId = property['owner_id'];
    if (name.isEmpty || ownerId is! int || ownerId <= 0) {
      throw ArgumentError('اسم العقار والمالك حقول مطلوبة');
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      await _requireOptionalLookup(txn, 'owners', ownerId, 'مالك العقار');
      await _requireOptionalLookup(
        txn,
        'cities',
        property['city_id'],
        'المدينة',
      );
      await _requireOptionalLookup(
        txn,
        'property_types',
        property['property_type_id'],
        'نوع العقار',
      );
      await _requireOptionalLookup(
        txn,
        'cost_centers',
        property['cost_center_id'],
        'مركز التكلفة',
      );
      final values = Map<String, dynamic>.from(property)
        ..remove('id')
        ..['name'] = name;
      return txn.insert('properties', values);
    });
  }

  Future<void> updateProperty(Map<String, dynamic> property) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final propertyId = property['id'];
    final name = (property['name'] as String?)?.trim() ?? '';
    final ownerId = property['owner_id'];
    if (propertyId is! int ||
        propertyId <= 0 ||
        name.isEmpty ||
        ownerId is! int) {
      throw ArgumentError('معرف العقار والاسم والمالك حقول مطلوبة');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(txn, 'owners', ownerId, 'مالك العقار');
      await _requireOptionalLookup(
        txn,
        'cities',
        property['city_id'],
        'المدينة',
      );
      await _requireOptionalLookup(
        txn,
        'property_types',
        property['property_type_id'],
        'نوع العقار',
      );
      await _requireOptionalLookup(
        txn,
        'cost_centers',
        property['cost_center_id'],
        'مركز التكلفة',
      );
      final existing = await txn.query(
        'properties',
        columns: ['id', 'owner_id'],
        where: 'id = ?',
        whereArgs: [propertyId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('العقار المطلوب غير موجود');
      final previousOwnerId = existing.first['owner_id'] as int;
      if (previousOwnerId != ownerId) {
        throw StateError(
          'لا تغيّر ملكية العقار من شاشة التعديل؛ استخدم مسار مراجعة البيع وإتمامه لحفظ تاريخ الملكية والدفاتر.',
        );
      }
      final changed = await txn.update(
        'properties',
        {
          'name': name,
          'owner_id': ownerId,
          'city_id': property['city_id'],
          'property_type_id': property['property_type_id'],
          'cost_center_id': property['cost_center_id'],
          'address': property['address'],
          'deed_number': property['deed_number'],
        },
        where: 'id = ?',
        whereArgs: [propertyId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات العقار');
    });
  }

  Future<List<Map<String, dynamic>>> getProperties() async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    // Basic join could be done here, but let's fetch plain properties for now
    return await db.query('properties');
  }

  Future<List<Map<String, dynamic>>> getPropertiesForLeasing() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return db.query(
      'properties',
      columns: ['id', 'name'],
      orderBy: 'name COLLATE NOCASE, id',
    );
  }

  Future<int> insertUnit(Map<String, dynamic> unit) async {
    PermissionRuntime.require('properties', AppPermissionAction.add);
    final db = await instance.database;
    final propertyId = unit['property_id'];
    final number = (unit['unit_number'] as String?)?.trim() ?? '';
    final rent = unit['default_rent'] as num?;
    final rentPeriod = unit['default_rent_period'];
    if (propertyId is! int || propertyId <= 0 || number.isEmpty) {
      throw ArgumentError('العقار ورقم الوحدة حقول مطلوبة');
    }
    if (!RentPeriod.isValid(rentPeriod)) {
      throw ArgumentError('حدد دورية الإيجار الشهري أو السنوي');
    }
    if (rent != null &&
        (!rent.toDouble().isFinite ||
            rent < 0 ||
            !_hasCentPrecision(rent.toDouble()))) {
      throw ArgumentError(
        'الإيجار الافتراضي يجب أن يكون غير سالب وبمنزلتين عشريتين',
      );
    }

    return db.transaction((txn) async {
      final property = await txn.query(
        'properties',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [propertyId],
        limit: 1,
      );
      if (property.isEmpty) throw StateError('العقار المطلوب غير موجود');
      await _requireOptionalLookup(
        txn,
        'unit_types',
        unit['unit_type_id'],
        'نوع الوحدة',
      );
      final duplicate = await txn.query(
        'units',
        columns: ['id'],
        where: 'property_id = ? AND lower(trim(unit_number)) = lower(trim(?))',
        whereArgs: [propertyId, number],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw StateError('رقم الوحدة مستخدم في هذا العقار مسبقًا');
      }
      return txn.insert('units', {
        ...unit,
        'unit_number': number,
        'default_rent': rent?.toDouble(),
        'default_rent_period': rentPeriod,
      });
    });
  }

  Future<List<Map<String, dynamic>>> getUnitsForProperty(int propertyId) async {
    PermissionRuntime.require('properties', AppPermissionAction.view);
    final db = await instance.database;
    return await db.rawQuery(
      '''
      SELECT u.*,
             CASE WHEN EXISTS (
               SELECT 1 FROM units duplicate
               WHERE duplicate.property_id = u.property_id
                 AND lower(trim(duplicate.unit_number)) =
                     lower(trim(u.unit_number))
                 AND duplicate.id != u.id
             ) THEN 1 ELSE 0 END AS has_duplicate_number
      FROM units u
      WHERE u.property_id = ?
      ORDER BY u.unit_number COLLATE NOCASE, u.id
      ''',
      [propertyId],
    );
  }

  Future<void> updateUnit(Map<String, dynamic> unit) async {
    PermissionRuntime.require('properties', AppPermissionAction.edit);
    final db = await instance.database;
    final unitId = unit['id'];
    final number = (unit['unit_number'] as String?)?.trim() ?? '';
    final rent = unit['default_rent'] as num?;
    final rentPeriod = unit['default_rent_period'];
    if (unitId is! int || unitId <= 0 || number.isEmpty) {
      throw ArgumentError('معرف الوحدة ورقمها حقول مطلوبة');
    }
    if (!RentPeriod.isValid(rentPeriod)) {
      throw ArgumentError('حدد دورية الإيجار الشهري أو السنوي');
    }
    if (rent != null &&
        (!rent.toDouble().isFinite ||
            rent < 0 ||
            !_hasCentPrecision(rent.toDouble()))) {
      throw ArgumentError(
        'الإيجار الافتراضي يجب أن يكون غير سالب وبمنزلتين عشريتين',
      );
    }

    await db.transaction((txn) async {
      final existing = await txn.query(
        'units',
        columns: ['id', 'property_id', 'unit_number'],
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('الوحدة المطلوبة غير موجودة');
      await _requireOptionalLookup(
        txn,
        'unit_types',
        unit['unit_type_id'],
        'نوع الوحدة',
      );
      final previousNumber =
          existing.first['unit_number']?.toString().trim().toLowerCase() ?? '';
      if (previousNumber != number.toLowerCase()) {
        final duplicate = await txn.query(
          'units',
          columns: ['id'],
          where:
              'property_id = ? AND lower(trim(unit_number)) = lower(trim(?)) AND id != ?',
          whereArgs: [existing.first['property_id'], number, unitId],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw StateError('رقم الوحدة مستخدم في هذا العقار مسبقًا');
        }
      }
      final changed = await txn.update(
        'units',
        {
          'unit_number': number,
          'unit_type_id': unit['unit_type_id'],
          'floor': unit['floor'],
          'elec_meter': unit['elec_meter'],
          'water_meter': unit['water_meter'],
          'default_rent': rent?.toDouble(),
          'default_rent_period': rentPeriod,
        },
        where: 'id = ?',
        whereArgs: [unitId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات الوحدة');
    });
  }

  Future<void> deleteUnit(int id) async {
    PermissionRuntime.require('properties', AppPermissionAction.delete);
    final db = await instance.database;
    if (id <= 0) throw ArgumentError('معرف الوحدة غير صالح');
    await db.transaction((txn) async {
      final units = await txn.query(
        'units',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (units.isEmpty) throw StateError('الوحدة المطلوبة غير موجودة');
      final history = await txn.query(
        'contracts',
        columns: ['id'],
        where: 'unit_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (history.isNotEmpty) {
        throw StateError(
          'لا يمكن حذف وحدة مرتبطة بعقد؛ غيّر حالتها أو أرشفها للحفاظ على السجل التاريخي.',
        );
      }
      final deleted = await txn.delete(
        'units',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (deleted != 1) throw StateError('تعذر حذف الوحدة');
    });
  }

  // --- Leasing & Tenants Operations ---

  Future<void> insertTenantWithAccount(Map<String, dynamic> tenant) async {
    PermissionRuntime.require('leasing', AppPermissionAction.add);
    final name = (tenant['name'] as String?)?.trim() ?? '';
    final mobile = (tenant['mobile'] as String?)?.trim() ?? '';
    if (name.isEmpty || mobile.isEmpty) {
      throw ArgumentError('اسم المستأجر ورقم الجوال حقول مطلوبة');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(
        txn,
        'nationalities',
        tenant['nationality_id'],
        'الجنسية',
      );
      // 1. Find the parent account for Tenants (code: '1201')
      final parentResult = await txn.query(
        'accounts',
        where: 'code = ?',
        whereArgs: ['1201'],
      );
      if (parentResult.isEmpty)
        throw Exception('حساب ذمم المستأجرين غير موجود (1201)');

      final parentId = parentResult.first['id'] as int;
      await _repairUnusedLegacyTenantLinksTx(txn, parentId);
      final newCode = await _nextAccountCodeTx(txn, parentId);

      // 3. Create the sub-account
      final newAccount = {
        'code': newCode,
        'name': name,
        'parent_id': parentId,
        'account_type': 'Asset', // Since '1201' is an asset
        'balance': 0.0,
      };

      final accountId = await txn.insert('accounts', newAccount);

      // 4. Insert Tenant linked to the new account
      final tenantValues = Map<String, dynamic>.from(tenant)
        ..remove('id')
        ..remove('account_id')
        ..['name'] = name
        ..['mobile'] = mobile
        ..['account_id'] = accountId;
      await txn.insert('tenants', tenantValues);
    });
  }

  Future<List<Map<String, dynamic>>> getAllTenants() async {
    final db = await instance.database;
    if (PermissionRuntime.allows('leasing', AppPermissionAction.view)) {
      return db.query('tenants');
    }
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    return db.query(
      'tenants',
      columns: ['id', 'name', 'mobile', 'account_id'],
      orderBy: 'name COLLATE NOCASE',
    );
  }

  Future<List<Map<String, dynamic>>> getTenantStatementAccounts() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT
        t.id,
        t.name,
        t.account_id,
        a.code AS account_code,
        a.name AS account_name,
        CASE WHEN a.id IS NOT NULL
          AND a.account_type = 'Asset'
          AND a.parent_id IS NOT NULL
          AND (SELECT COUNT(*) FROM tenants linked
               WHERE linked.account_id = a.id) = 1
          AND NOT EXISTS (
            SELECT 1 FROM accounts child WHERE child.parent_id = a.id
          )
          THEN 1 ELSE 0 END AS is_reportable
      FROM tenants t
      LEFT JOIN accounts a ON a.id = t.account_id
      ORDER BY t.name COLLATE NOCASE, t.id
    ''');
    PermissionRuntime.require('reports', AppPermissionAction.view);
    return rows;
  }

  Future<List<Map<String, dynamic>>> getOwnerStatementAccounts() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT
        o.id,
        o.name,
        o.account_id,
        a.code AS account_code,
        a.name AS account_name,
        CASE WHEN a.id IS NOT NULL
          AND a.account_type = 'Liability'
          AND a.parent_id IS NOT NULL
          AND (SELECT COUNT(*) FROM owners linked
               WHERE linked.account_id = a.id) = 1
          AND NOT EXISTS (
            SELECT 1 FROM accounts child WHERE child.parent_id = a.id
          )
          THEN 1 ELSE 0 END AS is_reportable
      FROM owners o
      LEFT JOIN accounts a ON a.id = o.account_id
      ORDER BY o.name COLLATE NOCASE, o.id
    ''');
    PermissionRuntime.require('reports', AppPermissionAction.view);
    return rows;
  }

  Future<void> updateTenant(Map<String, dynamic> tenant) async {
    PermissionRuntime.require('leasing', AppPermissionAction.edit);
    final tenantId = tenant['id'];
    final name = (tenant['name'] as String?)?.trim() ?? '';
    final mobile = (tenant['mobile'] as String?)?.trim() ?? '';
    if (tenantId is! int || tenantId <= 0 || name.isEmpty || mobile.isEmpty) {
      throw ArgumentError('معرف المستأجر والاسم والجوال حقول مطلوبة');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      await _requireOptionalLookup(
        txn,
        'nationalities',
        tenant['nationality_id'],
        'الجنسية',
      );
      final existing = await txn.query(
        'tenants',
        columns: ['id', 'account_id'],
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('المستأجر المطلوب غير موجود');

      final accountId = existing.first['account_id'] as int?;
      final values = <String, Object?>{
        'name': name,
        'mobile': mobile,
        'identity_number': tenant['identity_number'],
        'identity_issue_date': tenant['identity_issue_date'],
        'identity_source': tenant['identity_source'],
        'profession': tenant['profession'],
        'nationality_id': tenant['nationality_id'],
      };
      final changed = await txn.update(
        'tenants',
        values,
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (changed != 1) throw StateError('تعذر تحديث بيانات المستأجر');

      if (accountId != null) {
        final changedAccount = await txn.update(
          'accounts',
          {'name': name},
          where: 'id = ?',
          whereArgs: [accountId],
        );
        if (changedAccount != 1) {
          throw StateError('الحساب المحاسبي المرتبط بالمستأجر غير موجود');
        }
      }
    });
  }

  Future<Map<String, dynamic>> _captureContractPartySnapshot(
    DatabaseExecutor txn,
    Map<String, dynamic> tenant,
    Map<String, dynamic> unit,
  ) async {
    final propertyRows = await txn.query(
      'properties',
      where: 'id = ?',
      whereArgs: [unit['property_id']],
      limit: 1,
    );
    if (propertyRows.isEmpty)
      throw StateError('العقار المرتبط بالوحدة غير موجود');
    final property = propertyRows.first;
    final effectiveOwnerId = unit['owner_id'] ?? property['owner_id'];
    if (effectiveOwnerId is! int || effectiveOwnerId <= 0) {
      throw StateError('مالك الوحدة الفعلي غير صالح');
    }
    final ownerRows = await txn.query(
      'owners',
      where: 'id = ?',
      whereArgs: [effectiveOwnerId],
      limit: 1,
    );
    if (ownerRows.isEmpty) throw StateError('مالك العقار المرتبط غير موجود');
    final owner = ownerRows.first;

    Future<String?> lookupName(String table, Object? id) async {
      if (id == null) return null;
      final rows = await txn.query(
        table,
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first['name']?.toString();
    }

    final tenantSnapshot = <String, dynamic>{
      for (final field in [
        'name',
        'identity_number',
        'identity_issue_date',
        'identity_source',
        'profession',
        'mobile',
      ])
        field: tenant[field],
      'nationality_name': await lookupName(
        'nationalities',
        tenant['nationality_id'],
      ),
    };

    return {
      'owner': {
        'owner_id': effectiveOwnerId,
        'account_id': owner['account_id'],
        for (final field in [
          'name',
          'identity_number',
          'identity_issue_date',
          'identity_source',
        ])
          field: owner[field],
      },
      'tenant': tenantSnapshot,
      'property': {'name': property['name'], 'address': property['address']},
      'unit': {'unit_number': unit['unit_number']},
      'city_name': await lookupName('cities', property['city_id']),
      'unit_type_name': await lookupName('unit_types', unit['unit_type_id']),
      'property_type_name': await lookupName(
        'property_types',
        property['property_type_id'],
      ),
    };
  }

  void _validateContractAndInstallments(
    Map<String, dynamic> contract,
    List<Map<String, dynamic>> installments,
  ) {
    final rent = (contract['rent_amount'] as num?)?.toDouble() ?? 0;
    final startDate = DateTime.tryParse(
      contract['start_date']?.toString() ?? '',
    );
    final endDate = DateTime.tryParse(contract['end_date']?.toString() ?? '');
    if (rent <= 0 ||
        !_hasCentPrecision(rent) ||
        startDate == null ||
        endDate == null ||
        ContractTerm.wholeMonths(startDate, endDate) == null) {
      throw ArgumentError(
        'بيانات العقد غير صحيحة؛ المدة يجب أن تكون شهرًا أو عددًا صحيحًا من الشهور دون أيام جزئية',
      );
    }
    if (installments.isEmpty) {
      throw ArgumentError('يجب إضافة قسط واحد على الأقل');
    }

    var installmentCents = 0;
    for (final installment in installments) {
      final amount = (installment['amount'] as num?)?.toDouble() ?? 0;
      final dueDate = DateTime.tryParse(
        installment['due_date']?.toString() ?? '',
      );
      if (amount <= 0 ||
          !_hasCentPrecision(amount) ||
          dueDate == null ||
          dueDate.isBefore(startDate) ||
          dueDate.isAfter(endDate)) {
        throw ArgumentError(
          'مبلغ أو تاريخ أحد الأقساط غير صحيح أو خارج مدة العقد',
        );
      }
      installmentCents += (amount * 100).round();
    }
    if (installmentCents != (rent * 100).round()) {
      throw ArgumentError('مجموع الأقساط لا يساوي قيمة العقد');
    }
  }

  Future<int> insertContractWithInstallments(
    Map<String, dynamic> contract,
    List<Map<String, dynamic>> installments, {
    int? renewedFromContractId,
  }) async {
    PermissionRuntime.require('leasing', AppPermissionAction.add);
    final rent = (contract['rent_amount'] as num?)?.toDouble() ?? 0;
    final startDate = DateTime.tryParse(
      contract['start_date']?.toString() ?? '',
    );
    _validateContractAndInstallments(contract, installments);
    final validatedStartDate = startDate!;

    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantId = contract['tenant_id'];
      final unitId = contract['unit_id'];
      if (tenantId is! int || tenantId <= 0) {
        throw ArgumentError('المستأجر المحدد غير موجود');
      }
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty) {
        throw ArgumentError('المستأجر المحدد غير موجود');
      }
      if (unitId is! int || unitId <= 0) {
        throw ArgumentError('الوحدة المحددة غير موجودة');
      }
      final unitRows = await txn.query(
        'units',
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      if (unitRows.isEmpty) throw ArgumentError('الوحدة المحددة غير موجودة');
      final expectedUnitStatus = renewedFromContractId == null
          ? 'شاغرة'
          : 'مؤجرة';
      if (unitRows.first['status'] != expectedUnitStatus) {
        throw StateError(
          renewedFromContractId == null
              ? 'الوحدة لم تعد شاغرة؛ حدّث القائمة واختر وحدة أخرى'
              : 'الوحدة لم تعد مرتبطة بعقد ساري؛ تعذر تجديده',
        );
      }
      final unitRentPeriod = unitRows.first['default_rent_period'];
      final unitRent = unitRows.first['default_rent'] as num?;
      if (!RentPeriod.isValid(unitRentPeriod)) {
        throw StateError(
          'دورية إيجار الوحدة غير محددة؛ حدّث بيانات الوحدة قبل إنشاء العقد',
        );
      }
      if (unitRent != null &&
          (!unitRent.toDouble().isFinite ||
              unitRent < 0 ||
              !_hasCentPrecision(unitRent.toDouble()))) {
        throw StateError(
          'سعر الوحدة الافتراضي غير صالح؛ حدّث بيانات الوحدة قبل إنشاء العقد',
        );
      }
      if (renewedFromContractId == null) {
        final activeContracts = await txn.query(
          'contracts',
          columns: ['id'],
          where: "unit_id = ? AND status = 'Active'",
          whereArgs: [unitId],
          limit: 1,
        );
        if (activeContracts.isNotEmpty) {
          throw StateError('للوحدة عقد نشط بالفعل');
        }
      } else {
        final previousRows = await txn.query(
          'contracts',
          where: "id = ? AND status = 'Active'",
          whereArgs: [renewedFromContractId],
          limit: 1,
        );
        if (previousRows.isEmpty) {
          throw StateError('العقد السابق غير موجود أو غير قابل للتجديد');
        }
        final previous = previousRows.first;
        if (previous['unit_id'] != unitId ||
            previous['tenant_id'] != tenantId) {
          throw StateError('يجب أن يحافظ التجديد على المستأجر والوحدة نفسيهما');
        }
        final previousEnd = DateTime.tryParse(
          previous['end_date']?.toString() ?? '',
        );
        if (previousEnd == null) {
          throw StateError('نهاية العقد السابق غير صالحة؛ يلزم تصحيحها يدويًا');
        }
        final expectedStart = DateTime(
          previousEnd.year,
          previousEnd.month,
          previousEnd.day,
        ).add(const Duration(days: 1));
        if (validatedStartDate.year != expectedStart.year ||
            validatedStartDate.month != expectedStart.month ||
            validatedStartDate.day != expectedStart.day) {
          throw StateError(
            'يبدأ عقد التجديد في اليوم التالي لنهاية العقد السابق',
          );
        }
        final existingSuccessor = await txn.query(
          'contracts',
          columns: ['id'],
          where: "renewed_from_contract_id = ? AND status != 'Cancelled'",
          whereArgs: [renewedFromContractId],
          limit: 1,
        );
        if (existingSuccessor.isNotEmpty) {
          throw StateError('سبق إنشاء عقد تجديد لهذا العقد');
        }
        final overlaps = await txn.rawQuery(
          '''
          SELECT id FROM contracts
          WHERE unit_id = ? AND status = 'Active' AND id != ?
            AND DATE(start_date) <= DATE(?)
            AND DATE(end_date) >= DATE(?)
          LIMIT 1
          ''',
          [
            unitId,
            renewedFromContractId,
            contract['end_date'],
            contract['start_date'],
          ],
        );
        if (overlaps.isNotEmpty) {
          throw StateError('توجد مدة عقد أخرى متداخلة لهذه الوحدة');
        }
      }

      final partySnapshot = await _captureContractPartySnapshot(
        txn,
        tenantRows.first,
        unitRows.first,
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['terms_conditions'],
        limit: 1,
      );
      final termsSnapshot = companyRows.isEmpty
          ? LeaseContractTerms.defaultText
          : companyRows.first['terms_conditions']?.toString() ??
                LeaseContractTerms.defaultText;

      final contractId = await txn.insert('contracts', {
        ...contract,
        'renewed_from_contract_id': renewedFromContractId,
        'unit_rent_amount': unitRent?.toDouble(),
        'unit_rent_period': unitRentPeriod,
        'party_snapshot': jsonEncode(partySnapshot),
        'terms_conditions_snapshot': termsSnapshot,
      });
      for (final item in installments) {
        final installment = Map<String, dynamic>.from(item)
          ..['contract_id'] = contractId;
        await txn.insert('contract_installments', installment);
      }
      if (renewedFromContractId == null) {
        final updated = await txn.update(
          'units',
          {'status': 'مؤجرة'},
          where: "id = ? AND status = 'شاغرة'",
          whereArgs: [unitId],
        );
        if (updated != 1) {
          throw StateError('تعذر اعتماد الوحدة؛ أُلغيت المعاملة');
        }
      }
      await _recordAuditTx(
        txn,
        action: renewedFromContractId == null
            ? 'CONTRACT_CREATED'
            : 'CONTRACT_RENEWED',
        entityType: 'contract',
        entityId: contractId,
        amountMinor: (rent * 100).round(),
        details: {
          'tenant_id': tenantId,
          'unit_id': unitId,
          'start_date': contract['start_date']?.toString(),
          'end_date': contract['end_date']?.toString(),
          'rent_amount_minor': (rent * 100).round(),
          'installment_count': installments.length,
          'renewed_from_contract_id': renewedFromContractId,
        },
      );
      return contractId;
    });
  }

  Future<List<Map<String, dynamic>>> getVacantUnits() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('units', where: 'status = ?', whereArgs: ['شاغرة']);
  }

  Future<List<Map<String, dynamic>>> getAllContracts() async {
    PermissionRuntime.require('leasing', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT c.*,
        (SELECT successor.id FROM contracts successor
          WHERE successor.renewed_from_contract_id = c.id
            AND successor.status != 'Cancelled'
          ORDER BY successor.id DESC LIMIT 1) AS renewed_to_contract_id
      FROM contracts c
      ORDER BY c.id DESC
    ''');
  }

  Future<List<Map<String, dynamic>>>
  getActiveTenantContractsForFinancial() async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.query(
      'contracts',
      columns: ['id', 'tenant_id', 'status'],
      where: "status = 'Active'",
    );
  }

  Future<List<Map<String, dynamic>>> getInstallmentsForContract(
    int contractId,
  ) async {
    if (!PermissionRuntime.allows('leasing', AppPermissionAction.view) &&
        !PermissionRuntime.allows(
          'tenant_financial',
          AppPermissionAction.view,
        )) {
      throw StateError('لا تملك صلاحية عرض بيانات أقساط التأجير');
    }
    final db = await instance.database;
    return await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contractId],
    );
  }

  Future<List<Map<String, dynamic>>> getAllPendingLegacyInvoiceReviews() async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT
        r.invoice_id,
        r.contract_id,
        c.status AS contract_status,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        t.name AS tenant_name
      FROM legacy_invoice_reviews r
      JOIN tax_invoices ti ON ti.id = r.invoice_id
      JOIN contracts c ON c.id = r.contract_id
      LEFT JOIN tenants t ON t.id = c.tenant_id
      WHERE r.status = 'pending'
      ORDER BY ti.invoice_date, ti.id
      ''');
  }

  Future<List<Map<String, dynamic>>> getPendingLegacyInvoiceReviews(
    int contractId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        r.invoice_id,
        r.contract_id,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        t.name AS tenant_name
      FROM legacy_invoice_reviews r
      JOIN tax_invoices ti ON ti.id = r.invoice_id
      JOIN contracts c ON c.id = r.contract_id
      LEFT JOIN tenants t ON t.id = c.tenant_id
      WHERE r.contract_id = ? AND r.status = 'pending'
      ORDER BY ti.invoice_date, ti.id
      ''',
      [contractId],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingLegacyInvoiceReviewsForTenant(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        r.invoice_id,
        r.contract_id,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount
      FROM legacy_invoice_reviews r
      JOIN tax_invoices ti ON ti.id = r.invoice_id
      JOIN contracts c ON c.id = r.contract_id
      WHERE c.tenant_id = ? AND r.status = 'pending'
      ORDER BY ti.invoice_date, ti.id
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getLegacyInvoiceInstallmentCandidates(
    int invoiceId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT ci.id, ci.contract_id, ci.amount, ci.paid_amount, ci.due_date, ci.status
      FROM legacy_invoice_reviews r
      JOIN tax_invoices ti ON ti.id = r.invoice_id
      JOIN contract_installments ci ON ci.contract_id = r.contract_id
      WHERE r.invoice_id = ?
        AND r.status = 'pending'
        AND ti.installment_id IS NULL
        AND ROUND(ci.amount * 100) = ROUND(ti.net_amount * 100)
        AND NOT EXISTS (
          SELECT 1 FROM tax_invoices linked
          WHERE linked.installment_id = ci.id
        )
      ORDER BY ci.due_date, ci.id
      ''',
      [invoiceId],
    );
  }

  Future<void> resolveLegacyInvoiceAsInstallment({
    required int invoiceId,
    required int installmentId,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError('سبب المطابقة مطلوب وبحد أقصى 1000 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final invoiceRows = await txn.rawQuery(
        '''
        SELECT r.status, r.contract_id, ti.net_amount, ti.tax_amount,
               ti.total_amount, ti.installment_id
        FROM legacy_invoice_reviews r
        JOIN tax_invoices ti ON ti.id = r.invoice_id
        WHERE r.invoice_id = ?
        LIMIT 1
        ''',
        [invoiceId],
      );
      if (invoiceRows.isEmpty || invoiceRows.first['status'] != 'pending') {
        throw StateError('الفاتورة التاريخية غير موجودة أو سبق تسويتها');
      }
      final invoice = invoiceRows.first;
      if (invoice['installment_id'] != null) {
        throw StateError('الفاتورة التاريخية مرتبطة بقسط بالفعل');
      }
      final contractId = (invoice['contract_id'] as num).toInt();
      final installmentRows = await txn.rawQuery(
        '''
        SELECT ci.id, ci.contract_id, ci.amount, c.tenant_id
        FROM contract_installments ci
        JOIN contracts c ON c.id = ci.contract_id
        WHERE ci.id = ? AND ci.contract_id = ?
        LIMIT 1
        ''',
        [installmentId, contractId],
      );
      if (installmentRows.isEmpty) {
        throw StateError('القسط المختار لا يتبع عقد الفاتورة التاريخية');
      }
      final netAmount = (invoice['net_amount'] as num).toDouble();
      final taxAmount = (invoice['tax_amount'] as num).toDouble();
      final grossAmount = (invoice['total_amount'] as num).toDouble();
      final installmentAmount = (installmentRows.first['amount'] as num)
          .toDouble();
      if (!_hasCentPrecision(netAmount) ||
          !_hasCentPrecision(taxAmount) ||
          !_hasCentPrecision(grossAmount) ||
          !_hasCentPrecision(installmentAmount)) {
        throw StateError('تتضمن الفاتورة أو القسط مبلغًا لا يمكن مطابقته بدقة');
      }
      final netMinor = InternalTax.toMinorUnits(netAmount);
      final taxMinor = InternalTax.toMinorUnits(taxAmount);
      final grossMinor = InternalTax.toMinorUnits(grossAmount);
      if (netMinor != InternalTax.toMinorUnits(installmentAmount) ||
          netMinor + taxMinor != grossMinor) {
        throw StateError(
          'صافي الفاتورة لا يطابق قيمة القسط أو إجماليها غير متسق',
        );
      }
      final duplicateRows = await txn.query(
        'tax_invoices',
        columns: ['id'],
        where: 'installment_id = ? AND id != ?',
        whereArgs: [installmentId, invoiceId],
        limit: 1,
      );
      if (duplicateRows.isNotEmpty) {
        throw StateError('القسط مرتبط بفاتورة أخرى بالفعل');
      }
      final contractTenantId = (installmentRows.first['tenant_id'] as num)
          .toInt();

      await _ensureNoPendingLegacyTenantPayments(txn, contractTenantId);
      final invoicePaymentRows = await txn.rawQuery(
        '''
        SELECT via.voucher_id, via.amount AS allocated_amount,
               v.amount AS voucher_amount, v.voucher_type, v.tenant_id,
               v.journal_entry_id, v.voucher_date, je.is_posted
        FROM voucher_invoice_allocations via
        JOIN vouchers v ON v.id = via.voucher_id
        LEFT JOIN journal_entries je ON je.id = v.journal_entry_id
        WHERE via.invoice_id = ?
        ORDER BY v.voucher_date, v.id
        ''',
        [invoiceId],
      );
      final installmentPaymentRows = await txn.rawQuery(
        '''
        SELECT via.voucher_id, via.amount AS allocated_amount,
               v.amount AS voucher_amount, v.voucher_type, v.tenant_id,
               v.journal_entry_id, v.voucher_date, je.is_posted
        FROM voucher_installment_allocations via
        JOIN vouchers v ON v.id = via.voucher_id
        LEFT JOIN journal_entries je ON je.id = v.journal_entry_id
        WHERE via.installment_id = ?
        ORDER BY v.voucher_date, v.id
        ''',
        [installmentId],
      );
      final receiptsById = <int, Map<String, dynamic>>{};
      void addReceiptAllocation(
        Map<String, dynamic> row, {
        required bool invoiceSpecific,
      }) {
        final amount = (row['allocated_amount'] as num).toDouble();
        final voucherAmount = (row['voucher_amount'] as num).toDouble();
        if (row['voucher_type'] != 'قبض مستأجر' ||
            (row['tenant_id'] as num?)?.toInt() != contractTenantId ||
            (row['is_posted'] as num?)?.toInt() != 1 ||
            !_hasCentPrecision(amount) ||
            !_hasCentPrecision(voucherAmount) ||
            amount <= 0 ||
            voucherAmount <= 0) {
          throw StateError(
            'تخصيص قبض تاريخي غير مرحّل أو غير متوافق؛ لا يمكن ربط الفاتورة بأمان',
          );
        }
        final voucherId = (row['voucher_id'] as num).toInt();
        final amountMinor = InternalTax.toMinorUnits(amount);
        final voucherAmountMinor = InternalTax.toMinorUnits(voucherAmount);
        final receipt = receiptsById.putIfAbsent(
          voucherId,
          () => {
            'voucher_id': voucherId,
            'voucher_amount_minor': voucherAmountMinor,
            'voucher_date': row['voucher_date'],
          },
        );
        if (receipt['voucher_amount_minor'] != voucherAmountMinor) {
          throw StateError('قيمة سند القبض التاريخي غير متسقة بين تخصيصاته');
        }
        final allocationKey = invoiceSpecific
            ? 'invoice_amount_minor'
            : 'installment_amount_minor';
        final previousAmount = receipt[allocationKey] as int?;
        if (previousAmount != null && previousAmount != amountMinor) {
          throw StateError('يوجد تخصيص قبض تاريخي مكرر وغير متطابق');
        }
        receipt[allocationKey] = amountMinor;
      }

      for (final row in invoicePaymentRows) {
        addReceiptAllocation(row, invoiceSpecific: true);
      }
      for (final row in installmentPaymentRows) {
        addReceiptAllocation(row, invoiceSpecific: false);
      }
      for (final receipt in receiptsById.values) {
        final invoiceAmount = receipt['invoice_amount_minor'] as int?;
        final installmentAmount = receipt['installment_amount_minor'] as int?;
        if (invoiceAmount != null && installmentAmount != null) {
          if (invoiceAmount < installmentAmount ||
              invoiceAmount - installmentAmount > taxMinor) {
            throw StateError(
              'إجمالي تخصيص الفاتورة وصافي القسط لا يفسران بعضهما ضمن ضريبة الفاتورة؛ يلزم فحص يدوي',
            );
          }
          receipt['amount_minor'] = invoiceAmount;
          receipt['rent_amount_minor'] = installmentAmount;
          receipt['tax_amount_minor'] = invoiceAmount - installmentAmount;
        } else if (invoiceAmount != null) {
          receipt['amount_minor'] = invoiceAmount;
        } else {
          receipt['amount_minor'] = installmentAmount!;
          receipt['rent_amount_minor'] = installmentAmount;
          receipt['tax_amount_minor'] = 0;
        }
      }
      final receipts = receiptsById.values.toList()
        ..sort(
          (a, b) => (a['voucher_date'] as String).compareTo(
            b['voucher_date'] as String,
          ),
        );
      final sourceByVoucher = <int, Map<String, dynamic>>{};
      for (final receipt in receipts) {
        final voucherId = receipt['voucher_id'] as int;
        final amountMinor = receipt['amount_minor'] as int;
        final existingSources = await txn.query(
          'collection_allocations',
          where: 'voucher_id = ? AND installment_id = ?',
          whereArgs: [voucherId, installmentId],
          limit: 2,
        );
        if (existingSources.length > 1) {
          throw StateError('يوجد أكثر من مصدر قبض لنفس السند والقسط');
        }
        Map<String, dynamic>? source;
        if (existingSources.isNotEmpty) {
          source = existingSources.single;
          final linkedInvoiceId = (source['invoice_id'] as num?)?.toInt();
          final sourceAmount = (source['amount_minor'] as num).toInt();
          final expectedRentMinor = receipt['rent_amount_minor'] as int?;
          final expectedTaxMinor = receipt['tax_amount_minor'] as int?;
          final reconcilesGrossAndRent =
              linkedInvoiceId == null &&
              expectedRentMinor != null &&
              expectedTaxMinor != null &&
              sourceAmount == expectedRentMinor &&
              (source['rent_amount_minor'] as num).toInt() == sourceAmount &&
              (source['tax_amount_minor'] as num).toInt() == 0 &&
              expectedRentMinor + expectedTaxMinor == amountMinor;
          if ((linkedInvoiceId != null && linkedInvoiceId != invoiceId) ||
              (sourceAmount != amountMinor && !reconcilesGrossAndRent)) {
            throw StateError(
              'مصدر القبض التاريخي لا يطابق تخصيص الفاتورة والقسط؛ يلزم فحص يدوي',
            );
          }
        }
        final totalSources = await txn.rawQuery(
          '''
          SELECT COALESCE(SUM(amount_minor), 0) AS allocated_minor
          FROM collection_allocations
          WHERE voucher_id = ?
          ''',
          [voucherId],
        );
        var allocatedByVoucher = (totalSources.first['allocated_minor'] as num)
            .toInt();
        if (source == null) {
          allocatedByVoucher += amountMinor;
        } else {
          allocatedByVoucher +=
              amountMinor - (source['amount_minor'] as num).toInt();
        }
        if (allocatedByVoucher > (receipt['voucher_amount_minor'] as int)) {
          throw StateError(
            'مصادر سند القبض التاريخي تتجاوز قيمة السند؛ أوقف الربط للمراجعة',
          );
        }
        sourceByVoucher[voucherId] = {
          'source': source,
          'amount_minor': amountMinor,
          'rent_amount_minor': receipt['rent_amount_minor'],
          'tax_amount_minor': receipt['tax_amount_minor'],
        };
      }

      await txn.update(
        'tax_invoices',
        {'installment_id': installmentId},
        where: 'id = ? AND installment_id IS NULL',
        whereArgs: [invoiceId],
      );
      final createdBy = await _verifiedAuditUserId(txn);
      for (final entry in sourceByVoucher.entries) {
        final source = entry.value['source'] as Map<String, dynamic>?;
        if (source != null) {
          final linkedInvoiceId = (source['invoice_id'] as num?)?.toInt();
          if (linkedInvoiceId == null) {
            final amountMinor = entry.value['amount_minor'] as int;
            final rentMinor = entry.value['rent_amount_minor'] as int?;
            final taxMinorForSource = entry.value['tax_amount_minor'] as int?;
            if (rentMinor != null &&
                taxMinorForSource != null &&
                (source['amount_minor'] as num).toInt() != amountMinor) {
              await txn.update(
                'collection_allocations',
                {
                  'invoice_id': invoiceId,
                  'amount_minor': amountMinor,
                  'rent_amount_minor': rentMinor,
                  'tax_amount_minor': taxMinorForSource,
                },
                where: 'id = ? AND invoice_id IS NULL',
                whereArgs: [source['id']],
              );
            } else {
              await txn.update(
                'collection_allocations',
                {'invoice_id': invoiceId},
                where: 'id = ? AND invoice_id IS NULL',
                whereArgs: [source['id']],
              );
            }
          }
        } else {
          final amountMinor = entry.value['amount_minor'] as int;
          final usedRentRows = await txn.rawQuery(
            '''
            SELECT COALESCE(SUM(remaining_rent_minor), 0) AS used_rent,
                   COALESCE(SUM(remaining_tax_minor), 0) AS used_tax
            FROM collection_allocation_balances
            WHERE invoice_id = ?
            ''',
            [invoiceId],
          );
          final usedRent = (usedRentRows.first['used_rent'] as num).toInt();
          final usedTax = (usedRentRows.first['used_tax'] as num).toInt();
          final remainingRent = netMinor - usedRent;
          final remainingTax = taxMinor - usedTax;
          if (remainingRent < 0 || remainingTax < 0) {
            throw StateError(
              'المقبوضات المرتبطة تتجاوز صافي أو ضريبة الفاتورة',
            );
          }
          final specifiedRentMinor = (entry.value['rent_amount_minor'] as int?);
          final specifiedTaxMinor = (entry.value['tax_amount_minor'] as int?);
          final rentMinor =
              specifiedRentMinor ??
              (amountMinor < remainingRent ? amountMinor : remainingRent);
          final taxPartMinor = specifiedTaxMinor ?? (amountMinor - rentMinor);
          if (rentMinor + taxPartMinor != amountMinor ||
              rentMinor > remainingRent ||
              taxPartMinor > remainingTax) {
            throw StateError(
              'المقبوضات التاريخية تتجاوز صافي أو ضريبة الفاتورة؛ يلزم فحص يدوي',
            );
          }
          await txn.insert('collection_allocations', {
            'voucher_id': entry.key,
            'installment_id': installmentId,
            'invoice_id': invoiceId,
            'amount_minor': amountMinor,
            'rent_amount_minor': rentMinor,
            'tax_amount_minor': taxPartMinor,
            'created_by': createdBy,
          });
        }
      }
      final invoiceBalanceRows = await txn.rawQuery(
        '''
        SELECT COALESCE(SUM(remaining_minor), 0) AS remaining_minor,
               COALESCE(SUM(remaining_rent_minor), 0) AS remaining_rent_minor,
               COALESCE(SUM(remaining_tax_minor), 0) AS remaining_tax_minor
        FROM collection_allocation_balances
        WHERE invoice_id = ?
        ''',
        [invoiceId],
      );
      final linkedRemaining =
          (invoiceBalanceRows.first['remaining_minor'] as num).toInt();
      final linkedRentRemaining =
          (invoiceBalanceRows.first['remaining_rent_minor'] as num).toInt();
      final linkedTaxRemaining =
          (invoiceBalanceRows.first['remaining_tax_minor'] as num).toInt();
      if (linkedRemaining > grossMinor ||
          linkedRentRemaining > netMinor ||
          linkedTaxRemaining > taxMinor ||
          linkedRentRemaining + linkedTaxRemaining != linkedRemaining) {
        throw StateError(
          'القبوض أو الردود التاريخية لا تتطابق مع رصيد الفاتورة؛ يلزم مراجعة يدوية',
        );
      }
      await txn.update(
        'legacy_invoice_reviews',
        {
          'status': 'linked',
          'reason': normalizedReason,
          'reviewed_by': createdBy,
          'reviewed_at': DateTime.now().toIso8601String(),
        },
        where: "invoice_id = ? AND status = 'pending'",
        whereArgs: [invoiceId],
      );
      await _recordAuditTx(
        txn,
        action: 'LEGACY_INVOICE_LINKED_TO_INSTALLMENT',
        entityType: 'tax_invoice',
        entityId: invoiceId,
        details: {
          'invoice_id': invoiceId,
          'installment_id': installmentId,
          'contract_id': contractId,
          'receipt_voucher_ids': receipts
              .map((receipt) => receipt['voucher_id'])
              .toList(),
          'reason': normalizedReason,
        },
      );
    });
  }

  Future<void> resolveLegacyInvoiceAsNonBillable({
    required int invoiceId,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError('سبب المراجعة مطلوب وبحد أقصى 1000 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final invoices = await txn.rawQuery(
        '''
        SELECT r.status, ti.journal_entry_id
        FROM legacy_invoice_reviews r
        JOIN tax_invoices ti ON ti.id = r.invoice_id
        WHERE r.invoice_id = ?
        LIMIT 1
        ''',
        [invoiceId],
      );
      if (invoices.isEmpty || invoices.first['status'] != 'pending') {
        throw StateError('الفاتورة التاريخية غير موجودة أو سبق تسويتها');
      }
      final payments = await txn.query(
        'voucher_invoice_allocations',
        columns: ['id'],
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
        limit: 1,
      );
      if (payments.isNotEmpty || invoices.first['journal_entry_id'] != null) {
        throw StateError(
          'للفاتورة ترحيل أو تحصيلات؛ يجب ربطها بقسط ومراجعة تحصيلاتها، لا استبعادها',
        );
      }
      final reviewedBy = await _verifiedAuditUserId(txn);
      await txn.update(
        'legacy_invoice_reviews',
        {
          'status': 'non_billable',
          'reason': normalizedReason,
          'reviewed_by': reviewedBy,
          'reviewed_at': DateTime.now().toIso8601String(),
        },
        where: "invoice_id = ? AND status = 'pending'",
        whereArgs: [invoiceId],
      );
      await _recordAuditTx(
        txn,
        action: 'LEGACY_INVOICE_MARKED_NON_BILLABLE',
        entityType: 'tax_invoice',
        entityId: invoiceId,
        details: {'invoice_id': invoiceId, 'reason': normalizedReason},
      );
    });
  }

  Future<List<Map<String, dynamic>>> getUnbilledInstallmentsForContract(
    int contractId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT ci.*
      FROM contract_installments ci
      JOIN contracts c ON c.id = ci.contract_id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      WHERE ci.contract_id = ? AND c.status = 'Active' AND ti.id IS NULL
      ORDER BY ci.due_date, ci.id
      ''',
      [contractId],
    );
  }

  Future<List<Map<String, dynamic>>> getUnbilledInstallmentsForTenant(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        ci.*,
        (SELECT COUNT(*) + 1 FROM contract_installments earlier
          WHERE earlier.contract_id = ci.contract_id
            AND (DATE(earlier.due_date) < DATE(ci.due_date)
              OR (DATE(earlier.due_date) = DATE(ci.due_date)
                AND earlier.id < ci.id))) AS installment_number,
        p.name AS property_name,
        u.unit_number
      FROM contract_installments ci
      JOIN contracts c ON c.id = ci.contract_id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      LEFT JOIN units u ON u.id = c.unit_id
      LEFT JOIN properties p ON p.id = u.property_id
      WHERE c.tenant_id = ?
        AND (c.status = 'Active'
          OR (c.status = 'Terminated'
            AND DATE(ci.due_date) <= DATE(c.early_termination_date)))
        AND ci.status != 'Paid'
        AND ci.status != 'Cancelled'
        AND ti.id IS NULL
      ORDER BY ci.due_date, ci.id
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getOpenTaxInvoicesForTenant(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        ti.id,
        ti.contract_id,
        ti.installment_id,
        (SELECT COUNT(*) + 1 FROM contract_installments earlier
          WHERE earlier.contract_id = ci.contract_id
            AND (DATE(earlier.due_date) < DATE(ci.due_date)
              OR (DATE(earlier.due_date) = DATE(ci.due_date)
                AND earlier.id < ci.id))) AS installment_number,
        p.name AS property_name,
        u.unit_number,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        ci.due_date,
        ci.amount AS installment_amount,
        ci.paid_amount AS installment_paid_amount,
        COALESCE(vip.paid_minor, 0) / 100.0 AS paid_amount,
        COALESCE(credit.total_minor, 0) / 100.0 AS credited_amount,
        MAX(CAST(ROUND(ti.total_amount * 100) AS INTEGER)
          - COALESCE(vip.paid_minor, 0)
          - COALESCE(credit.total_minor, 0), 0) / 100.0
          AS remaining_amount
      FROM tax_invoices ti
      JOIN contracts c ON c.id = ti.contract_id
      JOIN contract_installments ci ON ci.id = ti.installment_id
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      LEFT JOIN (
        SELECT invoice_id, SUM(remaining_minor) AS paid_minor
        FROM collection_allocation_balances
        WHERE invoice_id IS NOT NULL
        GROUP BY invoice_id
      ) vip ON vip.invoice_id = ti.id
      LEFT JOIN (
        SELECT invoice_id, SUM(total_amount_minor) AS total_minor
        FROM credit_notes
        WHERE status = 'posted'
        GROUP BY invoice_id
      ) credit ON credit.invoice_id = ti.id
      WHERE c.tenant_id = ? AND c.status IN ('Active', 'Terminated')
      GROUP BY ti.id
      HAVING MAX(CAST(ROUND(ti.total_amount * 100) AS INTEGER)
        - COALESCE(vip.paid_minor, 0)
        - COALESCE(credit.total_minor, 0), 0) > 0
      ORDER BY ci.due_date, ti.invoice_date, ti.id
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getCreditNoteInvoiceCandidates() async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT
        ti.id AS invoice_id,
        ti.contract_id,
        ti.installment_id,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        ti.tax_account_id,
        c.tenant_id,
        t.name AS tenant_name,
        COALESCE(credits.net_minor, 0) AS credited_net_minor,
        COALESCE(credits.tax_minor, 0) AS credited_tax_minor,
        COALESCE(credits.total_minor, 0) AS credited_total_minor,
        MAX(CAST(ROUND(ti.total_amount * 100) AS INTEGER)
          - COALESCE(credits.total_minor, 0), 0) AS available_credit_minor,
        source.is_posted AS source_journal_posted
      FROM tax_invoices ti
      JOIN contracts c ON c.id = ti.contract_id
      JOIN tenants t ON t.id = c.tenant_id
      LEFT JOIN (
        SELECT invoice_id,
          SUM(net_amount_minor) AS net_minor,
          SUM(tax_amount_minor) AS tax_minor,
          SUM(total_amount_minor) AS total_minor
        FROM credit_notes
        WHERE status = 'posted'
        GROUP BY invoice_id
      ) credits ON credits.invoice_id = ti.id
      LEFT JOIN journal_entries source ON source.id = ti.journal_entry_id
      WHERE CAST(ROUND(ti.total_amount * 100) AS INTEGER)
        > COALESCE(credits.total_minor, 0)
        AND source.is_posted = 1
        AND CAST(ROUND(ti.net_amount * 100) AS INTEGER)
          + CAST(ROUND(ti.tax_amount * 100) AS INTEGER)
          = CAST(ROUND(ti.total_amount * 100) AS INTEGER)
      ORDER BY ti.invoice_date DESC, ti.id DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getCreditNotesForInvoice(
    int invoiceId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.transaction((txn) => _creditNoteRefundBalancesTx(txn, invoiceId));
  }

  Future<List<Map<String, dynamic>>> _creditNoteRefundBalancesTx(
    DatabaseExecutor txn,
    int invoiceId,
  ) async {
    return txn.rawQuery(
      '''
      SELECT note.*, balance.tenant_id, balance.applied_minor,
        balance.refunded_minor, balance.refunded_net_minor,
        balance.refunded_tax_minor, balance.refundable_minor,
        balance.refundable_net_minor, balance.refundable_tax_minor
      FROM credit_note_refund_balances balance
      JOIN credit_notes note ON note.id = balance.id
      WHERE balance.invoice_id = ?
      ORDER BY balance.note_date, balance.id
      ''',
      [invoiceId],
    );
  }

  Future<List<Map<String, dynamic>>> getCreditNotes({int? invoiceId}) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    final where = invoiceId == null ? '' : 'WHERE note.invoice_id = ?';
    return db.rawQuery('''
      SELECT note.*,
        invoice.invoice_date,
        invoice.total_amount AS invoice_total_amount,
        contract.tenant_id,
        tenant.name AS tenant_name
      FROM credit_notes note
      LEFT JOIN tax_invoices invoice ON invoice.id = note.invoice_id
      LEFT JOIN contracts contract ON contract.id = invoice.contract_id
      LEFT JOIN tenants tenant ON tenant.id = contract.tenant_id
      $where
      ORDER BY note.note_date DESC, note.id DESC
    ''', invoiceId == null ? const [] : [invoiceId]);
  }

  Future<int> createCreditNoteDraft({
    required int invoiceId,
    required String noteDate,
    required int totalAmountMinor,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.add);
    final normalizedReason = reason.trim();
    if (!_isIsoCalendarDate(noteDate) ||
        totalAmountMinor <= 0 ||
        normalizedReason.isEmpty ||
        normalizedReason.length > 500) {
      throw ArgumentError('تاريخ الإشعار ومبلغه وسببه مطلوبة وصحيحة');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.add);
      final invoices = await txn.rawQuery(
        '''
        SELECT ti.* FROM tax_invoices ti
        WHERE ti.id = ?
        LIMIT 1
        ''',
        [invoiceId],
      );
      if (invoices.isEmpty) throw StateError('الفاتورة الأصلية غير موجودة');
      final invoice = invoices.first;
      final net = (invoice['net_amount'] as num).toDouble();
      final tax = (invoice['tax_amount'] as num).toDouble();
      final total = (invoice['total_amount'] as num).toDouble();
      if (!_hasCentPrecision(net) ||
          !_hasCentPrecision(tax) ||
          !_hasCentPrecision(total) ||
          InternalTax.toMinorUnits(net + tax) !=
              InternalTax.toMinorUnits(total)) {
        throw StateError('مبالغ الفاتورة الأصلية غير متسقة؛ يلزم فحص يدوي');
      }
      final priorCredits = await txn.rawQuery(
        '''
        SELECT COALESCE(SUM(net_amount_minor), 0) AS net_minor,
          COALESCE(SUM(tax_amount_minor), 0) AS tax_minor,
          COALESCE(SUM(total_amount_minor), 0) AS total_minor
        FROM credit_notes
        WHERE invoice_id = ? AND status = 'posted'
        ''',
        [invoiceId],
      );
      final originalNetMinor = InternalTax.toMinorUnits(net);
      final originalTaxMinor = InternalTax.toMinorUnits(tax);
      final originalTotalMinor = InternalTax.toMinorUnits(total);
      final priorNetMinor = (priorCredits.first['net_minor'] as num).toInt();
      final priorTaxMinor = (priorCredits.first['tax_minor'] as num).toInt();
      final priorTotalMinor = (priorCredits.first['total_minor'] as num)
          .toInt();
      final remainingNet = originalNetMinor - priorNetMinor;
      final remainingTax = originalTaxMinor - priorTaxMinor;
      final remainingTotal = originalTotalMinor - priorTotalMinor;
      if (remainingNet < 0 ||
          remainingTax < 0 ||
          remainingTotal < 0 ||
          remainingNet + remainingTax != remainingTotal ||
          totalAmountMinor > remainingTotal) {
        throw StateError('مبلغ الإشعار يتجاوز الرصيد غير المعكوس من الفاتورة');
      }
      var noteTaxMinor = totalAmountMinor == remainingTotal
          ? remainingTax
          : ((BigInt.from(totalAmountMinor) * BigInt.from(remainingTax) +
                        BigInt.from(remainingTotal ~/ 2)) ~/
                    BigInt.from(remainingTotal))
                .toInt();
      if (noteTaxMinor > remainingTax) noteTaxMinor = remainingTax;
      var noteNetMinor = totalAmountMinor - noteTaxMinor;
      if (noteNetMinor > remainingNet) {
        noteNetMinor = remainingNet;
        noteTaxMinor = totalAmountMinor - noteNetMinor;
      }
      if (noteNetMinor < 0 ||
          noteTaxMinor < 0 ||
          noteTaxMinor > remainingTax ||
          noteNetMinor + noteTaxMinor != totalAmountMinor) {
        throw StateError('تعذر توزيع الإشعار على الصافي والضريبة بأمان');
      }
      final actorId = await _verifiedAuditUserId(txn);
      final createdAt = DateTime.now().toIso8601String();
      final noteId = await txn.insert('credit_notes', {
        'invoice_id': invoiceId,
        'note_date': noteDate,
        'amount': totalAmountMinor / 100.0,
        'reason': normalizedReason,
        'status': 'draft',
        'net_amount_minor': noteNetMinor,
        'tax_amount_minor': noteTaxMinor,
        'total_amount_minor': totalAmountMinor,
        'tax_rate_snapshot': invoice['tax_rate'],
        'tax_account_id': invoice['tax_account_id'],
        'created_by': actorId,
        'created_at': createdAt,
      });
      await _recordAuditTx(
        txn,
        action: 'CREDIT_NOTE_DRAFT_CREATED',
        entityType: 'credit_note',
        entityId: noteId,
        amountMinor: totalAmountMinor,
        details: {
          'invoice_id': invoiceId,
          'note_date': noteDate,
          'net_amount_minor': noteNetMinor,
          'tax_amount_minor': noteTaxMinor,
          'reason': normalizedReason,
        },
      );
      return noteId;
    });
  }

  List<int> _allocateCreditNoteMinorUnits({
    required int amountMinor,
    required List<Map<String, dynamic>> sourceLines,
    required String sourceAmountField,
  }) {
    if (sourceLines.isEmpty || amountMinor < 0) {
      throw StateError('تعذر توزيع مبلغ الإشعار على أسطر مصدره');
    }
    final weights = sourceLines
        .map(
          (line) => InternalTax.toMinorUnits(
            (line[sourceAmountField] as num).toDouble(),
          ),
        )
        .toList();
    final totalWeight = weights.fold<int>(0, (sum, value) => sum + value);
    if (totalWeight <= 0) {
      throw StateError('لا توجد مبالغ مصدر صالحة لتوزيع الإشعار');
    }
    var allocated = 0;
    return List<int>.generate(sourceLines.length, (index) {
      if (index == sourceLines.length - 1) return amountMinor - allocated;
      final share =
          (BigInt.from(amountMinor) *
                  BigInt.from(weights[index]) ~/
                  BigInt.from(totalWeight))
              .toInt();
      allocated += share;
      return share;
    });
  }

  Future<void> postCreditNote(int creditNoteId) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    final db = await instance.database;
    await db.transaction((txn) async {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
      final notes = await txn.query(
        'credit_notes',
        where: 'id = ?',
        whereArgs: [creditNoteId],
        limit: 1,
      );
      if (notes.isEmpty || notes.first['status'] != 'draft') {
        throw StateError('لا يمكن ترحيل هذا الإشعار؛ يجب أن يكون مسودة');
      }
      final note = notes.first;
      final invoiceId = (note['invoice_id'] as num?)?.toInt();
      if (invoiceId == null) {
        throw StateError(
          'الإشعار التاريخي بلا فاتورة أصلية؛ يتطلب مراجعة يدوية',
        );
      }
      final noteNet = (note['net_amount_minor'] as num).toInt();
      final noteTax = (note['tax_amount_minor'] as num).toInt();
      final noteTotal = (note['total_amount_minor'] as num).toInt();
      final noteAmount = (note['amount'] as num).toDouble();
      if (noteTotal <= 0 ||
          noteNet + noteTax != noteTotal ||
          !_hasCentPrecision(noteAmount) ||
          InternalTax.toMinorUnits(noteAmount) != noteTotal ||
          !_isIsoCalendarDate(note['note_date']?.toString() ?? '') ||
          (note['reason']?.toString().trim().isEmpty ?? true)) {
        throw StateError('تفصيل مبلغ الإشعار غير متوازن');
      }
      final invoices = await txn.rawQuery(
        '''
        SELECT ti.*, c.tenant_id, t.account_id AS tenant_account_id
        FROM tax_invoices ti
        JOIN contracts c ON c.id = ti.contract_id
        JOIN tenants t ON t.id = c.tenant_id
        WHERE ti.id = ?
        LIMIT 1
        ''',
        [invoiceId],
      );
      if (invoices.isEmpty)
        throw StateError('الفاتورة الأصلية غير مرتبطة بمستأجر');
      final invoice = invoices.first;
      final invoiceNet = (invoice['net_amount'] as num).toDouble();
      final invoiceTax = (invoice['tax_amount'] as num).toDouble();
      final invoiceTotal = (invoice['total_amount'] as num).toDouble();
      if (!_hasCentPrecision(invoiceNet) ||
          !_hasCentPrecision(invoiceTax) ||
          !_hasCentPrecision(invoiceTotal) ||
          InternalTax.toMinorUnits(invoiceNet + invoiceTax) !=
              InternalTax.toMinorUnits(invoiceTotal)) {
        throw StateError('الفاتورة الأصلية غير متسقة؛ لا يمكن ترحيل الإشعار');
      }
      final invoiceTaxRate = invoice['tax_rate'] as num?;
      final noteTaxRate = note['tax_rate_snapshot'] as num?;
      if ((invoiceTaxRate == null) != (noteTaxRate == null) ||
          (invoiceTaxRate != null &&
              invoiceTaxRate.toDouble() != noteTaxRate!.toDouble()) ||
          (invoice['tax_account_id'] as num?)?.toInt() !=
              (note['tax_account_id'] as num?)?.toInt()) {
        throw StateError('لقطة الضريبة في المسودة تغيرت عن الفاتورة الأصلية');
      }
      final sourceJournalId = (invoice['journal_entry_id'] as num?)?.toInt();
      if (sourceJournalId == null) {
        throw StateError('الفاتورة لا تحمل قيدًا أصليًا صالحًا للانعكاس');
      }
      final sourceJournal = await txn.query(
        'journal_entries',
        columns: ['id', 'is_posted'],
        where: 'id = ?',
        whereArgs: [sourceJournalId],
        limit: 1,
      );
      if (sourceJournal.isEmpty || sourceJournal.first['is_posted'] != 1) {
        throw StateError('قيد الفاتورة الأصلية غير مرحّل؛ راجع المصدر يدويًا');
      }
      final sourceLines = await txn.rawQuery(
        '''
        SELECT jl.account_id, jl.debit, jl.credit, jl.cost_center_id,
          a.account_type
        FROM journal_lines jl
        JOIN accounts a ON a.id = jl.account_id
        WHERE jl.journal_entry_id = ?
        ORDER BY jl.id
        ''',
        [sourceJournalId],
      );
      final receivableLines = <Map<String, dynamic>>[];
      final revenueLines = <Map<String, dynamic>>[];
      final taxLines = <Map<String, dynamic>>[];
      var sourceDebitMinor = 0;
      var sourceCreditMinor = 0;
      var sourceNetMinor = 0;
      var sourceTaxMinor = 0;
      for (final line in sourceLines) {
        final debit = (line['debit'] as num).toDouble();
        final credit = (line['credit'] as num).toDouble();
        if (!_hasCentPrecision(debit) ||
            !_hasCentPrecision(credit) ||
            debit < 0 ||
            credit < 0 ||
            (debit > 0 && credit > 0) ||
            (debit == 0 && credit == 0)) {
          throw StateError('سطر قيد الفاتورة غير صالح؛ يلزم فحص يدوي');
        }
        final debitMinor = InternalTax.toMinorUnits(debit);
        final creditMinor = InternalTax.toMinorUnits(credit);
        final type = line['account_type']?.toString();
        final accountId = (line['account_id'] as num).toInt();
        sourceDebitMinor += debitMinor;
        sourceCreditMinor += creditMinor;
        if (debitMinor > 0) {
          if (type != 'Asset' ||
              invoice['tenant_account_id'] == null ||
              accountId != (invoice['tenant_account_id'] as num).toInt()) {
            throw StateError(
              'حساب الذمم بالقيد الأصلي لا يطابق حساب المستأجر الحالي؛ راجع الحساب يدويًا',
            );
          }
          receivableLines.add(line);
        } else if (type == 'Revenue') {
          revenueLines.add(line);
          sourceNetMinor += creditMinor;
        } else if (type == 'Liability') {
          if (invoice['tax_account_id'] == null ||
              accountId != (invoice['tax_account_id'] as num).toInt()) {
            throw StateError(
              'حساب الالتزام بالقيد الأصلي لا يطابق لقطة ضريبة الفاتورة؛ راجعها يدويًا',
            );
          }
          taxLines.add(line);
          sourceTaxMinor += creditMinor;
        } else {
          throw StateError(
            'قيد الفاتورة يحتوي حسابًا غير متوقع؛ لا يعكس آليًا',
          );
        }
      }
      final originalNetMinor = InternalTax.toMinorUnits(invoiceNet);
      final originalTaxMinor = InternalTax.toMinorUnits(invoiceTax);
      final originalTotalMinor = InternalTax.toMinorUnits(invoiceTotal);
      if (sourceLines.isEmpty ||
          sourceDebitMinor != originalTotalMinor ||
          sourceCreditMinor != originalTotalMinor ||
          sourceNetMinor != originalNetMinor ||
          sourceTaxMinor != originalTaxMinor ||
          receivableLines.isEmpty ||
          revenueLines.isEmpty ||
          (originalTaxMinor > 0 && taxLines.isEmpty) ||
          (originalTaxMinor == 0 && taxLines.isNotEmpty)) {
        throw StateError(
          'القيد الأصلي لا يطابق صافي وضريبة وإجمالي الفاتورة؛ راجع المستند يدويًا',
        );
      }
      final priorCredits = await txn.rawQuery(
        '''
        SELECT COALESCE(SUM(net_amount_minor), 0) AS net_minor,
          COALESCE(SUM(tax_amount_minor), 0) AS tax_minor,
          COALESCE(SUM(total_amount_minor), 0) AS total_minor
        FROM credit_notes
        WHERE invoice_id = ? AND status = 'posted'
        ''',
        [invoiceId],
      );
      final creditedNet = (priorCredits.first['net_minor'] as num).toInt();
      final creditedTax = (priorCredits.first['tax_minor'] as num).toInt();
      final creditedTotal = (priorCredits.first['total_minor'] as num).toInt();
      if (noteNet > originalNetMinor - creditedNet ||
          noteTax > originalTaxMinor - creditedTax ||
          noteTotal > originalTotalMinor - creditedTotal ||
          noteNet + noteTax != noteTotal) {
        throw StateError('تجاوز الإشعار الرصيد غير المعكوس؛ أعد تحميله');
      }
      final revenueShares = _allocateCreditNoteMinorUnits(
        amountMinor: noteNet,
        sourceLines: revenueLines,
        sourceAmountField: 'credit',
      );
      final taxShares = noteTax == 0
          ? List<int>.filled(taxLines.length, 0)
          : _allocateCreditNoteMinorUnits(
              amountMinor: noteTax,
              sourceLines: taxLines,
              sourceAmountField: 'credit',
            );
      final receivableShares = _allocateCreditNoteMinorUnits(
        amountMinor: noteTotal,
        sourceLines: receivableLines,
        sourceAmountField: 'debit',
      );
      final description =
          'إشعار دائن رقم $creditNoteId مرتبط بالفاتورة $invoiceId';
      final journalId = await txn.insert('journal_entries', {
        'entry_date': note['note_date'],
        'description': description,
        'is_posted': 1,
      });
      Future<void> addLine({
        required Map<String, dynamic> source,
        required int amountMinor,
        required bool debit,
        required String lineDescription,
      }) async {
        if (amountMinor <= 0) return;
        final amount = amountMinor / 100.0;
        final accountId = (source['account_id'] as num).toInt();
        await _requireLeafAccountTx(
          txn,
          accountId,
          expectedType: debit
              ? (source['account_type'] == 'Revenue' ? 'Revenue' : 'Liability')
              : 'Asset',
        );
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': accountId,
          'debit': debit ? amount : 0.0,
          'credit': debit ? 0.0 : amount,
          'cost_center_id': source['cost_center_id'],
          'description': lineDescription,
        });
        await _updateBalanceTx(
          txn,
          accountId,
          debit ? amount : 0.0,
          debit ? 0.0 : amount,
        );
      }

      for (var i = 0; i < revenueLines.length; i++) {
        await addLine(
          source: revenueLines[i],
          amountMinor: revenueShares[i],
          debit: true,
          lineDescription: 'عكس إيراد فاتورة $invoiceId',
        );
      }
      for (var i = 0; i < taxLines.length; i++) {
        await addLine(
          source: taxLines[i],
          amountMinor: taxShares[i],
          debit: true,
          lineDescription: 'عكس التزام ضريبة الفاتورة $invoiceId',
        );
      }
      for (var i = 0; i < receivableLines.length; i++) {
        await addLine(
          source: receivableLines[i],
          amountMinor: receivableShares[i],
          debit: false,
          lineDescription: 'تخفيض ذمم الفاتورة $invoiceId',
        );
      }
      final actorId = await _verifiedAuditUserId(txn);
      final changed = await txn.update(
        'credit_notes',
        {
          'status': 'posted',
          'journal_entry_id': journalId,
          'posted_by': actorId,
          'posted_at': DateTime.now().toIso8601String(),
        },
        where: "id = ? AND status = 'draft'",
        whereArgs: [creditNoteId],
      );
      if (changed != 1) throw StateError('تغيرت حالة الإشعار؛ أُلغيت المعاملة');
      await _recordAuditTx(
        txn,
        action: 'CREDIT_NOTE_POSTED',
        entityType: 'credit_note',
        entityId: creditNoteId,
        amountMinor: noteTotal,
        details: {
          'invoice_id': invoiceId,
          'journal_entry_id': journalId,
          'net_amount_minor': noteNet,
          'tax_amount_minor': noteTax,
          'note_date': note['note_date'],
        },
      );
    });
  }

  Future<void> reverseCreditNote(
    int creditNoteId, {
    required String reversalDate,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    final normalizedReason = reason.trim();
    if (!_isIsoCalendarDate(reversalDate) ||
        normalizedReason.isEmpty ||
        normalizedReason.length > 500) {
      throw ArgumentError('تاريخ وسبب عكس الإشعار مطلوبان');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
      final notes = await txn.query(
        'credit_notes',
        where: 'id = ?',
        whereArgs: [creditNoteId],
        limit: 1,
      );
      if (notes.isEmpty || notes.first['status'] != 'posted') {
        throw StateError('يمكن عكس الإشعار المرحّل فقط');
      }
      final originalNoteDate = notes.first['note_date']?.toString() ?? '';
      if (!_isIsoCalendarDate(originalNoteDate) ||
          reversalDate.compareTo(originalNoteDate) < 0) {
        throw ArgumentError(
          'تاريخ العكس يجب أن يكون صحيحًا وغير سابق لتاريخ الإشعار',
        );
      }
      final linkedRefund = await txn.query(
        'refund_allocations',
        columns: ['id'],
        where: 'credit_note_id = ?',
        whereArgs: [creditNoteId],
        limit: 1,
      );
      if (linkedRefund.isNotEmpty) {
        throw StateError(
          'لا يمكن عكس إشعار استُخدم في رد نقدي؛ يلزم مستند تسوية مستقل',
        );
      }
      final originalJournalId = (notes.first['journal_entry_id'] as num?)
          ?.toInt();
      if (originalJournalId == null) {
        throw StateError('قيد الإشعار المرحّل غير موجود؛ يلزم فحص يدوي');
      }
      final originalJournal = await txn.query(
        'journal_entries',
        columns: ['id', 'is_posted'],
        where: 'id = ?',
        whereArgs: [originalJournalId],
        limit: 1,
      );
      if (originalJournal.isEmpty || originalJournal.first['is_posted'] != 1) {
        throw StateError('قيد الإشعار غير مرحّل؛ لا يمكن عكسه');
      }
      final lines = await txn.query(
        'journal_lines',
        where: 'journal_entry_id = ?',
        whereArgs: [originalJournalId],
        orderBy: 'id',
      );
      if (lines.isEmpty)
        throw StateError('قيد الإشعار بلا أسطر؛ يلزم فحص يدوي');
      final journalId = await txn.insert('journal_entries', {
        'entry_date': reversalDate,
        'description': 'عكس إشعار دائن رقم $creditNoteId: $normalizedReason',
        'is_posted': 1,
      });
      for (final line in lines) {
        final debit = (line['debit'] as num).toDouble();
        final credit = (line['credit'] as num).toDouble();
        if (!_hasCentPrecision(debit) ||
            !_hasCentPrecision(credit) ||
            debit < 0 ||
            credit < 0 ||
            (debit > 0 && credit > 0)) {
          throw StateError('سطر قيد الإشعار غير صالح؛ لا يمكن عكسه');
        }
        final accountId = (line['account_id'] as num).toInt();
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': accountId,
          'debit': credit,
          'credit': debit,
          'cost_center_id': line['cost_center_id'],
          'description': 'عكس قيد الإشعار الدائن رقم $creditNoteId',
        });
        await _updateBalanceTx(txn, accountId, credit, debit);
      }
      final actorId = await _verifiedAuditUserId(txn);
      final changed = await txn.update(
        'credit_notes',
        {
          'status': 'reversed',
          'reversal_journal_entry_id': journalId,
          'reversal_reason': normalizedReason,
          'reversed_by': actorId,
          'reversed_at': DateTime.now().toIso8601String(),
        },
        where: "id = ? AND status = 'posted'",
        whereArgs: [creditNoteId],
      );
      if (changed != 1) throw StateError('تغيرت حالة الإشعار؛ أُلغيت المعاملة');
      await _recordAuditTx(
        txn,
        action: 'CREDIT_NOTE_REVERSED',
        entityType: 'credit_note',
        entityId: creditNoteId,
        amountMinor: (notes.first['total_amount_minor'] as num).toInt(),
        details: {
          'reversal_journal_entry_id': journalId,
          'reversal_date': reversalDate,
          'reason': normalizedReason,
        },
      );
    });
  }

  Future<void> _ensureNoPendingLegacyInvoicesForTenant(
    DatabaseExecutor txn,
    int tenantId,
  ) async {
    final pending = await txn.rawQuery(
      '''
      SELECT r.invoice_id
      FROM legacy_invoice_reviews r
      JOIN contracts c ON c.id = r.contract_id
      WHERE c.tenant_id = ? AND r.status = 'pending'
      LIMIT 1
      ''',
      [tenantId],
    );
    if (pending.isNotEmpty) {
      throw StateError(
        'توجد فاتورة تاريخية غير مرتبطة بقسط؛ راجعها قبل الفوترة أو القبض أو الاسترداد',
      );
    }
  }

  Future<void> _ensureNoPendingLegacyTenantPayments(
    DatabaseExecutor txn,
    int tenantId,
  ) async {
    final pending = await txn.query(
      'legacy_tenant_payment_reviews',
      columns: ['voucher_id'],
      where: "tenant_id = ? AND status = 'pending'",
      whereArgs: [tenantId],
      limit: 1,
    );
    if (pending.isNotEmpty) {
      throw StateError(
        'توجد سندات صرف مستأجر تاريخية غير مصنفة؛ طابقها يدويًا قبل الفوترة أو القبض أو الاسترداد',
      );
    }
  }

  // --- Tenant Financial Operations ---

  Future<int> insertTenantReceiptVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required List<Map<String, dynamic>> installmentsToUpdate,
    int? invoiceId,
    String? description,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (amount <= 0 ||
        !_hasCentPrecision(amount) ||
        DateTime.tryParse(voucherDate) == null ||
        (invoiceId == null && installmentsToUpdate.isEmpty) ||
        (invoiceId != null && installmentsToUpdate.isNotEmpty)) {
      throw ArgumentError('المبلغ والأقساط المطلوب تسديدها يجب أن تكون صحيحة');
    }
    final enteredDescription = description?.trim();
    final defaultVoucherDescription = invoiceId == null
        ? 'تحصيل دفعة إيجار'
        : 'سداد فاتورة رقم $invoiceId';
    final voucherDescription = enteredDescription ?? defaultVoucherDescription;
    final defaultJournalDescription = invoiceId == null
        ? 'سند قبض مستأجر'
        : 'سداد فاتورة داخلية رقم $invoiceId';
    final journalDescription = voucherDescription.isEmpty
        ? defaultJournalDescription
        : voucherDescription;
    final defaultReceiptLineDescription = invoiceId == null
        ? 'تحصيل دفعة مستأجر'
        : 'سداد فاتورة داخلية رقم $invoiceId';
    final receiptLineDescription = voucherDescription.isEmpty
        ? defaultReceiptLineDescription
        : voucherDescription;
    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      await _ensureNoPendingLegacyTenantPayments(txn, tenantId);
      await _ensureNoPendingLegacyInvoicesForTenant(txn, tenantId);
      final tenantAccountId = tenantRows.first['account_id'] as int;
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }

      var allocatedCents = 0;
      var invoiceInstallmentId = 0;
      var invoiceRentCents = 0;
      var invoiceTaxCents = 0;
      final verifiedUpdates = <Map<String, dynamic>>[];
      if (invoiceId != null) {
        final invoices = await txn.rawQuery(
          '''
          SELECT
            ti.id,
            ti.total_amount,
            ti.net_amount,
            ti.tax_amount,
            ti.installment_id,
            c.tenant_id,
            ci.amount AS installment_amount,
            ci.paid_amount AS installment_paid_amount
          FROM tax_invoices ti
          JOIN contracts c ON c.id = ti.contract_id
          JOIN contract_installments ci ON ci.id = ti.installment_id
          WHERE ti.id = ? AND c.status IN ('Active', 'Terminated')
          LIMIT 1
          ''',
          [invoiceId],
        );
        if (invoices.isEmpty || invoices.first['tenant_id'] != tenantId) {
          throw StateError(
            'الفاتورة المحددة لا تخص هذا المستأجر أو عقدها غير نشط',
          );
        }
        final invoice = invoices.first;
        invoiceInstallmentId = (invoice['installment_id'] as num).toInt();
        final invoiceTotal = (invoice['total_amount'] as num).toDouble();
        final invoiceNet = (invoice['net_amount'] as num).toDouble();
        final invoiceTax = (invoice['tax_amount'] as num).toDouble();
        if (!_hasCentPrecision(invoiceTotal) ||
            !_hasCentPrecision(invoiceNet) ||
            !_hasCentPrecision(invoiceTax)) {
          throw StateError('بيانات الفاتورة غير متسقة؛ لا يمكن تحصيلها');
        }
        final invoiceTotalCents = InternalTax.toMinorUnits(invoiceTotal);
        if (invoiceTotalCents !=
            InternalTax.toMinorUnits(invoiceNet + invoiceTax)) {
          throw StateError('بيانات الفاتورة غير متسقة؛ لا يمكن تحصيلها');
        }
        final paidRows = await txn.rawQuery(
          '''
          SELECT
            COALESCE(SUM(ca.amount_minor - COALESCE(refunds.amount_minor, 0)), 0)
              AS paid_minor,
            COALESCE(SUM(ca.rent_amount_minor
              - COALESCE(refunds.rent_amount_minor, 0)), 0) AS paid_rent_minor,
            COALESCE(SUM(ca.tax_amount_minor
              - COALESCE(refunds.tax_amount_minor, 0)), 0) AS paid_tax_minor
          FROM collection_allocations ca
          LEFT JOIN (
            SELECT collection_allocation_id,
              SUM(amount_minor) AS amount_minor,
              SUM(rent_amount_minor) AS rent_amount_minor,
              SUM(tax_amount_minor) AS tax_amount_minor
            FROM refund_allocations
            GROUP BY collection_allocation_id
          ) refunds ON refunds.collection_allocation_id = ca.id
          WHERE ca.invoice_id = ?
          ''',
          [invoiceId],
        );
        final invoicePaidMinor = (paidRows.first['paid_minor'] as num).toInt();
        final invoicePaidRentMinor = (paidRows.first['paid_rent_minor'] as num)
            .toInt();
        final invoicePaidTaxMinor = (paidRows.first['paid_tax_minor'] as num)
            .toInt();
        if (invoicePaidMinor != invoicePaidRentMinor + invoicePaidTaxMinor ||
            invoicePaidMinor < 0) {
          throw StateError('تخصيصات الفاتورة السابقة غير متسقة ماليًا');
        }
        final creditRows = await txn.rawQuery(
          '''
          SELECT COALESCE(SUM(net_amount_minor), 0) AS credited_net_minor,
            COALESCE(SUM(tax_amount_minor), 0) AS credited_tax_minor,
            COALESCE(SUM(total_amount_minor), 0) AS credited_total_minor
          FROM credit_notes
          WHERE invoice_id = ? AND status = 'posted'
          ''',
          [invoiceId],
        );
        final creditedNetMinor = (creditRows.first['credited_net_minor'] as num)
            .toInt();
        final creditedTaxMinor = (creditRows.first['credited_tax_minor'] as num)
            .toInt();
        final creditedTotalMinor =
            (creditRows.first['credited_total_minor'] as num).toInt();
        if (creditedNetMinor + creditedTaxMinor != creditedTotalMinor ||
            creditedNetMinor > InternalTax.toMinorUnits(invoiceNet) ||
            creditedTaxMinor > InternalTax.toMinorUnits(invoiceTax) ||
            creditedTotalMinor > invoiceTotalCents) {
          throw StateError('إجمالي الإشعارات الدائنة غير متسق مع الفاتورة');
        }
        final remainingInvoiceCents =
            invoiceTotalCents - invoicePaidMinor - creditedTotalMinor;
        final receiptCents = (amount * 100).round();
        if (remainingInvoiceCents <= 0 ||
            receiptCents > remainingInvoiceCents) {
          throw StateError('المبلغ يتجاوز المتبقي على الفاتورة؛ أعد تحميلها');
        }

        final installmentTotal = (invoice['installment_amount'] as num)
            .toDouble();
        final oldPaid =
            (invoice['installment_paid_amount'] as num?)?.toDouble() ?? 0;
        if (!_hasCentPrecision(installmentTotal) ||
            !_hasCentPrecision(oldPaid) ||
            oldPaid < 0 ||
            oldPaid > installmentTotal ||
            InternalTax.toMinorUnits(installmentTotal) !=
                InternalTax.toMinorUnits(invoiceNet)) {
          throw StateError('مبلغ القسط أو تحصيله غير متسق مع الفاتورة');
        }
        final installmentRemainingCents =
            InternalTax.toMinorUnits(installmentTotal) -
            InternalTax.toMinorUnits(oldPaid) -
            creditedNetMinor;
        final nonnegativeRentRemaining = installmentRemainingCents > 0
            ? installmentRemainingCents
            : 0;
        final principalCents = receiptCents < nonnegativeRentRemaining
            ? receiptCents
            : nonnegativeRentRemaining;
        final taxPart = receiptCents - principalCents;
        final remainingTaxCents =
            InternalTax.toMinorUnits(invoiceTax) -
            invoicePaidTaxMinor -
            creditedTaxMinor;
        if (taxPart < 0 || taxPart > remainingTaxCents) {
          throw StateError('مبلغ القبض يتجاوز المتبقي من ضريبة الفاتورة');
        }
        invoiceRentCents = principalCents;
        invoiceTaxCents = taxPart;
        if (principalCents > 0) {
          final newPaidCents =
              InternalTax.toMinorUnits(oldPaid) + principalCents;
          final newPaid = newPaidCents / 100;
          final status =
              newPaidCents >= InternalTax.toMinorUnits(installmentTotal)
              ? 'Paid'
              : 'Partially Paid';
          verifiedUpdates.add({
            'id': invoice['installment_id'],
            'old_paid': oldPaid,
            'paid_amount': newPaid,
            'status': status,
            'allocated_amount': principalCents / 100,
          });
        }
        allocatedCents = receiptCents;
      } else {
        for (final requested in installmentsToUpdate) {
          final rows = await txn.rawQuery(
            '''
            SELECT ci.* FROM contract_installments ci
            JOIN contracts c ON c.id = ci.contract_id
            WHERE ci.id = ? AND c.tenant_id = ?
              AND (c.status = 'Active'
                OR (c.status = 'Terminated'
                  AND DATE(ci.due_date) <= DATE(c.early_termination_date)))
              AND ci.status != 'Cancelled'
            ''',
            [requested['id'], tenantId],
          );
          if (rows.isEmpty)
            throw StateError(
              'القسط المحدد لا يتبع هذا المستأجر أو أن عقده غير نشط',
            );
          final current = rows.first;
          final linkedInvoices = await txn.query(
            'tax_invoices',
            columns: ['id'],
            where: 'installment_id = ?',
            whereArgs: [requested['id']],
            limit: 1,
          );
          if (linkedInvoices.isNotEmpty) {
            throw StateError(
              'القسط مرتبط بفاتورة؛ سجل القبض من وضع سداد الفاتورة',
            );
          }
          final total = (current['amount'] as num).toDouble();
          final oldPaid = (current['paid_amount'] as num?)?.toDouble() ?? 0;
          final newPaid = (requested['paid_amount'] as num?)?.toDouble();
          if (newPaid == null ||
              !_hasCentPrecision(newPaid) ||
              !_hasCentPrecision(oldPaid) ||
              newPaid <= oldPaid ||
              newPaid > total + 0.001) {
            throw StateError(
              'تغير رصيد القسط أو أن المبلغ يتجاوز المستحق؛ أعد تحميل الأقساط',
            );
          }
          final status = newPaid >= total - 0.001 ? 'Paid' : 'Partially Paid';
          if (requested['status'] != status)
            throw ArgumentError('حالة القسط لا تطابق المبلغ المدفوع');
          final allocatedAmount = newPaid - oldPaid;
          allocatedCents += (allocatedAmount * 100).round();
          verifiedUpdates.add({
            'id': requested['id'],
            'old_paid': oldPaid,
            'paid_amount': newPaid,
            'status': status,
            'allocated_amount': allocatedAmount,
          });
        }
      }
      if (allocatedCents != (amount * 100).round()) {
        throw ArgumentError('مجموع تخصيص الدفعة لا يساوي مبلغ السند');
      }

      final journalId = await txn.insert('journal_entries', {
        'entry_date': voucherDate,
        'description': journalDescription,
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': amount,
        'credit': 0.0,
        'description': receiptLineDescription,
      });
      final receiptParts = <({int? costCenterId, int amountMinor})>[];
      for (final installment in verifiedUpdates) {
        receiptParts.add((
          costCenterId: await _installmentCostCenterTx(txn, installment['id']),
          amountMinor: InternalTax.toMinorUnits(
            (installment['allocated_amount'] as num).toDouble(),
          ),
        ));
      }
      final principalMinor = receiptParts.fold<int>(
        0,
        (sum, part) => sum + part.amountMinor,
      );
      if (allocatedCents != principalMinor) {
        receiptParts.add((
          costCenterId: await _installmentCostCenterTx(
            txn,
            invoiceInstallmentId,
          ),
          amountMinor: allocatedCents - principalMinor,
        ));
      }
      for (final bucket in _groupMinorByCostCenter(receiptParts)) {
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': tenantAccountId,
          'debit': 0.0,
          'credit': (bucket['amount_minor'] as int) / 100.0,
          'cost_center_id': bucket['cost_center_id'],
          'description': receiptLineDescription,
        });
      }
      await _updateBalanceTx(txn, cashAccountId, amount, 0.0);
      await _updateBalanceTx(txn, tenantAccountId, 0.0, amount);

      final voucherId = await txn.insert('vouchers', {
        'voucher_type': 'قبض مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'party_name': tenantRows.first['name'],
        'journal_entry_id': journalId,
        'description': voucherDescription,
      });
      if (invoiceId != null) {
        await txn.insert('voucher_invoice_allocations', {
          'voucher_id': voucherId,
          'invoice_id': invoiceId,
          'amount': amount,
        });
      }
      for (final installment in verifiedUpdates) {
        await txn.insert('voucher_installment_allocations', {
          'voucher_id': voucherId,
          'installment_id': installment['id'],
          'amount': installment['allocated_amount'],
        });
      }
      final collectionCreatedBy = await _verifiedAuditUserId(txn);
      if (invoiceId != null) {
        await txn.insert('collection_allocations', {
          'voucher_id': voucherId,
          'installment_id': invoiceInstallmentId,
          'invoice_id': invoiceId,
          'amount_minor': allocatedCents,
          'rent_amount_minor': invoiceRentCents,
          'tax_amount_minor': invoiceTaxCents,
          'created_by': collectionCreatedBy,
        });
      } else {
        for (final installment in verifiedUpdates) {
          final installmentCents = InternalTax.toMinorUnits(
            (installment['allocated_amount'] as num).toDouble(),
          );
          await txn.insert('collection_allocations', {
            'voucher_id': voucherId,
            'installment_id': (installment['id'] as num).toInt(),
            'invoice_id': null,
            'amount_minor': installmentCents,
            'rent_amount_minor': installmentCents,
            'tax_amount_minor': 0,
            'created_by': collectionCreatedBy,
          });
        }
      }
      for (final installment in verifiedUpdates) {
        final changed = await txn.update(
          'contract_installments',
          {
            'paid_amount': installment['paid_amount'],
            'status': installment['status'],
          },
          where: 'id = ? AND paid_amount = ?',
          whereArgs: [installment['id'], installment['old_paid']],
        );
        if (changed != 1)
          throw StateError('تم تحديث القسط من عملية أخرى؛ أُلغيت المعاملة');
      }
      await _recordAuditTx(
        txn,
        action: 'TENANT_RECEIPT_POSTED',
        entityType: 'voucher',
        entityId: voucherId,
        amountMinor: InternalTax.toMinorUnits(amount),
        details: {
          'tenant_id': tenantId,
          'voucher_date': voucherDate,
          'journal_entry_id': journalId,
          'invoice_id': invoiceId,
          'installment_ids': [
            for (final installment in verifiedUpdates)
              (installment['id'] as num).toInt(),
          ],
        },
      );
      return voucherId;
    });
  }

  Map<String, int> _splitRefundMinorUnits({
    required int amountMinor,
    required int remainingRentMinor,
    required int remainingTaxMinor,
  }) {
    final remainingTotal = remainingRentMinor + remainingTaxMinor;
    if (amountMinor <= 0 ||
        remainingRentMinor < 0 ||
        remainingTaxMinor < 0 ||
        amountMinor > remainingTotal) {
      throw StateError('مبلغ الاسترداد يتجاوز الرصيد غير المسترد للمصدر');
    }
    if (amountMinor == remainingTotal) {
      return {'rent': remainingRentMinor, 'tax': remainingTaxMinor};
    }
    var rentRefund = (amountMinor * remainingRentMinor / remainingTotal)
        .round();
    rentRefund = rentRefund.clamp(0, remainingRentMinor).toInt();
    var taxRefund = amountMinor - rentRefund;
    if (taxRefund > remainingTaxMinor) {
      taxRefund = remainingTaxMinor;
      rentRefund = amountMinor - taxRefund;
    }
    if (rentRefund > remainingRentMinor ||
        taxRefund > remainingTaxMinor ||
        rentRefund + taxRefund != amountMinor) {
      throw StateError('تعذر توزيع مبلغ الاسترداد على الإيجار والضريبة بأمان');
    }
    return {'rent': rentRefund, 'tax': taxRefund};
  }

  Future<int?> _verifiedAuditUserId(DatabaseExecutor txn) async {
    final userId = PermissionRuntime.userId;
    if (userId == null) return null;
    final rows = await txn.query(
      'users',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isEmpty ? null : userId;
  }

  /// Resolves the acting user's id and display name for an audit snapshot.
  ///
  /// Returns nulls when no session is active or the user no longer exists; the
  /// caller still records the event so the trail never silently drops a posting.
  Future<({int? id, String? name})> _auditActor(DatabaseExecutor txn) async {
    final userId = PermissionRuntime.userId;
    if (userId == null) return (id: null, name: null);
    final rows = await txn.query(
      'users',
      columns: ['full_name', 'username'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return (id: null, name: null);
    final fullName = rows.first['full_name']?.toString().trim() ?? '';
    final username = rows.first['username']?.toString().trim() ?? '';
    return (id: userId, name: fullName.isNotEmpty ? fullName : username);
  }

  /// Writes one append-only audit row inside the caller's transaction.
  ///
  /// Must be called from within the same transaction as the financial change so
  /// that a rollback erases both the change and its trail. [amountMinor] is the
  /// primary monetary figure in minor units (cents); the remaining figures go
  /// into [details] and must never contain credentials or keys.
  Future<int> _recordAuditTx(
    DatabaseExecutor txn, {
    required String action,
    required String entityType,
    required int entityId,
    int? amountMinor,
    Map<String, Object?> details = const {},
    String? timestamp,
  }) async {
    final actor = await _auditActor(txn);
    return txn.insert('audit_logs', {
      'user_id': actor.id,
      'actor_name': actor.name,
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'amount_minor': amountMinor,
      'details': jsonEncode(details),
      'timestamp': timestamp ?? DateTime.now().toIso8601String(),
    });
  }

  /// Read-only, permission-gated audit trail query.
  ///
  /// Returns rows newest first. [fromDate]/[toDate] are inclusive calendar
  /// dates (YYYY-MM-DD); [action], [entityType] and [entityId] narrow the
  /// result. Only view permission on the dedicated `audit_logs` module grants
  /// access — no other module can read this table.
  Future<List<Map<String, dynamic>>> getAuditTrail({
    String? fromDate,
    String? toDate,
    String? action,
    String? entityType,
    int? entityId,
    String? search,
    int limit = 500,
  }) async {
    PermissionRuntime.require('audit_logs', AppPermissionAction.view);
    for (final value in [fromDate, toDate]) {
      if (value == null) continue;
      // DateTime.tryParse normalizes out-of-range parts (month 13 rolls into the
      // next year), so require an exact round-trip instead of trusting it.
      final parsed = DateTime.tryParse(value);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
          parsed == null ||
          parsed.toIso8601String().substring(0, 10) != value) {
        throw ArgumentError('تاريخ غير صحيح بصيغة YYYY-MM-DD');
      }
    }
    if (fromDate != null && toDate != null && fromDate.compareTo(toDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    if (limit < 1 || limit > 5000) {
      throw ArgumentError('حد الصفوف غير صالح');
    }
    final where = <String>[];
    final args = <Object?>[];
    if (fromDate != null) {
      where.add('a.timestamp >= ?');
      args.add(fromDate);
    }
    if (toDate != null) {
      where.add('a.timestamp < ?');
      args.add(
        DateTime.parse(
          toDate,
        ).add(const Duration(days: 1)).toIso8601String().substring(0, 10),
      );
    }
    if (action != null && action.trim().isNotEmpty) {
      where.add('a.action = ?');
      args.add(action.trim());
    }
    if (entityType != null && entityType.trim().isNotEmpty) {
      where.add('a.entity_type = ?');
      args.add(entityType.trim());
    }
    if (entityId != null) {
      where.add('a.entity_id = ?');
      args.add(entityId);
    }
    final term = search?.trim();
    if (term != null && term.isNotEmpty) {
      where.add(
        '(a.action LIKE ? OR a.details LIKE ? OR a.actor_name LIKE ? '
        'OR u.full_name LIKE ? OR u.username LIKE ?)',
      );
      args
        ..add('%$term%')
        ..add('%$term%')
        ..add('%$term%')
        ..add('%$term%')
        ..add('%$term%');
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        a.id,
        a.timestamp,
        a.action,
        a.entity_type,
        a.entity_id,
        a.amount_minor,
        a.details,
        a.user_id,
        COALESCE(a.actor_name, u.full_name, u.username, 'غير محدد') AS user_name
      FROM audit_logs a
      LEFT JOIN users u ON u.id = a.user_id
      $clause
      ORDER BY a.timestamp DESC, a.id DESC
      LIMIT ?
    ''',
      [...args, limit],
    );
  }

  /// Distinct action codes present in the trail, for the screen's filter menu.
  Future<List<String>> getAuditTrailActions() async {
    PermissionRuntime.require('audit_logs', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT action FROM audit_logs ORDER BY action',
    );
    return rows.map((row) => row['action'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> getRefundableCollectionAllocations(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        ca.id AS collection_allocation_id,
        ca.voucher_id AS receipt_voucher_id,
        v.voucher_date AS receipt_date,
        v.description AS receipt_description,
        cab.amount_minor / 100.0 AS collected_amount,
        (cab.amount_minor - cab.remaining_minor) / 100.0 AS refunded_amount,
        cab.remaining_minor / 100.0 AS remaining_amount,
        ca.installment_id,
        ca.invoice_id,
        ti.invoice_date,
        ti.total_amount AS invoice_total_amount,
        ci.due_date
      FROM collection_allocation_balances cab
      JOIN collection_allocations ca ON ca.id = cab.id
      JOIN vouchers v ON v.id = ca.voucher_id
      JOIN journal_entries je ON je.id = v.journal_entry_id AND je.is_posted = 1
      LEFT JOIN tax_invoices ti ON ti.id = ca.invoice_id
      LEFT JOIN contract_installments ci ON ci.id = ca.installment_id
      WHERE v.tenant_id = ?
        AND v.voucher_type = 'قبض مستأجر'
        AND cab.remaining_minor > 0
      ORDER BY v.voucher_date, v.id, ca.id
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingLegacyTenantPayments(
    int tenantId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        r.voucher_id,
        r.tenant_id,
        r.amount_minor / 100.0 AS amount,
        v.voucher_date,
        v.description,
        v.journal_entry_id,
        (
          SELECT a.name
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.journal_entry_id = v.journal_entry_id
            AND jl.debit > 0 AND jl.credit = 0
          LIMIT 1
        ) AS offset_account_name
      FROM legacy_tenant_payment_reviews r
      JOIN vouchers v ON v.id = r.voucher_id
      WHERE r.tenant_id = ? AND r.status = 'pending'
      ORDER BY v.voucher_date, v.id
      ''',
      [tenantId],
    );
  }

  Future<void> resolveLegacyTenantPaymentAsUnrelated({
    required int voucherId,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (reason.trim().isEmpty) {
      throw ArgumentError('اكتب سبب تصنيف سند الصرف القديم كعملية غير مرتبطة');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT r.tenant_id, r.amount_minor, r.status, v.voucher_type
        FROM legacy_tenant_payment_reviews r
        JOIN vouchers v ON v.id = r.voucher_id
        WHERE r.voucher_id = ?
        LIMIT 1
        ''',
        [voucherId],
      );
      if (rows.isEmpty ||
          rows.first['status'] != 'pending' ||
          rows.first['voucher_type'] != 'صرف مستأجر') {
        throw StateError('سند الصرف التاريخي غير موجود أو سبق تصنيفه');
      }
      final changed = await txn.update(
        'legacy_tenant_payment_reviews',
        {
          'status': 'unrelated',
          'reason': reason.trim(),
          'reviewed_by': await _verifiedAuditUserId(txn),
          'reviewed_at': DateTime.now().toIso8601String(),
        },
        where: "voucher_id = ? AND status = 'pending'",
        whereArgs: [voucherId],
      );
      if (changed != 1) throw StateError('تم تصنيف السند من مستخدم آخر');
      await _recordAuditTx(
        txn,
        action: 'LEGACY_TENANT_PAYMENT_MARKED_UNRELATED',
        entityType: 'voucher',
        entityId: voucherId,
        amountMinor: (rows.first['amount_minor'] as num).toInt(),
        details: {
          'voucher_id': voucherId,
          'tenant_id': rows.first['tenant_id'],
          'amount_minor': rows.first['amount_minor'],
          'reason': reason.trim(),
        },
      );
    });
  }

  Future<void> resolveLegacyTenantPaymentAsRefund({
    required int voucherId,
    required List<Map<String, int>> allocations,
    required String reason,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (reason.trim().isEmpty || allocations.isEmpty) {
      throw ArgumentError('سبب المطابقة ومصادر التحصيل مطلوبة');
    }
    final sourceIds = allocations
        .map((item) => item['collection_allocation_id'])
        .whereType<int>()
        .toList();
    if (sourceIds.length != allocations.length ||
        sourceIds.toSet().length != sourceIds.length ||
        allocations.any((item) => (item['amount_minor'] ?? 0) <= 0)) {
      throw ArgumentError('توزيع الاسترداد التاريخي غير صالح');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT
          r.tenant_id,
          r.amount_minor,
          r.status,
          v.voucher_type,
          v.voucher_date,
          v.journal_entry_id,
          v.description,
          v.amount
        FROM legacy_tenant_payment_reviews r
        JOIN vouchers v ON v.id = r.voucher_id
        WHERE r.voucher_id = ?
        LIMIT 1
        ''',
        [voucherId],
      );
      if (rows.isEmpty ||
          rows.first['status'] != 'pending' ||
          rows.first['voucher_type'] != 'صرف مستأجر') {
        throw StateError('سند الصرف التاريخي غير موجود أو سبق تصنيفه');
      }
      final legacy = rows.first;
      final tenantId = (legacy['tenant_id'] as num).toInt();
      final amountMinor = (legacy['amount_minor'] as num).toInt();
      final allocatedMinor = allocations.fold<int>(
        0,
        (sum, item) => sum + item['amount_minor']!,
      );
      if (allocatedMinor != amountMinor ||
          InternalTax.toMinorUnits((legacy['amount'] as num).toDouble()) !=
              amountMinor) {
        throw StateError(
          'يجب أن يساوي مجموع المطابقة كامل مبلغ سند الصرف القديم',
        );
      }
      final tenantRows = await txn.query(
        'tenants',
        columns: ['account_id'],
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty || tenantRows.first['account_id'] == null) {
        throw StateError('لا يوجد حساب ذمم صالح للمستأجر');
      }
      final tenantAccountId = (tenantRows.first['account_id'] as num).toInt();
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');

      final refundParts = <Map<String, int>>[];
      final rentRefundByInstallment = <int, int>{};
      for (final allocation in allocations) {
        final sourceId = allocation['collection_allocation_id']!;
        final sourceRows = await txn.rawQuery(
          '''
          SELECT
            cab.*,
            ca.voucher_id AS receipt_voucher_id,
            ca.installment_id,
            v.tenant_id AS receipt_tenant_id,
            v.voucher_type AS receipt_voucher_type,
            je.is_posted AS receipt_is_posted
          FROM collection_allocation_balances cab
          JOIN collection_allocations ca ON ca.id = cab.id
          JOIN vouchers v ON v.id = ca.voucher_id
          JOIN journal_entries je ON je.id = v.journal_entry_id
          WHERE ca.id = ?
          LIMIT 1
          ''',
          [sourceId],
        );
        if (sourceRows.isEmpty ||
            (sourceRows.first['receipt_tenant_id'] as num?)?.toInt() !=
                tenantId ||
            sourceRows.first['receipt_voucher_type'] != 'قبض مستأجر' ||
            (sourceRows.first['receipt_is_posted'] as num?)?.toInt() != 1) {
          throw StateError('مصدر التحصيل لا يخص المستأجر أو ليس قبضًا مرحّلًا');
        }
        final source = sourceRows.first;
        final rentRemaining = (source['remaining_rent_minor'] as num).toInt();
        final taxRemaining = (source['remaining_tax_minor'] as num).toInt();
        final amount = allocation['amount_minor']!;
        final split = _splitRefundMinorUnits(
          amountMinor: amount,
          remainingRentMinor: rentRemaining,
          remainingTaxMinor: taxRemaining,
        );
        refundParts.add({
          'source_id': sourceId,
          'amount': amount,
          'rent': split['rent']!,
          'tax': split['tax']!,
          'installment_id': (source['installment_id'] as num).toInt(),
        });
        final installmentId = (source['installment_id'] as num).toInt();
        rentRefundByInstallment.update(
          installmentId,
          (current) => current + split['rent']!,
          ifAbsent: () => split['rent']!,
        );
      }

      final journalId = (legacy['journal_entry_id'] as num?)?.toInt();
      if (journalId == null) {
        throw StateError(
          'سند الصرف القديم بلا قيد مرحّل؛ يلزم تصحيحه محاسبيًا أولًا',
        );
      }
      final originalLines = await txn.rawQuery(
        '''
        SELECT jl.account_id, jl.debit, jl.credit, a.account_type, a.code
        FROM journal_lines jl
        JOIN accounts a ON a.id = jl.account_id
        WHERE jl.journal_entry_id = ?
        ORDER BY jl.id
        ''',
        [journalId],
      );
      if (originalLines.length != 2) {
        throw StateError(
          'قيد سند الصرف القديم غير قياسي؛ لا يمكن إعادة تصنيفه تلقائيًا',
        );
      }
      final debitLines = originalLines.where((line) {
        final debit = (line['debit'] as num?)?.toDouble() ?? 0;
        final credit = (line['credit'] as num?)?.toDouble() ?? 0;
        return debit > 0 && credit == 0;
      }).toList();
      final creditLines = originalLines.where((line) {
        final debit = (line['debit'] as num?)?.toDouble() ?? 0;
        final credit = (line['credit'] as num?)?.toDouble() ?? 0;
        return credit > 0 && debit == 0;
      }).toList();
      final voucherAmount = (legacy['amount'] as num).toDouble();
      if (debitLines.length != 1 ||
          creditLines.length != 1 ||
          !_hasCentPrecision(voucherAmount) ||
          InternalTax.toMinorUnits(
                (debitLines.single['debit'] as num).toDouble(),
              ) !=
              amountMinor ||
          InternalTax.toMinorUnits(
                (creditLines.single['credit'] as num).toDouble(),
              ) !=
              amountMinor ||
          !(creditLines.single['code'] as String).startsWith('11')) {
        throw StateError(
          'قيد سند الصرف القديم غير متوازن أو لا يصرف من صندوق/بنك',
        );
      }
      final oldOffsetAccountId = (debitLines.single['account_id'] as num)
          .toInt();
      int? reclassificationJournalId;
      if (oldOffsetAccountId != tenantAccountId) {
        if (![
          'Expense',
          'Revenue',
        ].contains(debitLines.single['account_type'])) {
          throw StateError(
            'الحساب المقابل التاريخي التزام/حساب آخر؛ لا يمكن افتراض أنه رد إيجار. صنّف السند كصرف غير مرتبط أو راجعه يدويًا.',
          );
        }
        final correctionDescription =
            'إعادة تصنيف رد تاريخي مرتبط بسند قبض رقم ${refundParts.first['source_id']}';
        reclassificationJournalId = await txn.insert('journal_entries', {
          'entry_date': legacy['voucher_date'],
          'description': correctionDescription,
          'is_posted': 1,
        });
        await txn.insert('journal_lines', {
          'journal_entry_id': reclassificationJournalId,
          'account_id': tenantAccountId,
          'debit': voucherAmount,
          'credit': 0.0,
          'description': correctionDescription,
        });
        await txn.insert('journal_lines', {
          'journal_entry_id': reclassificationJournalId,
          'account_id': oldOffsetAccountId,
          'debit': 0.0,
          'credit': voucherAmount,
          'description': correctionDescription,
        });
        await _updateBalanceTx(txn, tenantAccountId, voucherAmount, 0.0);
        await _updateBalanceTx(txn, oldOffsetAccountId, 0.0, voucherAmount);
      }

      for (final part in refundParts) {
        await txn.insert('refund_allocations', {
          'refund_voucher_id': voucherId,
          'collection_allocation_id': part['source_id'],
          'amount_minor': part['amount'],
          'rent_amount_minor': part['rent'],
          'tax_amount_minor': part['tax'],
          'created_by': await _verifiedAuditUserId(txn),
        });
      }
      for (final entry in rentRefundByInstallment.entries) {
        if (entry.value == 0) continue;
        final installmentRows = await txn.query(
          'contract_installments',
          columns: ['amount', 'paid_amount'],
          where: 'id = ?',
          whereArgs: [entry.key],
          limit: 1,
        );
        if (installmentRows.isEmpty) {
          throw StateError('قسط مصدر الاسترداد غير موجود');
        }
        final totalCents = InternalTax.toMinorUnits(
          (installmentRows.first['amount'] as num).toDouble(),
        );
        final oldPaid =
            (installmentRows.first['paid_amount'] as num?)?.toDouble() ?? 0;
        final oldPaidCents = InternalTax.toMinorUnits(oldPaid);
        if (!_hasCentPrecision(oldPaid) || oldPaidCents < entry.value) {
          throw StateError(
            'المبلغ المدفوع المسجل على القسط أقل من الرد التاريخي',
          );
        }
        final newPaidCents = oldPaidCents - entry.value;
        final status = newPaidCents == 0
            ? 'Unpaid'
            : (newPaidCents >= totalCents ? 'Paid' : 'Partially Paid');
        final changed = await txn.update(
          'contract_installments',
          {'paid_amount': newPaidCents / 100.0, 'status': status},
          where: 'id = ? AND paid_amount = ?',
          whereArgs: [entry.key, oldPaid],
        );
        if (changed != 1)
          throw StateError('تغير القسط أثناء المطابقة؛ أُلغيت المعاملة');
      }
      final changed = await txn.update(
        'legacy_tenant_payment_reviews',
        {
          'status': 'refund',
          'reason': reason.trim(),
          'reviewed_by': await _verifiedAuditUserId(txn),
          'reviewed_at': DateTime.now().toIso8601String(),
          'reclassification_journal_entry_id': reclassificationJournalId,
        },
        where: "voucher_id = ? AND status = 'pending'",
        whereArgs: [voucherId],
      );
      if (changed != 1) throw StateError('تم تصنيف السند من مستخدم آخر');
      await _recordAuditTx(
        txn,
        action: 'LEGACY_TENANT_PAYMENT_RECONCILED_AS_REFUND',
        entityType: 'voucher',
        entityId: voucherId,
        amountMinor: amountMinor,
        details: {
          'voucher_id': voucherId,
          'tenant_id': tenantId,
          'amount_minor': amountMinor,
          'source_allocations': refundParts,
          'reason': reason.trim(),
          'reclassification_journal_entry_id': reclassificationJournalId,
        },
      );
    });
  }

  Future<int> insertTenantRefundVoucher({
    required int tenantId,
    required double amount,
    required String voucherDate,
    required int cashAccountId,
    required int collectionAllocationId,
    required String description,
    int? creditNoteId,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (amount <= 0 ||
        !_hasCentPrecision(amount) ||
        DateTime.tryParse(voucherDate) == null ||
        description.trim().isEmpty) {
      throw ArgumentError('المبلغ أو التاريخ أو البيان غير صحيح');
    }
    final refundCents = InternalTax.toMinorUnits(amount);
    final db = await instance.database;
    return db.transaction((txn) async {
      await _ensureNoPendingLegacyTenantPayments(txn, tenantId);
      await _ensureNoPendingLegacyInvoicesForTenant(txn, tenantId);
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty || tenantRows.first['account_id'] == null) {
        throw StateError('المستأجر أو حساب ذممه غير موجود');
      }
      final tenantAccountId = (tenantRows.first['account_id'] as num).toInt();
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      final cashAccount = await _requireLeafAccountTx(
        txn,
        cashAccountId,
        expectedType: 'Asset',
      );
      if (!(cashAccount['code'] as String).startsWith('11')) {
        throw ArgumentError('اختر حساب صندوق أو بنك صالحاً');
      }
      final sourceRows = await txn.rawQuery(
        '''
        SELECT
          cab.*,
          ca.voucher_id AS receipt_voucher_id,
          ca.installment_id,
          ca.invoice_id,
          v.tenant_id AS receipt_tenant_id,
          v.voucher_type AS receipt_voucher_type,
          v.journal_entry_id AS receipt_journal_id,
          je.is_posted AS receipt_is_posted
        FROM collection_allocation_balances cab
        JOIN collection_allocations ca ON ca.id = cab.id
        JOIN vouchers v ON v.id = ca.voucher_id
        JOIN journal_entries je ON je.id = v.journal_entry_id
        WHERE ca.id = ?
        LIMIT 1
        ''',
        [collectionAllocationId],
      );
      if (sourceRows.isEmpty ||
          (sourceRows.first['receipt_tenant_id'] as num?)?.toInt() !=
              tenantId ||
          sourceRows.first['receipt_voucher_type'] != 'قبض مستأجر' ||
          (sourceRows.first['receipt_is_posted'] as num?)?.toInt() != 1) {
        throw StateError('مصدر الاسترداد لا يخص المستأجر أو ليس قبضًا مرحّلًا');
      }
      final source = sourceRows.first;
      final remainingMinor = (source['remaining_minor'] as num).toInt();
      if (refundCents > remainingMinor) {
        throw StateError('المبلغ يتجاوز الجزء غير المسترد من سند القبض الأصلي');
      }
      final sourceRentRemaining = (source['remaining_rent_minor'] as num)
          .toInt();
      final sourceTaxRemaining = (source['remaining_tax_minor'] as num).toInt();
      Map<String, int> split;
      if (creditNoteId == null) {
        split = _splitRefundMinorUnits(
          amountMinor: refundCents,
          remainingRentMinor: sourceRentRemaining,
          remainingTaxMinor: sourceTaxRemaining,
        );
      } else {
        final invoiceId = (source['invoice_id'] as num?)?.toInt();
        if (invoiceId == null) {
          throw StateError('الإشعار الدائن يتطلب تخصيص قبض مرتبطًا بفاتورة');
        }
        final noteBalances = await _creditNoteRefundBalancesTx(txn, invoiceId);
        final matchingNotes = noteBalances.where(
          (row) => (row['id'] as num).toInt() == creditNoteId,
        );
        if (matchingNotes.isEmpty ||
            (matchingNotes.first['tenant_id'] as num?)?.toInt() != tenantId) {
          throw StateError('الإشعار الدائن لا يطابق فاتورة ومصدر قبض المستأجر');
        }
        final note = matchingNotes.first;
        final noteNetRemaining = (note['refundable_net_minor'] as num).toInt();
        final noteTaxRemaining = (note['refundable_tax_minor'] as num).toInt();
        final noteTotalRemaining = (note['refundable_minor'] as num).toInt();
        final refundableRent = math
            .min(sourceRentRemaining, noteNetRemaining)
            .toInt();
        final refundableTax = math
            .min(sourceTaxRemaining, noteTaxRemaining)
            .toInt();
        if (noteNetRemaining < 0 ||
            noteTaxRemaining < 0 ||
            noteTotalRemaining < 0 ||
            refundCents > noteTotalRemaining ||
            refundCents > refundableRent + refundableTax) {
          throw StateError('المبلغ يتجاوز الجزء غير المسترد من الإشعار الدائن');
        }
        split = _splitRefundMinorUnits(
          amountMinor: refundCents,
          remainingRentMinor: refundableRent,
          remainingTaxMinor: refundableTax,
        );
      }
      final sourceVoucherId = (source['receipt_voucher_id'] as num).toInt();
      final refundDescription = creditNoteId == null
          ? 'رد مرتبط بسند قبض رقم $sourceVoucherId - ${description.trim()}'
          : 'رد مرتبط بالإشعار الدائن $creditNoteId وبسند قبض رقم $sourceVoucherId - ${description.trim()}';
      final journalId = await txn.insert('journal_entries', {
        'entry_date': voucherDate,
        'description': refundDescription,
        'is_posted': 1,
      });
      final refundCostCenterId = await _installmentCostCenterTx(
        txn,
        source['installment_id'],
      );
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': amount,
        'credit': 0.0,
        'cost_center_id': refundCostCenterId,
        'description': refundDescription,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': cashAccountId,
        'debit': 0.0,
        'credit': amount,
        'description': refundDescription,
      });
      await _updateBalanceTx(txn, tenantAccountId, amount, 0.0);
      await _updateBalanceTx(txn, cashAccountId, 0.0, amount);
      final voucherId = await txn.insert('vouchers', {
        'voucher_type': 'صرف مستأجر',
        'voucher_date': voucherDate,
        'amount': amount,
        'tenant_id': tenantId,
        'party_name': tenantRows.first['name'],
        'journal_entry_id': journalId,
        'description': refundDescription,
      });
      await txn.insert('refund_allocations', {
        'refund_voucher_id': voucherId,
        'collection_allocation_id': collectionAllocationId,
        'credit_note_id': creditNoteId,
        'amount_minor': refundCents,
        'rent_amount_minor': split['rent'],
        'tax_amount_minor': split['tax'],
        'created_by': await _verifiedAuditUserId(txn),
      });
      final rentRefundMinor = split['rent']!;
      if (rentRefundMinor > 0) {
        final installmentId = (source['installment_id'] as num).toInt();
        final installmentRows = await txn.query(
          'contract_installments',
          columns: ['amount', 'paid_amount'],
          where: 'id = ?',
          whereArgs: [installmentId],
          limit: 1,
        );
        if (installmentRows.isEmpty) {
          throw StateError('قسط مصدر الاسترداد غير موجود');
        }
        final total = (installmentRows.first['amount'] as num).toDouble();
        final oldPaid =
            (installmentRows.first['paid_amount'] as num?)?.toDouble() ?? 0;
        final totalMinor = InternalTax.toMinorUnits(total);
        final oldPaidMinor = InternalTax.toMinorUnits(oldPaid);
        if (!_hasCentPrecision(total) ||
            !_hasCentPrecision(oldPaid) ||
            oldPaidMinor < rentRefundMinor ||
            oldPaidMinor > totalMinor) {
          throw StateError('رصيد القسط المدفوع غير متسق مع مصدر الاسترداد');
        }
        final newPaidMinor = oldPaidMinor - rentRefundMinor;
        final status = newPaidMinor == 0
            ? 'Unpaid'
            : (newPaidMinor >= totalMinor ? 'Paid' : 'Partially Paid');
        final changed = await txn.update(
          'contract_installments',
          {'paid_amount': newPaidMinor / 100.0, 'status': status},
          where: 'id = ? AND paid_amount = ?',
          whereArgs: [installmentId, oldPaid],
        );
        if (changed != 1)
          throw StateError('تغير القسط أثناء الاسترداد؛ أُلغيت المعاملة');
      }
      await _recordAuditTx(
        txn,
        action: 'TENANT_REFUND_POSTED',
        entityType: 'voucher',
        entityId: voucherId,
        amountMinor: refundCents,
        details: {
          'refund_voucher_id': voucherId,
          'tenant_id': tenantId,
          'collection_allocation_id': collectionAllocationId,
          'source_receipt_voucher_id': sourceVoucherId,
          'credit_note_id': creditNoteId,
          'amount_minor': refundCents,
          'rent_amount_minor': split['rent'],
          'tax_amount_minor': split['tax'],
        },
      );
      return voucherId;
    });
  }

  Future<List<Map<String, dynamic>>> getVoucherHistory({
    String? voucherType,
  }) async {
    PermissionRuntime.require('voucher_history', AppPermissionAction.view);
    final db = await instance.database;
    final where = voucherType == null ? '' : 'WHERE v.voucher_type = ?';
    final args = voucherType == null ? <Object?>[] : <Object?>[voucherType];
    return db.rawQuery('''
      SELECT
        v.id,
        v.voucher_type,
        v.voucher_date,
        v.amount,
        v.tenant_id,
        COALESCE(NULLIF(TRIM(v.party_name), ''), t.name, v.description, '') AS party_name,
        v.description,
        v.period_from_date,
        v.period_to_date,
        v.journal_entry_id
      FROM vouchers v
      LEFT JOIN tenants t ON t.id = v.tenant_id
      $where
      ORDER BY v.voucher_date DESC, v.id DESC
      ''', args);
  }

  Future<Map<String, dynamic>?> getVoucherDetails(int voucherId) async {
    PermissionRuntime.require('voucher_history', AppPermissionAction.view);
    return _loadVoucherDetails(voucherId);
  }

  Future<Map<String, dynamic>?> getTenantReceiptVoucherDetails(
    int voucherId,
  ) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.view);
    final db = await instance.database;
    final receipt = await db.query(
      'vouchers',
      columns: ['id'],
      where: "id = ? AND voucher_type = 'قبض مستأجر'",
      whereArgs: [voucherId],
      limit: 1,
    );
    if (receipt.isEmpty) return null;
    return _loadVoucherDetails(voucherId);
  }

  Future<Map<String, dynamic>?> _loadVoucherDetails(int voucherId) async {
    final db = await instance.database;
    final headers = await db.rawQuery(
      '''
      SELECT
        v.id,
        v.voucher_type,
        v.voucher_date,
        v.amount,
        v.tenant_id,
        COALESCE(NULLIF(TRIM(v.party_name), ''), t.name, v.description, '') AS party_name,
        t.name AS current_tenant_name,
        v.description,
        v.period_from_date,
        v.period_to_date,
        v.journal_entry_id
      FROM vouchers v
      LEFT JOIN tenants t ON t.id = v.tenant_id
      WHERE v.id = ?
      LIMIT 1
      ''',
      [voucherId],
    );
    if (headers.isEmpty) return null;

    final journalEntryId = headers.first['journal_entry_id'] as int?;
    final lines = journalEntryId == null
        ? <Map<String, Object?>>[]
        : await db.rawQuery(
            '''
            SELECT
              jl.id,
              jl.account_id,
              a.code AS account_code,
              a.name AS account_name,
              jl.debit,
              jl.credit,
              jl.description AS line_description,
              jl.cost_center_id,
              cc.name AS cost_center_name
            FROM journal_lines jl
            JOIN accounts a ON a.id = jl.account_id
            LEFT JOIN cost_centers cc ON cc.id = jl.cost_center_id
            WHERE jl.journal_entry_id = ?
            ORDER BY jl.id
            ''',
            [journalEntryId],
          );
    final installments = await db.rawQuery(
      '''
      SELECT
        via.installment_id,
        (SELECT COUNT(*) + 1 FROM contract_installments earlier
          WHERE earlier.contract_id = ci.contract_id
            AND (DATE(earlier.due_date) < DATE(ci.due_date)
              OR (DATE(earlier.due_date) = DATE(ci.due_date)
                AND earlier.id < ci.id))) AS installment_number,
        via.amount AS allocated_amount,
        ci.contract_id,
        ci.amount AS installment_amount,
        ci.paid_amount,
        ci.due_date,
        ci.status,
        p.name AS property_name,
        u.unit_number
      FROM voucher_installment_allocations via
      JOIN contract_installments ci ON ci.id = via.installment_id
      JOIN contracts c ON c.id = ci.contract_id
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE via.voucher_id = ?
      ORDER BY ci.due_date, ci.id
      ''',
      [voucherId],
    );
    final invoices = await db.rawQuery(
      '''
      SELECT
        via.invoice_id,
        via.amount AS allocated_amount,
        ti.contract_id,
        ti.installment_id,
        (SELECT COUNT(*) + 1 FROM contract_installments earlier
          WHERE earlier.contract_id = ci.contract_id
            AND (DATE(earlier.due_date) < DATE(ci.due_date)
              OR (DATE(earlier.due_date) = DATE(ci.due_date)
                AND earlier.id < ci.id))) AS installment_number,
        p.name AS property_name,
        u.unit_number,
        ti.invoice_date,
        ti.net_amount,
        ti.tax_amount,
        ti.total_amount,
        ti.tax_rate,
        ci.due_date
      FROM voucher_invoice_allocations via
      JOIN tax_invoices ti ON ti.id = via.invoice_id
      JOIN contract_installments ci ON ci.id = ti.installment_id
      JOIN contracts c ON c.id = ti.contract_id
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE via.voucher_id = ?
      ORDER BY ti.invoice_date, ti.id
      ''',
      [voucherId],
    );
    final ownerSettlementRows = await db.rawQuery(
      '''
      SELECT s.id AS settlement_id, s.owner_id, s.owner_account_id,
             owner_account.code AS owner_account_code,
             owner_account.name AS owner_account_name,
             s.cash_account_id, cash_account.code AS cash_account_code,
             cash_account.name AS cash_account_name,
             s.journal_entry_id, s.amount_minor, s.settlement_date,
             s.owner_name_snapshot, s.description, s.created_by, s.created_at
      FROM owner_settlements s
      JOIN accounts owner_account ON owner_account.id = s.owner_account_id
      JOIN accounts cash_account ON cash_account.id = s.cash_account_id
      WHERE s.voucher_id = ?
      LIMIT 1
      ''',
      [voucherId],
    );
    final refunds = await db.rawQuery(
      '''
      SELECT
        ra.collection_allocation_id,
        ra.amount_minor / 100.0 AS allocated_amount,
        ra.rent_amount_minor / 100.0 AS rent_refund_amount,
        ra.tax_amount_minor / 100.0 AS tax_refund_amount,
        ca.voucher_id AS source_receipt_voucher_id,
        source.voucher_date AS source_receipt_date,
        ca.installment_id,
        ca.invoice_id,
        ti.invoice_date,
        ti.total_amount AS invoice_total_amount,
        ci.due_date
      FROM refund_allocations ra
      JOIN collection_allocations ca ON ca.id = ra.collection_allocation_id
      JOIN vouchers source ON source.id = ca.voucher_id
      LEFT JOIN tax_invoices ti ON ti.id = ca.invoice_id
      LEFT JOIN contract_installments ci ON ci.id = ca.installment_id
      WHERE ra.refund_voucher_id = ?
      ORDER BY source.voucher_date, ca.id
      ''',
      [voucherId],
    );
    return {
      'voucher': headers.first,
      'journal_lines': lines,
      'installments': installments,
      'invoices': invoices,
      'refunds': refunds,
      'owner_settlement': ownerSettlementRows.isEmpty
          ? null
          : ownerSettlementRows.first,
    };
  }

  Future<int> insertTaxInvoice({
    required int contractId,
    required int tenantId,
    required int installmentId,
    required String invoiceDate,
    required double netAmount,
    required double taxAmount,
    required int revenueAccountId,
    required int? taxAccountId,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.post);
    if (netAmount <= 0 ||
        !_hasCentPrecision(netAmount) ||
        !_hasCentPrecision(taxAmount) ||
        taxAmount < 0 ||
        DateTime.tryParse(invoiceDate) == null) {
      throw ArgumentError('مبالغ أو تاريخ الفاتورة غير صحيح');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final contractRows = await txn.query(
        'contracts',
        where: "id = ? AND tenant_id = ? AND status = 'Active'",
        whereArgs: [contractId, tenantId],
      );
      if (contractRows.isEmpty) {
        throw StateError('العقد المحدد لا يتبع المستأجر المختار');
      }
      final installmentRows = await txn.rawQuery(
        '''
        SELECT ci.*
        FROM contract_installments ci
        JOIN contracts c ON c.id = ci.contract_id
        WHERE ci.id = ? AND c.id = ? AND c.tenant_id = ? AND c.status = 'Active'
        LIMIT 1
        ''',
        [installmentId, contractId, tenantId],
      );
      if (installmentRows.isEmpty) {
        throw StateError('القسط المحدد لا يتبع العقد أو المستأجر المختار');
      }
      final installment = installmentRows.first;
      final scheduledNet = (installment['amount'] as num).toDouble();
      final paidBeforeInvoice =
          (installment['paid_amount'] as num?)?.toDouble() ?? 0.0;
      if (!_hasCentPrecision(scheduledNet) ||
          !_hasCentPrecision(paidBeforeInvoice) ||
          paidBeforeInvoice < 0 ||
          paidBeforeInvoice > scheduledNet ||
          InternalTax.toMinorUnits(netAmount) !=
              InternalTax.toMinorUnits(scheduledNet)) {
        throw StateError('صافي الفاتورة يجب أن يطابق مبلغ القسط المسجل');
      }
      await _ensureNoPendingLegacyTenantPayments(txn, tenantId);
      await _ensureNoPendingLegacyInvoicesForTenant(txn, tenantId);
      final priorAllocations = await txn.rawQuery(
        '''
        SELECT
          ca.id AS collection_allocation_id,
          ca.voucher_id,
          ca.amount_minor / 100.0 AS amount,
          cab.remaining_minor,
          v.tenant_id,
          v.voucher_type
        FROM collection_allocations ca
        JOIN collection_allocation_balances cab ON cab.id = ca.id
        JOIN vouchers v ON v.id = ca.voucher_id
        WHERE ca.installment_id = ? AND ca.invoice_id IS NULL
        ORDER BY ca.id
        ''',
        [installmentId],
      );
      var priorAllocatedCents = 0;
      for (final allocation in priorAllocations) {
        final amount = (allocation['amount'] as num).toDouble();
        if (!_hasCentPrecision(amount) ||
            (allocation['tenant_id'] as num?)?.toInt() != tenantId ||
            allocation['voucher_type'] != 'قبض مستأجر') {
          throw StateError(
            'توجد تخصيصات قبض غير متسقة للقسط؛ راجعها يدويًا قبل إصدار الفاتورة',
          );
        }
        final remainingCents = (allocation['remaining_minor'] as num).toInt();
        if (remainingCents < 0 ||
            remainingCents > InternalTax.toMinorUnits(amount)) {
          throw StateError('رصيد تحصيل القسط بعد الردود غير متسق');
        }
        priorAllocatedCents += remainingCents;
      }
      if (priorAllocatedCents != InternalTax.toMinorUnits(paidBeforeInvoice)) {
        throw StateError(
          'لا يمكن مطابقة المدفوع السابق مع سندات قبض القسط؛ راجع السجل يدويًا قبل إصدار الفاتورة',
        );
      }
      final companyRows = await txn.query(
        'company_info',
        columns: ['tax_rate'],
        limit: 1,
      );
      final configuredTaxRate = companyRows.isEmpty
          ? 0.0
          : (companyRows.first['tax_rate'] as num?)?.toDouble() ?? 0.0;
      if (!InternalTax.isValidRate(configuredTaxRate)) {
        throw StateError(
          'نسبة الضريبة المحفوظة غير صالحة؛ راجع إعدادات المنشأة',
        );
      }
      final calculatedTaxAmount = InternalTax.calculate(
        netAmount,
        configuredTaxRate,
      );
      if (InternalTax.toMinorUnits(calculatedTaxAmount) !=
          InternalTax.toMinorUnits(taxAmount)) {
        throw ArgumentError(
          'مبلغ الضريبة لا يطابق نسبة المنشأة الحالية؛ أعد تحميل إعدادات الفاتورة',
        );
      }
      if (calculatedTaxAmount > 0 && taxAccountId == null) {
        throw ArgumentError('اختر حساب ضريبة تفصيليًا قبل إصدار الفاتورة');
      }
      final duplicates = await txn.query(
        'tax_invoices',
        where: 'installment_id = ?',
        whereArgs: [installmentId],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        throw StateError('صدرت فاتورة لهذا القسط مسبقًا');
      }
      final tenantRows = await txn.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [tenantId],
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر غير موجود');
      final tenantAccountId = tenantRows.first['account_id'] as int;
      await _requireLeafAccountTx(txn, tenantAccountId, expectedType: 'Asset');
      await _requireLeafAccountTx(
        txn,
        revenueAccountId,
        expectedType: 'Revenue',
      );
      if (calculatedTaxAmount > 0) {
        await _requireLeafAccountTx(
          txn,
          taxAccountId!,
          expectedType: 'Liability',
        );
      }

      final grossAmount = netAmount + calculatedTaxAmount;
      final invoiceCostCenterId = await _contractCostCenterTx(txn, contractId);
      final journalId = await txn.insert('journal_entries', {
        'entry_date': invoiceDate,
        'description': 'إثبات فاتورة ضريبية إيجار',
        'is_posted': 1,
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': tenantAccountId,
        'debit': grossAmount,
        'credit': 0.0,
        'description': 'استحقاق فاتورة إيجار',
      });
      await txn.insert('journal_lines', {
        'journal_entry_id': journalId,
        'account_id': revenueAccountId,
        'debit': 0.0,
        'credit': netAmount,
        'cost_center_id': invoiceCostCenterId,
        'description': 'إيراد إيجار',
      });
      if (calculatedTaxAmount > 0) {
        await txn.insert('journal_lines', {
          'journal_entry_id': journalId,
          'account_id': taxAccountId!,
          'debit': 0.0,
          'credit': calculatedTaxAmount,
          'description': 'ضريبة قيمة مضافة',
        });
      }
      await _updateBalanceTx(txn, tenantAccountId, grossAmount, 0.0);
      await _updateBalanceTx(txn, revenueAccountId, 0.0, netAmount);
      if (calculatedTaxAmount > 0) {
        await _updateBalanceTx(txn, taxAccountId!, 0.0, calculatedTaxAmount);
      }

      final invoiceId = await txn.insert('tax_invoices', {
        'contract_id': contractId,
        'installment_id': installmentId,
        'journal_entry_id': journalId,
        'invoice_date': invoiceDate,
        'net_amount': netAmount,
        'total_amount': grossAmount,
        'tax_amount': calculatedTaxAmount,
        'tax_rate': configuredTaxRate,
        'tax_account_id': calculatedTaxAmount > 0 ? taxAccountId : null,
      });
      for (final allocation in priorAllocations) {
        await txn.insert('voucher_invoice_allocations', {
          'voucher_id': allocation['voucher_id'],
          'invoice_id': invoiceId,
          'amount': allocation['amount'],
        });
        final linked = await txn.update(
          'collection_allocations',
          {'invoice_id': invoiceId},
          where: 'id = ? AND invoice_id IS NULL',
          whereArgs: [allocation['collection_allocation_id']],
        );
        if (linked != 1) {
          throw StateError(
            'تغير مصدر التحصيل أثناء إصدار الفاتورة؛ أُلغيت المعاملة',
          );
        }
      }
      await _recordAuditTx(
        txn,
        action: 'TAX_INVOICE_ISSUED',
        entityType: 'tax_invoice',
        entityId: invoiceId,
        amountMinor: InternalTax.toMinorUnits(grossAmount),
        details: {
          'contract_id': contractId,
          'installment_id': installmentId,
          'journal_entry_id': journalId,
          'invoice_date': invoiceDate,
          'net_amount_minor': InternalTax.toMinorUnits(netAmount),
          'tax_amount_minor': InternalTax.toMinorUnits(calculatedTaxAmount),
          'tax_rate': configuredTaxRate,
        },
      );
      return invoiceId;
    });
  }

  Future<void> cancelContract(int contractId, {required String reason}) async {
    PermissionRuntime.require('leasing', AppPermissionAction.edit);
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty) {
      throw ArgumentError('سبب الإلغاء الموثق مطلوب');
    }
    if (normalizedReason.length > 500) {
      throw ArgumentError('سبب الإلغاء يتجاوز الحد المسموح (500 حرف)');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final contractResult = await txn.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
        limit: 1,
      );
      if (contractResult.isEmpty) throw StateError('العقد غير موجود');
      if (contractResult.first['status'] == 'Cancelled') return;
      if (contractResult.first['status'] == 'Terminated') {
        throw StateError('العقد منتهٍ مبكرًا بالفعل؛ لا يمكن تحويله إلى إلغاء');
      }

      final liveSuccessors = await txn.query(
        'contracts',
        columns: ['id'],
        where: "renewed_from_contract_id = ? AND status != 'Cancelled'",
        whereArgs: [contractId],
        limit: 1,
      );
      if (liveSuccessors.isNotEmpty) {
        throw StateError('لا يمكن إلغاء عقد له عقد تجديد غير ملغى');
      }

      // Never erase a financial schedule or leave an invoice without reversal.
      final installments = await txn.query(
        'contract_installments',
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );
      bool hasPaid = installments.any(
        (inst) => (inst['paid_amount'] as num) > 0,
      );
      if (hasPaid) {
        throw StateError(
          'لا يمكن إلغاء العقد بشكل مباشر. يوجد دفعات مسددة، يتطلب عمل تسوية أو إشعار دائن.',
        );
      }
      final invoices = await txn.query(
        'tax_invoices',
        columns: ['id'],
        where: 'contract_id = ?',
        whereArgs: [contractId],
        limit: 1,
      );
      if (invoices.isNotEmpty) {
        throw StateError(
          'لا يمكن إلغاء العقد بعد إصدار فاتورة؛ أصدر إشعاراً دائناً أو تسوية موثقة أولاً.',
        );
      }
      final unitId = contractResult.first['unit_id'] as int;
      final cancelledAt = DateTime.now().toIso8601String();

      // Retain the original schedule for audit and mark it cancelled.
      await txn.update(
        'contract_installments',
        {'status': 'Cancelled'},
        where: 'contract_id = ?',
        whereArgs: [contractId],
      );

      await txn.update(
        'contracts',
        {
          'status': 'Cancelled',
          'cancellation_reason': normalizedReason,
          'cancelled_at': cancelledAt,
        },
        where: 'id = ?',
        whereArgs: [contractId],
      );
      await _recordAuditTx(
        txn,
        action: 'contract_cancelled',
        entityType: 'contract',
        entityId: contractId,
        details: {
          'contract_id': contractId,
          'unit_id': unitId,
          'reason': normalizedReason,
        },
        timestamp: cancelledAt,
      );

      final otherActiveContracts = await txn.rawQuery(
        '''
        SELECT COUNT(*) AS count FROM contracts
        WHERE unit_id = ? AND status = 'Active'
          AND DATE(end_date) >= DATE(?)
        ''',
        [unitId, cancelledAt],
      );
      if ((otherActiveContracts.first['count'] as int) == 0) {
        await txn.update(
          'units',
          {'status': 'شاغرة'},
          where: 'id = ?',
          whereArgs: [unitId],
        );
      }
    });
  }

  Future<void> terminateContractEarly(
    int contractId, {
    required String effectiveDate,
    required String reason,
  }) async {
    PermissionRuntime.require('leasing', AppPermissionAction.edit);
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 500) {
      throw ArgumentError('سبب الإنهاء مطلوب ولا يتجاوز 500 حرف');
    }
    final parsedDate = DateTime.tryParse(effectiveDate);
    if (parsedDate == null ||
        parsedDate.toIso8601String().substring(0, 10) != effectiveDate) {
      throw ArgumentError('تاريخ سريان الإنهاء غير صحيح');
    }
    final today = DateTime.now();
    final todayText = DateTime(
      today.year,
      today.month,
      today.day,
    ).toIso8601String().substring(0, 10);
    if (effectiveDate.compareTo(todayText) > 0) {
      throw ArgumentError('لا يمكن إتاحة الوحدة قبل تاريخ سريان الإنهاء');
    }

    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'contracts',
        where: 'id = ?',
        whereArgs: [contractId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('العقد غير موجود');
      final contract = rows.first;
      if (contract['status'] != 'Active') {
        throw StateError('لا يمكن إنهاء عقد غير نشط');
      }
      final startDate = contract['start_date']?.toString().substring(0, 10);
      final endDate = contract['end_date']?.toString().substring(0, 10);
      if (startDate == null ||
          endDate == null ||
          effectiveDate.compareTo(startDate) < 0 ||
          effectiveDate.compareTo(endDate) >= 0) {
        throw ArgumentError(
          'تاريخ الإنهاء يجب أن يقع ضمن مدة العقد وقبل نهايته',
        );
      }
      final unitId = (contract['unit_id'] as num).toInt();
      final overlappingContracts = await txn.rawQuery(
        '''
        SELECT id FROM contracts
        WHERE unit_id = ? AND id != ? AND status = 'Active'
          AND DATE(start_date) <= DATE(?) AND DATE(end_date) >= DATE(?)
        LIMIT 1
        ''',
        [unitId, contractId, todayText, todayText],
      );
      if (overlappingContracts.isNotEmpty) {
        throw StateError(
          'توجد وحدة مرتبطة بعقد نشط آخر؛ لم تُغيّر حالة الإشغال',
        );
      }

      final now = DateTime.now().toIso8601String();
      await txn.update(
        'contracts',
        {
          'status': 'Terminated',
          'early_termination_date': effectiveDate,
          'early_termination_reason': normalizedReason,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [contractId, 'Active'],
      );

      // Keep every historic installment and any invoice/allocation untouched.
      // Only unbilled future installments with no payment/allocation history are
      // marked cancelled; no refund, credit note, or journal entry is created.
      final futureRows = await txn.rawQuery(
        '''
        SELECT ci.id
        FROM contract_installments ci
        WHERE ci.contract_id = ?
          AND DATE(ci.due_date) > DATE(?)
          AND COALESCE(ci.paid_amount, 0) = 0
          AND NOT EXISTS (SELECT 1 FROM tax_invoices ti WHERE ti.installment_id = ci.id)
          AND NOT EXISTS (SELECT 1 FROM voucher_installment_allocations va WHERE va.installment_id = ci.id)
          AND NOT EXISTS (SELECT 1 FROM collection_allocations ca WHERE ca.installment_id = ci.id)
        ''',
        [contractId, effectiveDate],
      );
      for (final installment in futureRows) {
        await txn.update(
          'contract_installments',
          {'status': 'Cancelled'},
          where: 'id = ? AND status != ?',
          whereArgs: [installment['id'], 'Paid'],
        );
      }

      await _recordAuditTx(
        txn,
        action: 'contract_terminated_early',
        entityType: 'contract',
        entityId: contractId,
        details: {
          'contract_id': contractId,
          'unit_id': unitId,
          'effective_date': effectiveDate,
          'reason': normalizedReason,
          'future_unbilled_installments_cancelled': futureRows.length,
          'financial_history_preserved': true,
          'automatic_refund_or_journal_created': false,
        },
        timestamp: now,
      );

      final otherActiveContracts = await txn.rawQuery(
        '''
        SELECT COUNT(*) AS count FROM contracts
        WHERE unit_id = ? AND id != ? AND status = 'Active'
          AND DATE(end_date) >= DATE(?)
        ''',
        [unitId, contractId, todayText],
      );
      if ((otherActiveContracts.first['count'] as num).toInt() == 0) {
        await txn.update(
          'units',
          {'status': 'شاغرة'},
          where: 'id = ?',
          whereArgs: [unitId],
        );
      }
    });
  }

  // --- Reports & Alerts Queries ---
  // --- Reports & Alerts Queries ---

  Future<Map<String, dynamic>> getDashboardSummary() async {
    PermissionRuntime.require('dashboard', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM properties) AS properties_count,
        (SELECT COUNT(*) FROM units) AS units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'مؤجرة') AS rented_units_count,
        (SELECT COUNT(*) FROM units WHERE status = 'شاغرة') AS vacant_units_count,
        (SELECT COUNT(*) FROM tenants) AS tenants_count,
        (SELECT COUNT(*) FROM contracts
          WHERE status = 'Active'
            AND DATE(start_date) <= DATE('now', 'localtime')
            AND DATE(end_date) >= DATE('now', 'localtime'))
          AS active_contracts_count,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NOT NULL
            THEN MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0)
            ELSE MAX(ci.amount - ci.paid_amount, 0)
          END
        ), 0)
          FROM contract_installments ci
          JOIN contracts c ON c.id = ci.contract_id
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          LEFT JOIN (
            SELECT invoice_id, SUM(remaining_minor) / 100.0 AS paid_amount
            FROM collection_allocation_balances
            WHERE invoice_id IS NOT NULL
            GROUP BY invoice_id
          ) vip ON vip.invoice_id = ti.id
          WHERE c.status IN ('Active', 'Terminated')
            AND ci.status != 'Cancelled') AS outstanding_amount,
        (SELECT COUNT(*) FROM legacy_tenant_payment_reviews
          WHERE status = 'pending') AS pending_legacy_tenant_payment_count,
        (SELECT COALESCE(SUM(amount_minor), 0) / 100.0
          FROM legacy_tenant_payment_reviews
          WHERE status = 'pending') AS pending_legacy_tenant_payment_amount,
        (SELECT COUNT(*) FROM legacy_invoice_reviews
          WHERE status = 'pending') AS pending_legacy_invoice_count,
        (SELECT COALESCE(SUM(ti.total_amount), 0)
          FROM legacy_invoice_reviews r
          JOIN tax_invoices ti ON ti.id = r.invoice_id
          WHERE r.status = 'pending') AS pending_legacy_invoice_amount
    ''');
    return rows.first;
  }

  @Deprecated(
    'Use getLedgerAccountStatement for a consistent statement result.',
  )
  Future<double> getAccountOpeningBalance(
    int accountId,
    String startDate,
  ) async {
    final report = await getLedgerAccountStatement(
      accountId: accountId,
      startDate: startDate,
      endDate: startDate,
    );
    return report.openingBalance;
  }

  @Deprecated(
    'Use getLedgerAccountStatement for a consistent statement result.',
  )
  Future<List<Map<String, dynamic>>> getAccountStatement(
    int accountId,
    String startDate,
    String endDate,
  ) async {
    final report = await getLedgerAccountStatement(
      accountId: accountId,
      startDate: startDate,
      endDate: endDate,
    );
    return report.lines
        .map(
          (line) => {
            'date': line.date,
            'voucher_no': line.journalEntryId,
            'description': line.description,
            'debit': line.debit,
            'credit': line.credit,
            'running_balance': line.runningBalance,
          },
        )
        .toList(growable: false);
  }

  Future<AccountStatementReport> getLedgerAccountStatement({
    required int accountId,
    required String startDate,
    required String endDate,
    int? expectedTenantId,
    int? expectedOwnerId,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    if (accountId <= 0) throw ArgumentError('معرف الحساب غير صحيح');
    if (expectedTenantId != null && expectedOwnerId != null) {
      throw ArgumentError('لا يمكن ربط كشف واحد بمستأجر ومالك معًا');
    }

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final parsed = DateTime(year, month, day);
      return parsed.year == year && parsed.month == month && parsed.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final endDateParts = endDate.split('-').map(int.parse).toList();
    final exclusiveEndDate = DateTime.utc(
      endDateParts[0],
      endDateParts[1],
      endDateParts[2] + 1,
    ).toIso8601String().substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      if (expectedTenantId != null) {
        final tenantRows = await txn.query(
          'tenants',
          columns: ['id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
          limit: 2,
        );
        if (tenantRows.length != 1 ||
            tenantRows.single['id'] != expectedTenantId) {
          throw StateError(
            'حساب المستأجر غير مرتبط به حصريًا؛ راجع ارتباطات الحساب',
          );
        }
      } else if (expectedOwnerId != null) {
        final ownerRows = await txn.query(
          'owners',
          columns: ['id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
          limit: 2,
        );
        if (ownerRows.length != 1 ||
            ownerRows.single['id'] != expectedOwnerId) {
          throw StateError(
            'حساب المالك غير مرتبط به حصريًا؛ راجع ارتباطات الحساب',
          );
        }
      }
      final accounts = await txn.rawQuery(
        '''
        SELECT a.id, a.code, a.name, a.account_type
        FROM accounts a
        WHERE a.id = ?
          AND a.parent_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM accounts child WHERE child.parent_id = a.id
          )
        LIMIT 1
        ''',
        [accountId],
      );
      if (accounts.isEmpty) {
        throw StateError(
          'الحساب غير موجود أو حساب تجميعي وليس حسابًا تفصيليًا',
        );
      }
      final account = accounts.single;
      final accountType = account['account_type']?.toString() ?? '';
      if (expectedTenantId != null && accountType != 'Asset') {
        throw StateError('حساب ذمم المستأجر المحدد ليس من نوع الأصول');
      }
      if (expectedOwnerId != null && accountType != 'Liability') {
        throw StateError('حساب المالك المحدد ليس من نوع الالتزامات');
      }
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      const supportedTypes = {
        'Asset',
        'Liability',
        'Equity',
        'Revenue',
        'Expense',
      };
      if (!supportedTypes.contains(accountType)) {
        throw StateError('نوع الحساب غير معرف؛ لا يمكن تحديد طبيعته في الكشف');
      }
      final debitNormal = accountType == 'Asset' || accountType == 'Expense';

      final openingRows = await txn.rawQuery(
        '''
        SELECT
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = ? AND je.entry_date < ? AND je.is_posted = 1
        ''',
        [accountId, startDate],
      );
      final openingDebitMinor = (openingRows.single['debit_minor'] as num)
          .toInt();
      final openingCreditMinor = (openingRows.single['credit_minor'] as num)
          .toInt();
      var runningBalanceMinor = debitNormal
          ? openingDebitMinor - openingCreditMinor
          : openingCreditMinor - openingDebitMinor;
      final openingBalance = runningBalanceMinor / 100.0;

      final movementRows = await txn.rawQuery(
        '''
        SELECT
          je.entry_date AS date,
          je.id AS journal_entry_id,
          jl.description AS description,
          CAST(ROUND(jl.debit * 100) AS INTEGER) AS debit_minor,
          CAST(ROUND(jl.credit * 100) AS INTEGER) AS credit_minor
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = ?
          AND je.entry_date >= ?
          AND je.entry_date < ?
          AND je.is_posted = 1
        ORDER BY je.entry_date ASC, je.id ASC, jl.id ASC
        ''',
        [accountId, startDate, exclusiveEndDate],
      );

      var totalDebitMinor = 0;
      var totalCreditMinor = 0;
      final lines = <AccountStatementLine>[];
      for (final row in movementRows) {
        final debitMinor = (row['debit_minor'] as num).toInt();
        final creditMinor = (row['credit_minor'] as num).toInt();
        totalDebitMinor += debitMinor;
        totalCreditMinor += creditMinor;
        runningBalanceMinor += debitNormal
            ? debitMinor - creditMinor
            : creditMinor - debitMinor;
        lines.add(
          AccountStatementLine(
            date: row['date']?.toString() ?? '',
            journalEntryId: (row['journal_entry_id'] as num).toInt(),
            description: row['description']?.toString() ?? '',
            debit: debitMinor / 100.0,
            credit: creditMinor / 100.0,
            runningBalance: runningBalanceMinor / 100.0,
          ),
        );
      }
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return AccountStatementReport(
        accountId: accountId,
        accountCode: account['code']?.toString() ?? '',
        accountName: account['name']?.toString() ?? '',
        accountType: accountType,
        currency: currency,
        startDate: startDate,
        endDate: endDate,
        openingBalance: openingBalance,
        totalDebit: totalDebitMinor / 100.0,
        totalCredit: totalCreditMinor / 100.0,
        closingBalance: runningBalanceMinor / 100.0,
        lines: lines,
      );
    });
  }

  /// Read-only statement of posted lines attributed to [propertyId].
  ///
  /// Only lines whose cost centre is assigned to this property and to no other
  /// property are counted. Anything else is reported as a gap, never guessed.
  Future<PropertyStatementReport> getPropertyStatement({
    required int propertyId,
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    if (propertyId <= 0) throw ArgumentError('معرف العقار غير صحيح');

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final parsed = DateTime(year, month, day);
      return parsed.year == year && parsed.month == month && parsed.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final endDateParts = endDate.split('-').map(int.parse).toList();
    final exclusiveEndDate = DateTime.utc(
      endDateParts[0],
      endDateParts[1],
      endDateParts[2] + 1,
    ).toIso8601String().substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final propertyRows = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.cost_center_id, o.name AS owner_name
        FROM properties p
        LEFT JOIN owners o ON o.id = p.owner_id
        WHERE p.id = ?
        LIMIT 1
        ''',
        [propertyId],
      );
      if (propertyRows.isEmpty) throw StateError('العقار المطلوب غير موجود');
      final property = propertyRows.single;
      final costCenterId = (property['cost_center_id'] as num?)?.toInt();

      var costCenterCode = '';
      var costCenterName = '';
      var costCenterIsShared = false;
      if (costCenterId != null) {
        final centerRows = await txn.query(
          'cost_centers',
          columns: ['code', 'name'],
          where: 'id = ?',
          whereArgs: [costCenterId],
          limit: 1,
        );
        if (centerRows.isNotEmpty) {
          costCenterCode = centerRows.single['code']?.toString() ?? '';
          costCenterName = centerRows.single['name']?.toString() ?? '';
        }
        final sharers = await txn.rawQuery(
          'SELECT COUNT(*) AS total FROM properties WHERE cost_center_id = ?',
          [costCenterId],
        );
        costCenterIsShared = ((sharers.single['total'] as num).toInt()) > 1;
      }

      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;

      final gaps = <PropertyStatementGap>[];

      /// Counts posted lines in the period matching [where] into a gap.
      Future<void> recordGap(
        PropertyStatementGapReason reason,
        String where,
        List<Object?> args,
      ) async {
        final rows = await txn.rawQuery(
          '''
          SELECT
            COUNT(*) AS line_count,
            CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
              AS debit_minor,
            CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
              AS credit_minor
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.journal_entry_id
          WHERE je.is_posted = 1
            AND je.entry_date >= ?
            AND je.entry_date < ?
            AND $where
          ''',
          [startDate, exclusiveEndDate, ...args],
        );
        final row = rows.single;
        final lineCount = (row['line_count'] as num).toInt();
        if (lineCount == 0) return;
        gaps.add(
          PropertyStatementGap(
            reason: reason,
            lineCount: lineCount,
            debitMinor: (row['debit_minor'] as num).toInt(),
            creditMinor: (row['credit_minor'] as num).toInt(),
          ),
        );
      }

      final lines = <PropertyStatementLine>[];
      var openingBalanceMinor = 0;
      var totalDebitMinor = 0;
      var totalCreditMinor = 0;
      var closingBalanceMinor = 0;

      // Only a centre owned by this property alone may carry its lines.
      if (costCenterId != null && !costCenterIsShared) {
        final openingRows = await txn.rawQuery(
          '''
          SELECT
            CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
              AS debit_minor,
            CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
              AS credit_minor
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.journal_entry_id
          WHERE jl.cost_center_id = ?
            AND je.is_posted = 1
            AND je.entry_date < ?
          ''',
          [costCenterId, startDate],
        );
        openingBalanceMinor =
            (openingRows.single['debit_minor'] as num).toInt() -
            (openingRows.single['credit_minor'] as num).toInt();
        var runningBalanceMinor = openingBalanceMinor;

        final movementRows = await txn.rawQuery(
          '''
          SELECT
            je.entry_date AS date,
            je.id AS journal_entry_id,
            jl.id AS journal_line_id,
            a.code AS account_code,
            a.name AS account_name,
            jl.description AS description,
            CAST(ROUND(jl.debit * 100) AS INTEGER) AS debit_minor,
            CAST(ROUND(jl.credit * 100) AS INTEGER) AS credit_minor
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.journal_entry_id
          JOIN accounts a ON a.id = jl.account_id
          WHERE jl.cost_center_id = ?
            AND je.is_posted = 1
            AND je.entry_date >= ?
            AND je.entry_date < ?
          ORDER BY je.entry_date ASC, je.id ASC, jl.id ASC
          ''',
          [costCenterId, startDate, exclusiveEndDate],
        );

        for (final row in movementRows) {
          final debitMinor = (row['debit_minor'] as num).toInt();
          final creditMinor = (row['credit_minor'] as num).toInt();
          totalDebitMinor += debitMinor;
          totalCreditMinor += creditMinor;
          runningBalanceMinor += debitMinor - creditMinor;
          lines.add(
            PropertyStatementLine(
              date: row['date']?.toString() ?? '',
              journalEntryId: (row['journal_entry_id'] as num).toInt(),
              journalLineId: (row['journal_line_id'] as num).toInt(),
              accountCode: row['account_code']?.toString() ?? '',
              accountName: row['account_name']?.toString() ?? '',
              description: row['description']?.toString() ?? '',
              debitMinor: debitMinor,
              creditMinor: creditMinor,
              runningBalanceMinor: runningBalanceMinor,
            ),
          );
        }
        closingBalanceMinor = runningBalanceMinor;
      } else if (costCenterId == null) {
        await recordGap(
          PropertyStatementGapReason.propertyWithoutCostCenter,
          'jl.cost_center_id IS NULL',
          const [],
        );
        return _buildPropertyStatementReport(
          property: property,
          propertyId: propertyId,
          costCenterId: null,
          costCenterCode: costCenterCode,
          costCenterName: costCenterName,
          currency: currency,
          startDate: startDate,
          endDate: endDate,
          lines: const [],
          gaps: gaps,
          openingBalanceMinor: 0,
          totalDebitMinor: 0,
          totalCreditMinor: 0,
          closingBalanceMinor: 0,
        );
      } else {
        await recordGap(
          PropertyStatementGapReason.sharedCostCenter,
          'jl.cost_center_id = ?',
          [costCenterId],
        );
      }

      // Lines with no centre can never be tied to this property. Disclose them
      // so the reader knows the report is not silently dropping amounts.
      await recordGap(
        PropertyStatementGapReason.unassignedCostCenter,
        'jl.cost_center_id IS NULL',
        const [],
      );

      PermissionRuntime.require('reports', AppPermissionAction.view);
      return _buildPropertyStatementReport(
        property: property,
        propertyId: propertyId,
        costCenterId: costCenterId,
        costCenterCode: costCenterCode,
        costCenterName: costCenterName,
        currency: currency,
        startDate: startDate,
        endDate: endDate,
        lines: lines,
        gaps: gaps,
        openingBalanceMinor: openingBalanceMinor,
        totalDebitMinor: totalDebitMinor,
        totalCreditMinor: totalCreditMinor,
        closingBalanceMinor: closingBalanceMinor,
      );
    });
  }

  PropertyStatementReport _buildPropertyStatementReport({
    required Map<String, dynamic> property,
    required int propertyId,
    required int? costCenterId,
    required String costCenterCode,
    required String costCenterName,
    required String currency,
    required String startDate,
    required String endDate,
    required List<PropertyStatementLine> lines,
    required List<PropertyStatementGap> gaps,
    required int openingBalanceMinor,
    required int totalDebitMinor,
    required int totalCreditMinor,
    required int closingBalanceMinor,
  }) => PropertyStatementReport(
    propertyId: propertyId,
    propertyName: property['name']?.toString() ?? '',
    ownerName: property['owner_name']?.toString() ?? '',
    costCenterId: costCenterId,
    costCenterCode: costCenterCode,
    costCenterName: costCenterName,
    currency: currency,
    startDate: startDate,
    endDate: endDate,
    openingBalanceMinor: openingBalanceMinor,
    totalDebitMinor: totalDebitMinor,
    totalCreditMinor: totalCreditMinor,
    closingBalanceMinor: closingBalanceMinor,
    lines: lines,
    gaps: gaps,
  );

  Future<FinancialPositionReport> getFinancialPositionReport({
    required String asOfDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(asOfDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    final dateParts = asOfDate.split('-').map(int.tryParse).toList();
    if (dateParts.any((part) => part == null)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    final year = dateParts[0]!;
    final month = dateParts[1]!;
    final day = dateParts[2]!;
    if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    final parsedDate = DateTime.utc(year, month, day);
    if (parsedDate.year != year ||
        parsedDate.month != month ||
        parsedDate.day != day) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    final exclusiveEndDate = parsedDate
        .add(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final accountRows = await txn.rawQuery(
        '''
        WITH ledger_totals AS (
          SELECT
            jl.account_id,
            CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
              AS debit_minor,
            CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
              AS credit_minor
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.journal_entry_id
          WHERE je.is_posted = 1 AND je.entry_date < ?
          GROUP BY jl.account_id
        )
        SELECT
          totals.account_id AS account_id,
          COALESCE(NULLIF(TRIM(a.code), ''), '—') AS account_code,
          COALESCE(
            NULLIF(TRIM(a.name), ''),
            'حساب غير موجود (#' || totals.account_id || ')'
          ) AS account_name,
          COALESCE(a.account_type, 'Unclassified') AS account_type,
          totals.debit_minor AS debit_minor,
          totals.credit_minor AS credit_minor
        FROM ledger_totals totals
        LEFT JOIN accounts a ON a.id = totals.account_id
        WHERE totals.debit_minor != 0 OR totals.credit_minor != 0
        ORDER BY account_code COLLATE NOCASE, totals.account_id
        ''',
        [exclusiveEndDate],
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return FinancialPositionReport(
        asOfDate: asOfDate,
        currency: currency,
        rows: accountRows
            .map(
              (row) => FinancialPositionAccountRow(
                accountId: (row['account_id'] as num).toInt(),
                accountCode: row['account_code']?.toString() ?? '—',
                accountName: row['account_name']?.toString() ?? 'غير محدد',
                accountType: row['account_type']?.toString() ?? 'Unclassified',
                debitMinor: (row['debit_minor'] as num).toInt(),
                creditMinor: (row['credit_minor'] as num).toInt(),
              ),
            )
            .toList(growable: false),
      );
    });
  }

  Future<AccountBalanceReconciliationReport>
  getAccountBalanceReconciliationReport() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final rows = await txn.rawQuery('''
        WITH RECURSIVE account_tree(root_account_id, member_account_id) AS (
          SELECT id, id FROM accounts
          UNION
          SELECT tree.root_account_id, child.id
          FROM account_tree tree
          JOIN accounts child ON child.parent_id = tree.member_account_id
        ), ledger_balances AS (
          SELECT
            tree.root_account_id,
            CAST(ROUND(COALESCE(SUM(CASE
              WHEN journal.is_posted = 1
               AND root.account_type IN ('Asset', 'Expense')
              THEN COALESCE(line.debit, 0) - COALESCE(line.credit, 0)
              WHEN journal.is_posted = 1
               AND root.account_type IN ('Liability', 'Equity', 'Revenue')
              THEN COALESCE(line.credit, 0) - COALESCE(line.debit, 0)
              ELSE 0
            END), 0) * 100) AS INTEGER) AS ledger_balance_minor
          FROM account_tree tree
          JOIN accounts root ON root.id = tree.root_account_id
          LEFT JOIN journal_lines line
            ON line.account_id = tree.member_account_id
          LEFT JOIN journal_entries journal
            ON journal.id = line.journal_entry_id
          GROUP BY tree.root_account_id
        )
        SELECT
          account.id AS account_id,
          account.code AS account_code,
          account.name AS account_name,
          account.account_type AS account_type,
          CAST(ROUND(COALESCE(account.balance, 0) * 100) AS INTEGER)
            AS stored_balance_minor,
          COALESCE(ledger.ledger_balance_minor, 0) AS ledger_balance_minor
        FROM accounts account
        LEFT JOIN ledger_balances ledger
          ON ledger.root_account_id = account.id
        ORDER BY account.code COLLATE NOCASE, account.id
      ''');
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return AccountBalanceReconciliationReport(
        rows: rows.map(AccountBalanceReconciliationRow.fromMap).toList(),
      );
    });
  }

  Future<FinancialCloseReadinessReport> getFinancialCloseReadinessReport({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime.utc(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final exclusiveEndDate = _exclusiveDateBoundAfter(endDate);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final unpostedRows = await txn.rawQuery(
        '''
        SELECT
          je.id AS journal_entry_id,
          je.entry_date AS entry_date,
          COALESCE(je.description, '') AS description,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor,
          COUNT(jl.id) AS line_count
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        WHERE COALESCE(je.is_posted, 0) != 1
          AND je.entry_date >= ? AND je.entry_date < ?
        GROUP BY je.id, je.entry_date, je.description
        ORDER BY je.entry_date, je.id
        ''',
        [startDate, exclusiveEndDate],
      );
      final unbalancedRows = await txn.rawQuery(
        '''
        SELECT
          je.id AS journal_entry_id,
          je.entry_date AS entry_date,
          COALESCE(je.description, '') AS description,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor,
          COUNT(jl.id) AS line_count
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        WHERE je.is_posted = 1
          AND je.entry_date >= ? AND je.entry_date < ?
        GROUP BY je.id, je.entry_date, je.description
        HAVING COUNT(jl.id) = 0
          OR CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
             != CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
        ORDER BY je.entry_date, je.id
        ''',
        [startDate, exclusiveEndDate],
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      final invoiceReport = await _loadInvoiceLedgerReconciliationReport(
        db: txn,
        startDate: startDate,
        endDate: endDate,
        exclusiveEndDate: exclusiveEndDate,
        requireReportPermission: false,
      );
      final internalReconciliation =
          await InternalSubledgerReconciliationService.load(
            db: txn,
            startDate: startDate,
            endDate: endDate,
            exclusiveEndDate: exclusiveEndDate,
            currency: currency,
            invoices: invoiceReport,
          );
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return FinancialCloseReadinessReport(
        startDate: startDate,
        endDate: endDate,
        currency: currency,
        unpostedEntries: unpostedRows
            .map(
              (row) => FinancialCloseEntryIssue.fromMap(row, isPosted: false),
            )
            .toList(growable: false),
        unbalancedPostedEntries: unbalancedRows
            .map((row) => FinancialCloseEntryIssue.fromMap(row, isPosted: true))
            .toList(growable: false),
        internalReconciliation: internalReconciliation,
      );
    });
  }

  Future<List<AccountingPeriod>> getAccountingPeriods() async {
    PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
    final db = await instance.database;
    final rows = await db.query(
      'accounting_periods',
      orderBy: 'start_date DESC, id DESC',
    );
    PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
    return rows.map(AccountingPeriod.fromMap).toList(growable: false);
  }

  Future<List<AccountingPeriodEvent>> getAccountingPeriodEvents(
    int periodId,
  ) async {
    PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
    if (periodId <= 0) throw ArgumentError('رقم الفترة غير صالح');
    final db = await instance.database;
    final rows = await db.query(
      'accounting_period_events',
      where: 'period_id = ?',
      whereArgs: [periodId],
      orderBy: 'id ASC',
    );
    PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
    return rows.map(AccountingPeriodEvent.fromMap).toList(growable: false);
  }

  Future<AccountingPeriod> createAccountingPeriod({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('accounting_periods', AppPermissionAction.add);
    if (!_isIsoCalendarDate(startDate) || !_isIsoCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('accounting_periods', AppPermissionAction.add);
      final actor = await _requireAccountingPeriodActorTx(txn);
      PermissionRuntime.require('accounting_periods', AppPermissionAction.add);
      final periodId = await txn.insert('accounting_periods', {
        'start_date': startDate,
        'end_date': endDate,
        'status': 'open',
        'created_by_user_id': actor.id,
      });
      final timestamp = DateTime.now().toIso8601String();
      await _appendAccountingPeriodEventTx(
        txn,
        periodId: periodId,
        action: 'created',
        actor: actor,
        timestamp: timestamp,
      );
      await _recordAuditTx(
        txn,
        action: 'ACCOUNTING_PERIOD_CREATED',
        entityType: 'accounting_period',
        entityId: periodId,
        details: {'start_date': startDate, 'end_date': endDate},
        timestamp: timestamp,
      );
      final rows = await txn.query(
        'accounting_periods',
        where: 'id = ?',
        whereArgs: [periodId],
        limit: 1,
      );
      return AccountingPeriod.fromMap(rows.single);
    });
  }

  Future<AccountingPeriodReadiness> getAccountingPeriodReadiness(
    int periodId,
  ) async {
    PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
    if (periodId <= 0) throw ArgumentError('رقم الفترة غير صالح');
    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
      final period = await _accountingPeriodTx(txn, periodId);
      final report = await _financialCloseReadinessTx(
        txn,
        startDate: period.startDate,
        endDate: period.endDate,
      );
      PermissionRuntime.require('accounting_periods', AppPermissionAction.view);
      return AccountingPeriodReadiness(period: period, report: report);
    });
  }

  Future<void> lockAccountingPeriod(int periodId, {String reason = ''}) async {
    PermissionRuntime.require(
      'accounting_periods',
      AppPermissionAction.lockPeriod,
    );
    if (periodId <= 0) throw ArgumentError('رقم الفترة غير صالح');
    final normalizedReason = reason.trim();
    if (normalizedReason.length > 500) {
      throw ArgumentError('سبب القفل لا يتجاوز 500 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.lockPeriod,
      );
      final actor = await _requireAccountingPeriodActorTx(txn);
      final period = await _accountingPeriodTx(txn, periodId);
      if (period.status != 'open') {
        throw StateError('لا يمكن قفل فترة ليست مفتوحة');
      }
      // Re-run the readiness checks inside this same transaction. A report
      // loaded earlier in the UI is informational and cannot authorize a lock.
      final report = await _financialCloseReadinessTx(
        txn,
        startDate: period.startDate,
        endDate: period.endDate,
      );
      if (report.hasBlockingIssues) {
        throw StateError(
          'توجد قيود أو استثناءات مطابقة داخلية تحتاج معالجة يدوية؛ راجع الجاهزية أولًا',
        );
      }
      if (report.requiresManualReviewAcknowledgement &&
          normalizedReason.isEmpty) {
        throw StateError(
          'توجد استثناءات تتطلب إقرار مراجعة؛ أدخل سبب المراجعة أو الاعتماد قبل القفل',
        );
      }
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.lockPeriod,
      );
      final summary = <String, Object?>{
        'start_date': period.startDate,
        'end_date': period.endDate,
        'unposted_count': report.unpostedEntries.length,
        'unbalanced_posted_count': report.unbalancedPostedEntries.length,
        'internal_reconciliation_blocking_count':
            report.blockingReconciliationCount,
        'internal_manual_review_ack_count':
            report.manualReviewAcknowledgementCount,
        'internal_legacy_review_count': report.legacyReviewCount,
      };
      final timestamp = DateTime.now().toIso8601String();
      await _appendAccountingPeriodEventTx(
        txn,
        periodId: periodId,
        action: 'locked',
        actor: actor,
        reason: normalizedReason.isEmpty ? null : normalizedReason,
        readinessSummary: jsonEncode(summary),
        timestamp: timestamp,
      );
      final updated = await txn.update(
        'accounting_periods',
        {'status': 'locked'},
        where: 'id = ? AND status = ?',
        whereArgs: [periodId, 'open'],
      );
      if (updated != 1) throw StateError('تغيرت حالة الفترة قبل القفل');
      await _recordAuditTx(
        txn,
        action: 'ACCOUNTING_PERIOD_LOCKED',
        entityType: 'accounting_period',
        entityId: periodId,
        details: {
          ...summary,
          if (normalizedReason.isNotEmpty)
            'lock_review_reason': normalizedReason,
        },
        timestamp: timestamp,
      );
    });
  }

  Future<void> closeAccountingPeriod(int periodId, {String reason = ''}) async {
    PermissionRuntime.require(
      'accounting_periods',
      AppPermissionAction.closePeriod,
    );
    if (periodId <= 0) throw ArgumentError('رقم الفترة غير صالح');
    final normalizedReason = reason.trim();
    if (normalizedReason.length > 500) {
      throw ArgumentError('سبب الإقفال لا يتجاوز 500 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.closePeriod,
      );
      final actor = await _requireAccountingPeriodActorTx(txn);
      final period = await _accountingPeriodTx(txn, periodId);
      if (period.status != 'locked') {
        throw StateError('يجب قفل الفترة قبل اعتماد إقفالها النهائي');
      }
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.closePeriod,
      );
      final timestamp = DateTime.now().toIso8601String();
      await _appendAccountingPeriodEventTx(
        txn,
        periodId: periodId,
        action: 'closed',
        actor: actor,
        reason: normalizedReason.isEmpty ? null : normalizedReason,
        timestamp: timestamp,
      );
      final updated = await txn.update(
        'accounting_periods',
        {'status': 'closed'},
        where: 'id = ? AND status = ?',
        whereArgs: [periodId, 'locked'],
      );
      if (updated != 1) throw StateError('تغيرت حالة الفترة قبل الإقفال');
      await _recordAuditTx(
        txn,
        action: 'ACCOUNTING_PERIOD_CLOSED',
        entityType: 'accounting_period',
        entityId: periodId,
        details: {
          'start_date': period.startDate,
          'end_date': period.endDate,
          if (normalizedReason.isNotEmpty) 'reason': normalizedReason,
        },
        timestamp: timestamp,
      );
    });
  }

  Future<void> reopenAccountingPeriod(
    int periodId, {
    required String reason,
  }) async {
    PermissionRuntime.require(
      'accounting_periods',
      AppPermissionAction.reopenPeriod,
    );
    if (periodId <= 0) throw ArgumentError('رقم الفترة غير صالح');
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 500) {
      throw ArgumentError('سبب إعادة الفتح مطلوب ولا يتجاوز 500 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      );
      final actor = await _requireAccountingPeriodActorTx(txn);
      final period = await _accountingPeriodTx(txn, periodId);
      if (period.status != 'locked' && period.status != 'closed') {
        throw StateError('لا يمكن إعادة فتح فترة مفتوحة بالفعل');
      }
      PermissionRuntime.require(
        'accounting_periods',
        AppPermissionAction.reopenPeriod,
      );
      final timestamp = DateTime.now().toIso8601String();
      await _appendAccountingPeriodEventTx(
        txn,
        periodId: periodId,
        action: 'reopened',
        actor: actor,
        reason: normalizedReason,
        timestamp: timestamp,
      );
      final updated = await txn.update(
        'accounting_periods',
        {'status': 'open'},
        where: 'id = ? AND status = ?',
        whereArgs: [periodId, period.status],
      );
      if (updated != 1) throw StateError('تغيرت حالة الفترة قبل إعادة الفتح');
      await _recordAuditTx(
        txn,
        action: 'ACCOUNTING_PERIOD_REOPENED',
        entityType: 'accounting_period',
        entityId: periodId,
        details: {
          'start_date': period.startDate,
          'end_date': period.endDate,
          'previous_status': period.status,
          'reason': normalizedReason,
        },
        timestamp: timestamp,
      );
    });
  }

  Future<AccountingPeriod> _accountingPeriodTx(
    DatabaseExecutor txn,
    int periodId,
  ) async {
    final rows = await txn.query(
      'accounting_periods',
      where: 'id = ?',
      whereArgs: [periodId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('الفترة المحاسبية غير موجودة');
    return AccountingPeriod.fromMap(rows.single);
  }

  Future<({int id, String name})> _requireAccountingPeriodActorTx(
    DatabaseExecutor txn,
  ) async {
    final userId = PermissionRuntime.userId;
    if (userId == null) {
      throw StateError('يلزم مستخدم مسجل لتوثيق إدارة الفترة');
    }
    final rows = await txn.query(
      'users',
      columns: ['id', 'full_name', 'username', 'is_active'],
      where: 'id = ? AND is_active = 1',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('المستخدم غير موجود أو موقوف');
    final fullName = rows.single['full_name']?.toString().trim() ?? '';
    final username = rows.single['username']?.toString().trim() ?? '';
    final actorName = fullName.isNotEmpty ? fullName : username;
    if (actorName.isEmpty) throw StateError('تعذر تحديد اسم المستخدم للتدقيق');
    return (id: userId, name: actorName);
  }

  Future<void> _appendAccountingPeriodEventTx(
    DatabaseExecutor txn, {
    required int periodId,
    required String action,
    required ({int id, String name}) actor,
    String? reason,
    String? readinessSummary,
    String? timestamp,
  }) async {
    await txn.insert('accounting_period_events', {
      'period_id': periodId,
      'action': action,
      'actor_user_id': actor.id,
      'actor_name': actor.name,
      'reason': reason,
      'readiness_summary': readinessSummary,
      'created_at': timestamp ?? DateTime.now().toIso8601String(),
    });
  }

  String _exclusiveDateBoundAfter(String inclusiveEndDate) {
    if (inclusiveEndDate == '9999-12-31') return '9999-12-32';
    final parts = inclusiveEndDate.split('-').map(int.parse).toList();
    final nextDay = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
    ).add(const Duration(days: 1));
    return nextDay.toIso8601String().substring(0, 10);
  }

  Future<FinancialCloseReadinessReport> _financialCloseReadinessTx(
    DatabaseExecutor txn, {
    required String startDate,
    required String endDate,
  }) async {
    final unpostedRows = await txn.rawQuery(
      '''
      SELECT
        je.id AS journal_entry_id,
        je.entry_date AS entry_date,
        COALESCE(je.description, '') AS description,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS credit_minor,
        COUNT(jl.id) AS line_count
      FROM journal_entries je
      LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
      WHERE COALESCE(je.is_posted, 0) != 1
        AND substr(je.entry_date, 1, 10) BETWEEN ? AND ?
      GROUP BY je.id, je.entry_date, je.description
      ORDER BY je.entry_date, je.id
      ''',
      [startDate, endDate],
    );
    final unbalancedRows = await txn.rawQuery(
      '''
      SELECT
        je.id AS journal_entry_id,
        je.entry_date AS entry_date,
        COALESCE(je.description, '') AS description,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS credit_minor,
        COUNT(jl.id) AS line_count
      FROM journal_entries je
      LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
      WHERE je.is_posted = 1
        AND substr(je.entry_date, 1, 10) BETWEEN ? AND ?
      GROUP BY je.id, je.entry_date, je.description
      HAVING COUNT(jl.id) = 0
        OR CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
           != CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
      ORDER BY je.entry_date, je.id
      ''',
      [startDate, endDate],
    );
    final companyRows = await txn.query(
      'company_info',
      columns: ['default_currency'],
      orderBy: 'id ASC',
      limit: 1,
    );
    final configuredCurrency = companyRows.isEmpty
        ? null
        : companyRows.first['default_currency']?.toString().trim();
    final currency = configuredCurrency == null || configuredCurrency.isEmpty
        ? 'غير محددة'
        : configuredCurrency;
    final exclusiveEndDate = _exclusiveDateBoundAfter(endDate);
    final invoiceReport = await _loadInvoiceLedgerReconciliationReport(
      db: txn,
      startDate: startDate,
      endDate: endDate,
      exclusiveEndDate: exclusiveEndDate,
      requireReportPermission: false,
    );
    final internalReconciliation =
        await InternalSubledgerReconciliationService.load(
          db: txn,
          startDate: startDate,
          endDate: endDate,
          exclusiveEndDate: exclusiveEndDate,
          currency: currency,
          invoices: invoiceReport,
        );
    return FinancialCloseReadinessReport(
      startDate: startDate,
      endDate: endDate,
      currency: currency,
      unpostedEntries: unpostedRows
          .map((row) => FinancialCloseEntryIssue.fromMap(row, isPosted: false))
          .toList(growable: false),
      unbalancedPostedEntries: unbalancedRows
          .map((row) => FinancialCloseEntryIssue.fromMap(row, isPosted: true))
          .toList(growable: false),
      internalReconciliation: internalReconciliation,
    );
  }

  Future<TrialBalanceReport> getTrialBalance({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final endParts = endDate.split('-').map(int.parse).toList();
    final exclusiveEndDate = DateTime.utc(
      endParts[0],
      endParts[1],
      endParts[2] + 1,
    ).toIso8601String().substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final accountRows = await txn.rawQuery(
        '''
        WITH account_totals AS (
          SELECT
            jl.account_id,
            CAST(ROUND(COALESCE(SUM(
              CASE WHEN je.entry_date < ? THEN jl.debit ELSE 0 END
            ), 0) * 100) AS INTEGER) AS opening_debit_minor,
            CAST(ROUND(COALESCE(SUM(
              CASE WHEN je.entry_date < ? THEN jl.credit ELSE 0 END
            ), 0) * 100) AS INTEGER) AS opening_credit_minor,
            CAST(ROUND(COALESCE(SUM(
              CASE WHEN je.entry_date >= ? AND je.entry_date < ?
                   THEN jl.debit ELSE 0 END
            ), 0) * 100) AS INTEGER) AS period_debit_minor,
            CAST(ROUND(COALESCE(SUM(
              CASE WHEN je.entry_date >= ? AND je.entry_date < ?
                   THEN jl.credit ELSE 0 END
            ), 0) * 100) AS INTEGER) AS period_credit_minor
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.journal_entry_id
          WHERE je.is_posted = 1 AND je.entry_date < ?
          GROUP BY jl.account_id
        )
        SELECT
          a.id AS account_id,
          a.code AS account_code,
          a.name AS account_name,
          a.account_type AS account_type,
          COALESCE(t.opening_debit_minor, 0) AS opening_debit_minor,
          COALESCE(t.opening_credit_minor, 0) AS opening_credit_minor,
          COALESCE(t.period_debit_minor, 0) AS period_debit_minor,
          COALESCE(t.period_credit_minor, 0) AS period_credit_minor
        FROM accounts a
        LEFT JOIN account_totals t ON t.account_id = a.id
        WHERE (
          (a.parent_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM accounts child WHERE child.parent_id = a.id
          ))
          OR COALESCE(t.opening_debit_minor, 0) != 0
          OR COALESCE(t.opening_credit_minor, 0) != 0
          OR COALESCE(t.period_debit_minor, 0) != 0
          OR COALESCE(t.period_credit_minor, 0) != 0
        )
        ORDER BY a.code COLLATE NOCASE, a.id
        ''',
        [
          startDate,
          startDate,
          startDate,
          exclusiveEndDate,
          startDate,
          exclusiveEndDate,
          exclusiveEndDate,
        ],
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return TrialBalanceReport(
        startDate: startDate,
        endDate: endDate,
        currency: currency,
        rows: accountRows.map(TrialBalanceRow.fromMap).toList(growable: false),
      );
    });
  }

  Future<IncomeExpenseReport> getIncomeExpenseReport({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final endParts = endDate.split('-').map(int.parse).toList();
    final exclusiveEndDate = DateTime.utc(
      endParts[0],
      endParts[1],
      endParts[2] + 1,
    ).toIso8601String().substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final accountRows = await txn.rawQuery(
        '''
        SELECT
          a.id AS account_id,
          a.code AS account_code,
          a.name AS account_name,
          a.account_type AS account_type,
          jl.cost_center_id AS cost_center_id,
          cc.code AS cost_center_code,
          cc.name AS cost_center_name,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        JOIN accounts a ON a.id = jl.account_id
        LEFT JOIN cost_centers cc ON cc.id = jl.cost_center_id
        WHERE je.is_posted = 1
          AND je.entry_date >= ?
          AND je.entry_date < ?
          AND a.account_type IN ('Revenue', 'Expense')
        GROUP BY a.id, a.code, a.name, a.account_type,
                 jl.cost_center_id, cc.code, cc.name
        HAVING ROUND(COALESCE(SUM(jl.debit), 0) * 100) != 0
            OR ROUND(COALESCE(SUM(jl.credit), 0) * 100) != 0
        ORDER BY CASE WHEN jl.cost_center_id IS NULL THEN 0 ELSE 1 END,
                 cc.code COLLATE NOCASE, jl.cost_center_id,
                 CASE a.account_type WHEN 'Revenue' THEN 0 ELSE 1 END,
                 a.code COLLATE NOCASE, a.id
        ''',
        [startDate, exclusiveEndDate],
      );
      final costCenterRows = await txn.rawQuery(
        'SELECT id, code, name FROM cost_centers '
        'ORDER BY code COLLATE NOCASE, id',
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return IncomeExpenseReport(
        startDate: startDate,
        endDate: endDate,
        currency: currency,
        costCenters: costCenterRows
            .map(
              (row) => IncomeExpenseCostCenter(
                id: (row['id'] as num).toInt(),
                code: row['code']?.toString() ?? '',
                name: row['name']?.toString() ?? '',
              ),
            )
            .toList(growable: false),
        rows: accountRows
            .map(
              (row) => IncomeExpenseAccountRow(
                accountId: (row['account_id'] as num).toInt(),
                accountCode: row['account_code']?.toString() ?? '',
                accountName: row['account_name']?.toString() ?? '',
                accountType: row['account_type']?.toString() ?? '',
                debitMinor: (row['debit_minor'] as num).toInt(),
                creditMinor: (row['credit_minor'] as num).toInt(),
                costCenterId: (row['cost_center_id'] as num?)?.toInt(),
                costCenterCode: row['cost_center_code']?.toString(),
                costCenterName: row['cost_center_name']?.toString(),
              ),
            )
            .toList(growable: false),
      );
    });
  }

  Future<InvoiceLedgerReconciliationReport>
  getInvoiceLedgerReconciliationReport({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime.utc(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final exclusiveEndDate = _exclusiveDateBoundAfter(endDate);

    final db = await instance.database;
    return db.transaction(
      (txn) => _loadInvoiceLedgerReconciliationReport(
        db: txn,
        startDate: startDate,
        endDate: endDate,
        exclusiveEndDate: exclusiveEndDate,
      ),
    );
  }

  Future<InvoiceLedgerReconciliationReport>
  _loadInvoiceLedgerReconciliationReport({
    required DatabaseExecutor db,
    required String startDate,
    required String endDate,
    required String exclusiveEndDate,
    bool requireReportPermission = true,
  }) async {
    if (requireReportPermission) {
      PermissionRuntime.require('reports', AppPermissionAction.view);
    }
    final rows = await db.rawQuery(
      '''
      WITH invoice_link_counts AS (
        SELECT journal_entry_id, COUNT(*) AS linked_invoice_count
        FROM tax_invoices
        WHERE journal_entry_id IS NOT NULL
        GROUP BY journal_entry_id
      ), scoped_invoices AS (
        SELECT
          ti.id AS invoice_id,
          ti.invoice_date AS invoice_date,
          CAST(ROUND(COALESCE(ti.net_amount, 0) * 100) AS INTEGER)
            AS net_minor,
          CAST(ROUND(COALESCE(ti.tax_amount, 0) * 100) AS INTEGER)
            AS tax_minor,
          CAST(ROUND(COALESCE(ti.total_amount, 0) * 100) AS INTEGER)
            AS total_minor,
          ti.tax_account_id AS tax_account_id,
          CASE WHEN invoice_contract.id IS NULL THEN 1 ELSE 0
            END AS invoice_contract_missing,
          CASE WHEN ci.id IS NULL THEN 1 ELSE 0
            END AS invoice_installment_missing,
          CASE
            WHEN ti.contract_id IS NOT NULL
             AND ti.installment_id IS NOT NULL
             AND ci.contract_id IS NOT NULL
             AND ci.contract_id != ti.contract_id THEN 1
            ELSE 0
          END AS invoice_installment_contract_mismatch,
          CASE WHEN ti.installment_id IS NULL THEN NULL
            ELSE CAST(ROUND(COALESCE(ci.amount, 0) * 100) AS INTEGER)
          END AS installment_amount_minor,
          CASE
            WHEN ti.installment_id IS NOT NULL
             AND (ci.id IS NULL OR
               CAST(ROUND(COALESCE(ci.amount, 0) * 100) AS INTEGER) !=
               CAST(ROUND(COALESCE(ti.net_amount, 0) * 100) AS INTEGER))
            THEN 1 ELSE 0
          END AS invoice_installment_amount_mismatch,
          ti.journal_entry_id AS journal_entry_id,
          CASE WHEN je.id IS NULL THEN 0 ELSE 1 END AS journal_entry_exists,
          COALESCE(je.is_posted, 0) AS journal_is_posted,
          tenants.account_id AS tenant_account_id,
          tenants.name AS tenant_name,
          COALESCE(link_counts.linked_invoice_count, 0)
            AS linked_invoice_count
        FROM tax_invoices ti
        LEFT JOIN contracts invoice_contract
          ON invoice_contract.id = ti.contract_id
        LEFT JOIN contract_installments ci
          ON ci.id = ti.installment_id
        LEFT JOIN contracts installment_contract
          ON installment_contract.id = ci.contract_id
        LEFT JOIN tenants
          ON tenants.id = COALESCE(
            invoice_contract.tenant_id,
            installment_contract.tenant_id
          )
        LEFT JOIN journal_entries je ON je.id = ti.journal_entry_id
        LEFT JOIN invoice_link_counts link_counts
          ON link_counts.journal_entry_id = ti.journal_entry_id
        WHERE ti.invoice_date >= ? AND ti.invoice_date < ?
      )
      SELECT
        invoice.invoice_id,
        invoice.invoice_date,
        invoice.net_minor,
        invoice.tax_minor,
        invoice.total_minor,
        invoice.tax_account_id,
        invoice.invoice_contract_missing,
        invoice.invoice_installment_missing,
        invoice.journal_entry_id,
        invoice.journal_entry_exists,
        invoice.journal_is_posted,
        invoice.tenant_account_id,
        invoice.tenant_name,
        invoice.linked_invoice_count,
        invoice.invoice_installment_contract_mismatch,
        invoice.installment_amount_minor,
        invoice.invoice_installment_amount_mismatch,
        CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
          AS journal_debit_minor,
        CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
          AS journal_credit_minor,
        CAST(ROUND(COALESCE(SUM(CASE
          WHEN jl.account_id = invoice.tenant_account_id
          THEN jl.debit ELSE 0 END), 0) * 100) AS INTEGER)
          AS tenant_receivable_debit_minor,
        CAST(ROUND(COALESCE(SUM(CASE
          WHEN account.account_type = 'Revenue'
          THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
          AS revenue_credit_minor,
        CAST(ROUND(COALESCE(SUM(CASE
          WHEN jl.account_id = invoice.tax_account_id
           AND account.account_type = 'Liability'
          THEN jl.credit ELSE 0 END), 0) * 100) AS INTEGER)
          AS tax_liability_credit_minor
      FROM scoped_invoices invoice
      LEFT JOIN journal_lines jl
        ON jl.journal_entry_id = invoice.journal_entry_id
      LEFT JOIN accounts account ON account.id = jl.account_id
      GROUP BY
        invoice.invoice_id,
        invoice.invoice_date,
        invoice.net_minor,
        invoice.tax_minor,
        invoice.total_minor,
        invoice.tax_account_id,
        invoice.invoice_contract_missing,
        invoice.invoice_installment_missing,
        invoice.invoice_installment_contract_mismatch,
        invoice.installment_amount_minor,
        invoice.invoice_installment_amount_mismatch,
        invoice.journal_entry_id,
        invoice.journal_entry_exists,
        invoice.journal_is_posted,
        invoice.tenant_account_id,
        invoice.tenant_name,
        invoice.linked_invoice_count
      ORDER BY invoice.invoice_date, invoice.invoice_id
      ''',
      [startDate, exclusiveEndDate],
    );
    final companyRows = await db.query(
      'company_info',
      columns: ['default_currency'],
      orderBy: 'id ASC',
      limit: 1,
    );
    final configuredCurrency = companyRows.isEmpty
        ? null
        : companyRows.first['default_currency']?.toString().trim();
    final currency = configuredCurrency == null || configuredCurrency.isEmpty
        ? 'غير محددة'
        : configuredCurrency;
    if (requireReportPermission) {
      PermissionRuntime.require('reports', AppPermissionAction.view);
    }
    return InvoiceLedgerReconciliationReport(
      startDate: startDate,
      endDate: endDate,
      currency: currency,
      rows: rows.map(InvoiceLedgerReconciliationRow.fromMap).toList(),
    );
  }

  Future<InternalSubledgerReconciliationReport>
  getInternalSubledgerReconciliationReport({
    required String startDate,
    required String endDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final date = DateTime.utc(parts[0]!, parts[1]!, parts[2]!);
      return date.year == parts[0] &&
          date.month == parts[1] &&
          date.day == parts[2];
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    final exclusiveEndDate = _exclusiveDateBoundAfter(endDate);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final invoiceReport = await _loadInvoiceLedgerReconciliationReport(
        db: txn,
        startDate: startDate,
        endDate: endDate,
        exclusiveEndDate: exclusiveEndDate,
      );
      final report = await InternalSubledgerReconciliationService.load(
        db: txn,
        startDate: startDate,
        endDate: endDate,
        exclusiveEndDate: exclusiveEndDate,
        currency: invoiceReport.currency,
        invoices: invoiceReport,
      );
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return report;
    });
  }

  Future<List<Map<String, dynamic>>> getTenantCollectionReportTenants() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return db.query('tenants', columns: ['id', 'name'], orderBy: 'name, id');
  }

  Future<TenantCollectionReport> getTenantCollectionReport({
    required String startDate,
    required String endDate,
    int? tenantId,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(startDate) || !isCalendarDate(endDate)) {
      throw ArgumentError('يجب إدخال تاريخ صحيح بصيغة YYYY-MM-DD');
    }
    if (startDate.compareTo(endDate) > 0) {
      throw ArgumentError('بداية الفترة لا يمكن أن تتجاوز نهايتها');
    }
    if (tenantId != null && tenantId <= 0) {
      throw ArgumentError('معرّف المستأجر غير صالح');
    }
    final endParts = endDate.split('-').map(int.parse).toList();
    final exclusiveEndDate = DateTime.utc(
      endParts[0],
      endParts[1],
      endParts[2] + 1,
    ).toIso8601String().substring(0, 10);

    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final rows = await txn.rawQuery(
        '''
        WITH receipt_allocations AS (
          SELECT voucher_id, SUM(amount_minor) AS allocated_minor
          FROM collection_allocations
          GROUP BY voucher_id
        ), legacy_installment_totals AS (
          SELECT
            voucher_id,
            installment_id,
            SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS amount_minor
          FROM voucher_installment_allocations
          GROUP BY voucher_id, installment_id
        ), detailed_installment_totals AS (
          SELECT
            voucher_id,
            installment_id,
            SUM(rent_amount_minor) AS rent_amount_minor
          FROM collection_allocations
          GROUP BY voucher_id, installment_id
        ), installment_mismatches AS (
          SELECT legacy.voucher_id
          FROM legacy_installment_totals legacy
          LEFT JOIN detailed_installment_totals detailed
            ON detailed.voucher_id = legacy.voucher_id
            AND detailed.installment_id = legacy.installment_id
          WHERE legacy.amount_minor != COALESCE(detailed.rent_amount_minor, 0)
          UNION ALL
          SELECT detailed.voucher_id
          FROM detailed_installment_totals detailed
          LEFT JOIN legacy_installment_totals legacy
            ON legacy.voucher_id = detailed.voucher_id
            AND legacy.installment_id = detailed.installment_id
          WHERE detailed.rent_amount_minor > 0
            AND legacy.voucher_id IS NULL
        ), legacy_invoice_totals AS (
          SELECT
            voucher_id,
            invoice_id,
            SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS amount_minor
          FROM voucher_invoice_allocations
          GROUP BY voucher_id, invoice_id
        ), detailed_invoice_totals AS (
          SELECT voucher_id, invoice_id, SUM(amount_minor) AS amount_minor
          FROM collection_allocations
          WHERE invoice_id IS NOT NULL
          GROUP BY voucher_id, invoice_id
        ), invoice_mismatches AS (
          SELECT legacy.voucher_id
          FROM legacy_invoice_totals legacy
          LEFT JOIN detailed_invoice_totals detailed
            ON detailed.voucher_id = legacy.voucher_id
            AND detailed.invoice_id = legacy.invoice_id
          WHERE legacy.amount_minor != COALESCE(detailed.amount_minor, 0)
          UNION ALL
          SELECT detailed.voucher_id
          FROM detailed_invoice_totals detailed
          LEFT JOIN legacy_invoice_totals legacy
            ON legacy.voucher_id = detailed.voucher_id
            AND legacy.invoice_id = detailed.invoice_id
          WHERE legacy.voucher_id IS NULL
        ), source_link_mismatches AS (
          SELECT allocation.voucher_id
          FROM collection_allocations allocation
          JOIN vouchers receipt ON receipt.id = allocation.voucher_id
          LEFT JOIN contract_installments installment
            ON installment.id = allocation.installment_id
          LEFT JOIN contracts contract ON contract.id = installment.contract_id
          LEFT JOIN tax_invoices invoice ON invoice.id = allocation.invoice_id
          WHERE receipt.tenant_id IS NULL
             OR installment.id IS NULL
             OR contract.id IS NULL
             OR contract.tenant_id != receipt.tenant_id
             OR allocation.amount_minor <= 0
             OR allocation.amount_minor !=
                allocation.rent_amount_minor + allocation.tax_amount_minor
             OR (allocation.invoice_id IS NOT NULL AND (
                  invoice.id IS NULL
                  OR invoice.installment_id IS NOT allocation.installment_id
                  OR invoice.contract_id IS NOT contract.id
                ))
             OR (allocation.invoice_id IS NULL AND EXISTS (
                  SELECT 1
                  FROM voucher_invoice_allocations invoice_allocation
                  JOIN tax_invoices invoice_source
                    ON invoice_source.id = invoice_allocation.invoice_id
                  WHERE invoice_allocation.voucher_id = allocation.voucher_id
                    AND invoice_source.installment_id = allocation.installment_id
                ))
          GROUP BY allocation.voucher_id, allocation.id
        ), mismatch_rows AS (
          SELECT voucher_id FROM installment_mismatches
          UNION ALL
          SELECT voucher_id FROM invoice_mismatches
          UNION ALL
          SELECT voucher_id FROM source_link_mismatches
        ), source_issue_counts AS (
          SELECT voucher_id, COUNT(*) AS source_mismatch_count
          FROM mismatch_rows
          GROUP BY voucher_id
        ), refund_audit_base AS (
          SELECT
            refund.id AS voucher_id,
            refund.voucher_date AS voucher_date,
            refund.tenant_id AS tenant_id,
            COALESCE(tenant.name, refund.party_name, 'غير محدد') AS tenant_name,
            -ABS(CAST(ROUND(refund.amount * 100) AS INTEGER)) AS amount_minor,
            COALESCE(SUM(allocation.amount_minor), 0)
              AS linked_allocation_minor,
            COALESCE(GROUP_CONCAT(DISTINCT source.id), '')
              AS source_receipt_voucher_ids,
            CASE
              WHEN refund.amount <= 0 THEN 'مبلغ سند الاسترداد غير صالح'
              WHEN COALESCE(SUM(allocation.amount_minor), 0) !=
                CAST(ROUND(refund.amount * 100) AS INTEGER)
                THEN 'مجموع تخصيصات الاسترداد لا يطابق السند'
              WHEN SUM(CASE
                WHEN allocation.amount_minor <= 0
                  OR allocation.rent_amount_minor + allocation.tax_amount_minor !=
                    allocation.amount_minor THEN 1
                ELSE 0
              END) > 0 THEN 'تقسيم مبلغ الاسترداد غير متسق'
              WHEN SUM(CASE
                WHEN source.voucher_type = 'قبض مستأجر'
                  AND source.tenant_id = refund.tenant_id
                  AND source_journal.is_posted = 1 THEN 0
                ELSE 1
              END) > 0 THEN 'مصدر القبض غير مرحل أو لمستأجر مختلف'
              WHEN SUM(CASE
                WHEN COALESCE(source_issues.source_mismatch_count, 0) > 0
                  THEN 1 ELSE 0
              END) > 0 THEN 'تخصيص مصدر القبض يحتاج مراجعة'
              WHEN SUM(CASE
                WHEN source_balance.remaining_minor < 0
                  OR source_balance.remaining_rent_minor < 0
                  OR source_balance.remaining_tax_minor < 0 THEN 1
                ELSE 0
              END) > 0 THEN 'مجموع الاستردادات يتجاوز سقف المصدر'
              ELSE 'مرتبط ومطابق'
            END AS allocation_status
          FROM vouchers refund
          LEFT JOIN tenants tenant ON tenant.id = refund.tenant_id
          JOIN journal_entries refund_journal
            ON refund_journal.id = refund.journal_entry_id
            AND refund_journal.is_posted = 1
          JOIN refund_allocations allocation
            ON allocation.refund_voucher_id = refund.id
          JOIN collection_allocations source_allocation
            ON source_allocation.id = allocation.collection_allocation_id
          JOIN collection_allocation_balances source_balance
            ON source_balance.id = source_allocation.id
          JOIN vouchers source ON source.id = source_allocation.voucher_id
          LEFT JOIN journal_entries source_journal
            ON source_journal.id = source.journal_entry_id
          LEFT JOIN source_issue_counts source_issues
            ON source_issues.voucher_id = source.id
          WHERE refund.voucher_type = 'صرف مستأجر'
            AND refund.tenant_id IS NOT NULL
            AND refund.voucher_date >= ?
            AND refund.voucher_date < ?
          GROUP BY refund.id, refund.voucher_date, refund.tenant_id,
                   tenant.name, refund.party_name, refund.amount
        ), refund_audit AS (
          SELECT
            voucher_id,
            voucher_date,
            tenant_id,
            tenant_name,
            amount_minor,
            linked_allocation_minor,
            source_receipt_voucher_ids,
            allocation_status,
            CASE WHEN allocation_status = 'مرتبط ومطابق' THEN 1 ELSE 0
              END AS is_verified_refund,
            CASE WHEN allocation_status = 'مرتبط ومطابق' THEN 0 ELSE 1
              END AS source_mismatch_count,
            CASE WHEN allocation_status = 'مرتبط ومطابق'
              THEN 'المصدر متسق وتحت السقف' ELSE allocation_status
              END AS source_consistency_status
          FROM refund_audit_base
        ), report_rows AS (
          SELECT
            v.id AS voucher_id,
            v.voucher_date AS voucher_date,
            v.tenant_id AS tenant_id,
            COALESCE(t.name, v.party_name, 'غير محدد') AS tenant_name,
            0 AS is_refund,
            CAST(ROUND(v.amount * 100) AS INTEGER) AS amount_minor,
            COALESCE(ra.allocated_minor, 0) AS linked_allocation_minor,
            '' AS source_receipt_voucher_ids,
            CASE
              WHEN v.amount <= 0 THEN 'مبلغ السند غير صالح'
              WHEN COALESCE(ra.allocated_minor, 0) =
                CAST(ROUND(v.amount * 100) AS INTEGER)
                THEN 'التخصيص مطابق'
              WHEN COALESCE(ra.allocated_minor, 0) = 0
                THEN 'لا يوجد تخصيص مثبت'
              WHEN COALESCE(ra.allocated_minor, 0) <
                CAST(ROUND(v.amount * 100) AS INTEGER)
                THEN 'التخصيص غير مكتمل'
              ELSE 'التخصيص يتجاوز مبلغ السند'
            END AS allocation_status,
            CASE
              WHEN COALESCE(source_issues.source_mismatch_count, 0) > 0
                THEN 'يوجد اختلاف في سجل أو رابط التخصيص'
              WHEN COALESCE(ra.allocated_minor, 0) = 0
                THEN 'لا توجد تخصيصات للمقارنة'
              ELSE 'سجلات التخصيص متطابقة'
            END AS source_consistency_status,
            COALESCE(source_issues.source_mismatch_count, 0)
              AS source_mismatch_count,
            0 AS is_verified_refund
          FROM vouchers v
          JOIN tenants t ON t.id = v.tenant_id
          JOIN journal_entries je
            ON je.id = v.journal_entry_id AND je.is_posted = 1
          LEFT JOIN receipt_allocations ra ON ra.voucher_id = v.id
          LEFT JOIN source_issue_counts source_issues
            ON source_issues.voucher_id = v.id
          WHERE v.voucher_type = 'قبض مستأجر'
            AND v.tenant_id IS NOT NULL
            AND v.voucher_date >= ?
            AND v.voucher_date < ?

          UNION ALL

          SELECT
            audit.voucher_id,
            audit.voucher_date,
            audit.tenant_id,
            audit.tenant_name,
            1 AS is_refund,
            audit.amount_minor,
            audit.linked_allocation_minor,
            audit.source_receipt_voucher_ids,
            audit.allocation_status,
            audit.source_consistency_status,
            audit.source_mismatch_count,
            audit.is_verified_refund
          FROM refund_audit audit
        )
        SELECT * FROM report_rows
        WHERE (? IS NULL OR tenant_id = ?)
        ORDER BY voucher_date, voucher_id, is_refund
        ''',
        [
          startDate,
          exclusiveEndDate,
          startDate,
          exclusiveEndDate,
          tenantId,
          tenantId,
        ],
      );
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      final selectedTenantRows = tenantId == null
          ? const <Map<String, Object?>>[]
          : await txn.query(
              'tenants',
              columns: ['name'],
              where: 'id = ?',
              whereArgs: [tenantId],
              limit: 1,
            );
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return TenantCollectionReport(
        startDate: startDate,
        endDate: endDate,
        currency: currency,
        tenantId: tenantId,
        tenantName: selectedTenantRows.isEmpty
            ? null
            : selectedTenantRows.first['name']?.toString(),
        rows: rows
            .map(
              (row) => TenantCollectionReportRow(
                voucherId: (row['voucher_id'] as num).toInt(),
                voucherDate: row['voucher_date']?.toString() ?? '',
                tenantId: (row['tenant_id'] as num).toInt(),
                tenantName: row['tenant_name']?.toString() ?? 'غير محدد',
                isRefund: (row['is_refund'] as num).toInt() == 1,
                isVerifiedRefund:
                    (row['is_verified_refund'] as num).toInt() == 1,
                amountMinor: (row['amount_minor'] as num).toInt(),
                allocationStatus:
                    row['allocation_status']?.toString() ?? 'غير محدد',
                sourceConsistencyStatus:
                    row['source_consistency_status']?.toString() ?? 'غير محدد',
                sourceMismatchCount: (row['source_mismatch_count'] as num)
                    .toInt(),
                sourceReceiptVoucherIds:
                    row['source_receipt_voucher_ids']?.toString() ?? '',
                linkedAllocationMinor: (row['linked_allocation_minor'] as num)
                    .toInt(),
              ),
            )
            .toList(growable: false),
      );
    });
  }

  /// Reconstructs tenant installment balances using only posted documents
  /// dated on/before [asOfDate]. This is not a historical knowledge snapshot:
  /// documents entered later with an earlier document date are reflected.
  Future<TenantAgingReport> getTenantAgingReport({
    required String asOfDate,
  }) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);

    bool isCalendarDate(String value) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
      final parts = value.split('-').map(int.tryParse).toList();
      if (parts.any((part) => part == null)) return false;
      final year = parts[0]!;
      final month = parts[1]!;
      final day = parts[2]!;
      if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
        return false;
      }
      final date = DateTime.utc(year, month, day);
      return date.year == year && date.month == month && date.day == day;
    }

    if (!isCalendarDate(asOfDate)) {
      throw ArgumentError('يجب إدخال تاريخ قطع صحيح بصيغة YYYY-MM-DD');
    }
    final parts = asOfDate.split('-').map(int.parse).toList();
    final cutoff = DateTime.utc(parts[0], parts[1], parts[2]);
    final exclusiveEndDate = DateTime.utc(
      parts[0],
      parts[1],
      parts[2] + 1,
    ).toIso8601String().substring(0, 10);
    String dateOnly(Object? value) {
      final text = value?.toString() ?? '';
      return text.length >= 10 ? text.substring(0, 10) : text;
    }

    int minor(Object? value) =>
        value is num ? (value.toDouble() * 100).round() : 0;
    final db = await instance.database;
    return db.transaction((txn) async {
      PermissionRuntime.require('reports', AppPermissionAction.view);
      final exceptions = <TenantAgingReviewException>[];
      void addException({
        required int id,
        required String date,
        required String type,
        required String tenant,
        required int amount,
        required String reason,
      }) {
        exceptions.add(
          TenantAgingReviewException(
            documentId: id,
            documentDate: date,
            documentType: type,
            tenantName: tenant,
            amountMinor: amount.abs(),
            reason: reason,
          ),
        );
      }

      final installments = await txn.rawQuery('''
        SELECT
          ci.id AS installment_id,
          ci.contract_id,
          ci.amount AS installment_amount,
          ci.due_date,
          ci.status AS installment_status,
          ci.paid_amount AS legacy_paid_amount,
          c.status AS contract_status,
          c.tenant_id,
          COALESCE(t.name, 'غير محدد') AS tenant_name,
          COALESCE(p.name, 'غير محدد') AS property_name,
          COALESCE(u.unit_number, 'غير محدد') AS unit_number
        FROM contract_installments ci
        JOIN contracts c ON c.id = ci.contract_id
        JOIN tenants t ON t.id = c.tenant_id
        LEFT JOIN units u ON u.id = c.unit_id
        LEFT JOIN properties p ON p.id = u.property_id
        ORDER BY t.name COLLATE NOCASE, ci.due_date, ci.id
      ''');
      final installmentById = <int, Map<String, Object?>>{
        for (final row in installments)
          (row['installment_id'] as num).toInt(): row,
      };

      // Only a posted, internally consistent invoice linked to its contract
      // installment replaces the rent-only schedule amount with its gross
      // amount (total_amount already includes tax).
      final invoiceRows = await txn.rawQuery(
        '''
        SELECT
          invoice.id AS invoice_id,
          invoice.contract_id,
          invoice.installment_id,
          invoice.invoice_date,
          invoice.net_amount,
          invoice.tax_amount,
          invoice.total_amount,
          installment.contract_id AS installment_contract_id,
          installment.amount AS installment_amount,
          contract.tenant_id,
          COALESCE(tenant.name, 'غير محدد') AS tenant_name,
          journal.is_posted AS journal_is_posted
        FROM tax_invoices invoice
        LEFT JOIN contract_installments installment
          ON installment.id = invoice.installment_id
        LEFT JOIN contracts contract ON contract.id = invoice.contract_id
        LEFT JOIN tenants tenant ON tenant.id = contract.tenant_id
        LEFT JOIN journal_entries journal
          ON journal.id = invoice.journal_entry_id
        WHERE invoice.invoice_date < ?
        ORDER BY invoice.invoice_date, invoice.id
      ''',
        [exclusiveEndDate],
      );
      final invoiceAmountByInstallment = <int, int>{};
      final invoicesSeenByInstallment = <int, int>{};
      for (final invoice in invoiceRows) {
        final invoiceDate = dateOnly(invoice['invoice_date']);
        if (!isCalendarDate(invoiceDate) ||
            invoiceDate.compareTo(asOfDate) > 0) {
          continue;
        }
        final invoiceId = (invoice['invoice_id'] as num).toInt();
        final installmentId = (invoice['installment_id'] as num?)?.toInt();
        final totalMinor = minor(invoice['total_amount']);
        final netMinor = minor(invoice['net_amount']);
        final taxMinor = minor(invoice['tax_amount']);
        final installment = installmentId == null
            ? null
            : installmentById[installmentId];
        final isValid =
            installment != null &&
            invoice['contract_id'] is num &&
            (invoice['contract_id'] as num).toInt() ==
                (installment['contract_id'] as num).toInt() &&
            invoice['installment_contract_id'] is num &&
            (invoice['installment_contract_id'] as num).toInt() ==
                (invoice['contract_id'] as num).toInt() &&
            (invoice['journal_is_posted'] as num?)?.toInt() == 1 &&
            totalMinor > 0 &&
            netMinor + taxMinor == totalMinor;
        if (!isValid) {
          exceptions.add(
            TenantAgingReviewException(
              documentId: invoiceId,
              documentDate: invoiceDate,
              documentType: 'فاتورة',
              tenantName: invoice['tenant_name']?.toString() ?? 'غير محدد',
              amountMinor: totalMinor.abs(),
              reason:
                  'فاتورة غير مرحّلة أو لا ترتبط بقسط/عقد متسق؛ لم تدخل في الرصيد المؤكد.',
            ),
          );
          continue;
        }
        final previous = invoicesSeenByInstallment[installmentId];
        if (previous != null) {
          invoiceAmountByInstallment.remove(installmentId);
          exceptions.add(
            TenantAgingReviewException(
              documentId: invoiceId,
              documentDate: invoiceDate,
              documentType: 'فاتورة',
              tenantName: invoice['tenant_name']?.toString() ?? 'غير محدد',
              amountMinor: totalMinor,
              reason:
                  'تعددت الفواتير المرتبطة بالقسط؛ يلزم التحقق قبل اعتماد الإجمالي.',
            ),
          );
          continue;
        }
        invoicesSeenByInstallment[installmentId!] = invoiceId;
        invoiceAmountByInstallment[installmentId] = totalMinor;
      }

      final creditNoteRows = await txn.rawQuery(
        '''
        SELECT note.id, note.invoice_id, note.note_date, note.status,
          note.net_amount_minor, note.tax_amount_minor, note.total_amount_minor,
          note.amount, invoice.installment_id,
          COALESCE(tenant.name, 'غير محدد') AS tenant_name,
          original_journal.is_posted AS note_journal_is_posted,
          reversal.entry_date AS reversal_date,
          reversal.is_posted AS reversal_journal_is_posted
        FROM credit_notes note
        LEFT JOIN tax_invoices invoice ON invoice.id = note.invoice_id
        LEFT JOIN contracts contract ON contract.id = invoice.contract_id
        LEFT JOIN tenants tenant ON tenant.id = contract.tenant_id
        LEFT JOIN journal_entries original_journal
          ON original_journal.id = note.journal_entry_id
        LEFT JOIN journal_entries reversal
          ON reversal.id = note.reversal_journal_entry_id
        WHERE note.status != 'draft'
          AND note.note_date < ?
        ORDER BY note.note_date, note.id
        ''',
        [exclusiveEndDate],
      );
      final creditedByInstallment = <int, int>{};
      for (final note in creditNoteRows) {
        final noteId = (note['id'] as num).toInt();
        final noteDate = dateOnly(note['note_date']);
        final status = note['status']?.toString();
        final noteTotal = (note['total_amount_minor'] as num?)?.toInt() ?? 0;
        final legacyAmount = minor(note['amount']);
        if (status == 'legacy_review') {
          addException(
            id: noteId,
            date: noteDate,
            type: 'إشعار دائن تاريخي',
            tenant: note['tenant_name']?.toString() ?? 'غير محدد',
            amount: legacyAmount,
            reason:
                'إشعار قديم بلا لقطة تفصيلية أو قيد موثوق؛ لم يُخصم من الذمم.',
          );
          continue;
        }
        if (status != 'posted' && status != 'reversed') continue;
        if (!isCalendarDate(noteDate) || noteDate.compareTo(asOfDate) > 0) {
          addException(
            id: noteId,
            date: noteDate,
            type: 'إشعار دائن',
            tenant: note['tenant_name']?.toString() ?? 'غير محدد',
            amount: noteTotal,
            reason: 'تاريخ الإشعار غير صالح أو بعد تاريخ القطع؛ لم يُحتسب.',
          );
          continue;
        }
        if ((note['note_journal_is_posted'] as num?)?.toInt() != 1 ||
            (status == 'reversed' &&
                (note['reversal_journal_is_posted'] as num?)?.toInt() != 1)) {
          addException(
            id: noteId,
            date: noteDate,
            type: status == 'reversed' ? 'إشعار دائن معكوس' : 'إشعار دائن',
            tenant: note['tenant_name']?.toString() ?? 'غير محدد',
            amount: noteTotal,
            reason:
                'قيد الإشعار أو قيد عكسه غير مرحّل؛ لم يُحتسب في أعمار الذمم.',
          );
          continue;
        }
        if (status == 'reversed') {
          final reversalDate = dateOnly(note['reversal_date']);
          if (!isCalendarDate(reversalDate)) {
            addException(
              id: noteId,
              date: noteDate,
              type: 'إشعار دائن معكوس',
              tenant: note['tenant_name']?.toString() ?? 'غير محدد',
              amount: noteTotal,
              reason: 'قيد عكس الإشعار مفقود أو تاريخه غير صالح؛ يلزم التحقق.',
            );
            continue;
          }
          if (reversalDate.compareTo(asOfDate) <= 0) continue;
        }
        final invoiceId = (note['invoice_id'] as num?)?.toInt();
        final installmentId = (note['installment_id'] as num?)?.toInt();
        final noteNet = (note['net_amount_minor'] as num?)?.toInt() ?? 0;
        final noteTax = (note['tax_amount_minor'] as num?)?.toInt() ?? 0;
        if (invoiceId == null ||
            installmentId == null ||
            noteTotal <= 0 ||
            noteNet < 0 ||
            noteTax < 0 ||
            noteNet + noteTax != noteTotal ||
            invoicesSeenByInstallment[installmentId] != invoiceId ||
            invoiceAmountByInstallment[installmentId] == null) {
          addException(
            id: noteId,
            date: noteDate,
            type: 'إشعار دائن',
            tenant: note['tenant_name']?.toString() ?? 'غير محدد',
            amount: noteTotal,
            reason: 'الإشعار لا يرتبط بفاتورة مرحّلة وقسط متسق؛ لم يُخصم.',
          );
          continue;
        }
        creditedByInstallment[installmentId] =
            (creditedByInstallment[installmentId] ?? 0) + noteTotal;
      }

      final receipts = await txn.rawQuery(
        '''
        SELECT voucher.id AS voucher_id, voucher.tenant_id,
               voucher.voucher_date, voucher.amount,
               COALESCE(tenant.name, voucher.party_name, 'غير محدد') AS tenant_name
        FROM vouchers voucher
        JOIN journal_entries journal ON journal.id = voucher.journal_entry_id
          AND journal.is_posted = 1
        LEFT JOIN tenants tenant ON tenant.id = voucher.tenant_id
        WHERE voucher.voucher_type = 'قبض مستأجر'
          AND voucher.tenant_id IS NOT NULL
          AND voucher.voucher_date < ?
        ORDER BY voucher.voucher_date, voucher.id
      ''',
        [exclusiveEndDate],
      );
      final detailRows = await txn.rawQuery(
        '''
        SELECT allocation.id AS allocation_id, allocation.voucher_id,
               allocation.installment_id, allocation.invoice_id,
               allocation.amount_minor, allocation.rent_amount_minor,
               allocation.tax_amount_minor,
               installment.contract_id AS installment_contract_id,
               contract.tenant_id AS installment_tenant_id,
               invoice.contract_id AS invoice_contract_id,
               invoice.installment_id AS invoice_installment_id,
               invoice.invoice_date,
               invoice_journal.is_posted AS invoice_is_posted
        FROM collection_allocations allocation
        LEFT JOIN contract_installments installment
          ON installment.id = allocation.installment_id
        LEFT JOIN contracts contract ON contract.id = installment.contract_id
        LEFT JOIN tax_invoices invoice ON invoice.id = allocation.invoice_id
        LEFT JOIN journal_entries invoice_journal
          ON invoice_journal.id = invoice.journal_entry_id
        JOIN vouchers receipt ON receipt.id = allocation.voucher_id
        JOIN journal_entries receipt_journal
          ON receipt_journal.id = receipt.journal_entry_id
          AND receipt_journal.is_posted = 1
        WHERE receipt.voucher_type = 'قبض مستأجر'
          AND receipt.voucher_date < ?
        ORDER BY receipt.voucher_date, receipt.id, allocation.id
      ''',
        [exclusiveEndDate],
      );
      final legacyInstallmentRows = await txn.rawQuery(
        '''
        SELECT legacy.voucher_id, legacy.installment_id,
               SUM(CAST(ROUND(legacy.amount * 100) AS INTEGER)) AS amount_minor
        FROM voucher_installment_allocations legacy
        JOIN vouchers voucher ON voucher.id = legacy.voucher_id
        JOIN journal_entries journal ON journal.id = voucher.journal_entry_id
          AND journal.is_posted = 1
        WHERE voucher.voucher_type = 'قبض مستأجر'
          AND voucher.voucher_date < ?
        GROUP BY legacy.voucher_id, legacy.installment_id
      ''',
        [exclusiveEndDate],
      );
      final legacyInvoiceRows = await txn.rawQuery(
        '''
        SELECT legacy.voucher_id, legacy.invoice_id,
               SUM(CAST(ROUND(legacy.amount * 100) AS INTEGER)) AS amount_minor
        FROM voucher_invoice_allocations legacy
        JOIN vouchers voucher ON voucher.id = legacy.voucher_id
        JOIN journal_entries journal ON journal.id = voucher.journal_entry_id
          AND journal.is_posted = 1
        WHERE voucher.voucher_type = 'قبض مستأجر'
          AND voucher.voucher_date < ?
        GROUP BY legacy.voucher_id, legacy.invoice_id
      ''',
        [exclusiveEndDate],
      );
      final detailByReceipt = <int, List<Map<String, Object?>>>{};
      for (final row in detailRows) {
        final id = (row['voucher_id'] as num).toInt();
        detailByReceipt.putIfAbsent(id, () => []).add(row);
      }
      final legacyByReceipt = <int, Map<String, int>>{};
      for (final row in legacyInstallmentRows) {
        final voucherId = (row['voucher_id'] as num).toInt();
        final installmentId = (row['installment_id'] as num).toInt();
        legacyByReceipt.putIfAbsent(voucherId, () => {})['i:$installmentId'] =
            (row['amount_minor'] as num).toInt();
      }
      for (final row in legacyInvoiceRows) {
        final voucherId = (row['voucher_id'] as num).toInt();
        final invoiceId = (row['invoice_id'] as num).toInt();
        legacyByReceipt.putIfAbsent(voucherId, () => {})['f:$invoiceId'] =
            (row['amount_minor'] as num).toInt();
      }
      final acceptedSourceAllocations = <int, Map<String, Object?>>{};
      final sourceIssues = <int, String>{};
      for (final receipt in receipts) {
        final id = (receipt['voucher_id'] as num).toInt();
        final tenantId = (receipt['tenant_id'] as num).toInt();
        final date = dateOnly(receipt['voucher_date']);
        final amountMinor = minor(receipt['amount']);
        final rows = detailByReceipt[id] ?? const <Map<String, Object?>>[];
        final legacy = legacyByReceipt[id] ?? const <String, int>{};
        if (amountMinor <= 0 || !isCalendarDate(date)) {
          final reason = 'مبلغ القبض أو تاريخه غير صالح؛ لم يُخصم من الأقساط.';
          sourceIssues[id] = reason;
          addException(
            id: id,
            date: date,
            type: 'قبض',
            tenant: receipt['tenant_name']?.toString() ?? 'غير محدد',
            amount: amountMinor,
            reason: reason,
          );
          continue;
        } else if (rows.isEmpty) {
          addException(
            id: id,
            date: date,
            type: 'قبض',
            tenant: receipt['tenant_name']?.toString() ?? 'غير محدد',
            amount: amountMinor,
            reason: legacy.isEmpty
                ? 'قبض مرحّل بلا تخصيص تفصيلي موثق؛ لم يُخصم من الأقساط.'
                : 'تخصيص موجود في السجل التاريخي القديم فقط؛ لم يُكرر ولم يُخصم من الأقساط.',
          );
          continue;
        }

        final detailTotals = <String, int>{};
        var detailAmount = 0;
        var detailInvalid = false;
        for (final row in rows) {
          final installmentId = (row['installment_id'] as num?)?.toInt();
          final invoiceId = (row['invoice_id'] as num?)?.toInt();
          final installment = installmentId == null
              ? null
              : installmentById[installmentId];
          final amount = (row['amount_minor'] as num).toInt();
          final rent = (row['rent_amount_minor'] as num).toInt();
          final tax = (row['tax_amount_minor'] as num).toInt();
          detailAmount += amount;
          if (rent > 0 && installmentId != null) {
            detailTotals['i:$installmentId'] =
                (detailTotals['i:$installmentId'] ?? 0) + rent;
          }
          if (invoiceId != null) {
            detailTotals['f:$invoiceId'] =
                (detailTotals['f:$invoiceId'] ?? 0) + amount;
          }
          final invoiceDate = dateOnly(row['invoice_date']);
          if (amount <= 0 ||
              rent < 0 ||
              tax < 0 ||
              rent + tax != amount ||
              installment == null ||
              (row['installment_tenant_id'] as num?)?.toInt() != tenantId ||
              (invoiceId == null && tax != 0) ||
              (invoiceId != null &&
                  ((row['invoice_contract_id'] as num?)?.toInt() !=
                          (installment['contract_id'] as num).toInt() ||
                      (row['invoice_installment_id'] as num?)?.toInt() !=
                          installmentId ||
                      (row['invoice_is_posted'] as num?)?.toInt() != 1 ||
                      !isCalendarDate(invoiceDate) ||
                      invoiceDate.compareTo(asOfDate) > 0))) {
            detailInvalid = true;
          }
        }
        final expectedKeys = {...detailTotals.keys, ...legacy.keys};
        final historicalMismatch = expectedKeys.any(
          (key) => (detailTotals[key] ?? 0) != (legacy[key] ?? 0),
        );
        if (detailInvalid || detailAmount > amountMinor || historicalMismatch) {
          sourceIssues[id] = detailInvalid
              ? 'رابط التخصيص التفصيلي غير متسق؛ يلزم التحقق.'
              : detailAmount > amountMinor
              ? 'التخصيص التفصيلي يتجاوز مبلغ سند القبض.'
              : 'سجل التخصيص التفصيلي لا يطابق سجل التخصيص التاريخي؛ يلزم التحقق.';
          addException(
            id: id,
            date: date,
            type: 'قبض',
            tenant: receipt['tenant_name']?.toString() ?? 'غير محدد',
            amount: amountMinor,
            reason:
                '${sourceIssues[id]} لم يُستخدم أي جزء من هذا السند في الرصيد المؤكد.',
          );
          continue;
        }
        for (final row in rows) {
          final allocationId = (row['allocation_id'] as num).toInt();
          acceptedSourceAllocations[allocationId] = {
            'installment_id': (row['installment_id'] as num).toInt(),
            'amount_minor': (row['amount_minor'] as num).toInt(),
            'voucher_id': id,
            'voucher_date': date,
            'tenant_id': tenantId,
          };
        }
        if (detailAmount < amountMinor) {
          addException(
            id: id,
            date: date,
            type: 'قبض',
            tenant: receipt['tenant_name']?.toString() ?? 'غير محدد',
            amount: amountMinor - detailAmount,
            reason: 'جزء من القبض غير مخصص تفصيليًا؛ عُزل عن الرصيد المؤكد.',
          );
        }
      }

      final refunds = await txn.rawQuery(
        '''
        SELECT voucher.id AS voucher_id, voucher.tenant_id,
               voucher.voucher_date, voucher.amount,
               COALESCE(tenant.name, voucher.party_name, 'غير محدد') AS tenant_name
        FROM vouchers voucher
        JOIN journal_entries journal ON journal.id = voucher.journal_entry_id
          AND journal.is_posted = 1
        LEFT JOIN tenants tenant ON tenant.id = voucher.tenant_id
        WHERE voucher.voucher_type = 'صرف مستأجر'
          AND voucher.tenant_id IS NOT NULL
          AND voucher.voucher_date < ?
        ORDER BY voucher.voucher_date, voucher.id
      ''',
        [exclusiveEndDate],
      );
      final refundDetails = await txn.rawQuery(
        '''
        SELECT refund.refund_voucher_id AS voucher_id,
               refund.collection_allocation_id,
               refund.amount_minor, refund.rent_amount_minor,
               refund.tax_amount_minor
        FROM refund_allocations refund
        JOIN vouchers voucher ON voucher.id = refund.refund_voucher_id
        JOIN journal_entries journal ON journal.id = voucher.journal_entry_id
          AND journal.is_posted = 1
        WHERE voucher.voucher_type = 'صرف مستأجر'
          AND voucher.voucher_date < ?
        ORDER BY voucher.voucher_date, voucher.id, refund.id
      ''',
        [exclusiveEndDate],
      );
      final refundDetailsById = <int, List<Map<String, Object?>>>{};
      for (final row in refundDetails) {
        final id = (row['voucher_id'] as num).toInt();
        refundDetailsById.putIfAbsent(id, () => []).add(row);
      }
      final refundedBySource = <int, int>{};
      for (final refund in refunds) {
        final id = (refund['voucher_id'] as num).toInt();
        final tenantId = (refund['tenant_id'] as num).toInt();
        final date = dateOnly(refund['voucher_date']);
        final amountMinor = minor(refund['amount']);
        final rows = refundDetailsById[id] ?? const <Map<String, Object?>>[];
        var allocatedMinor = 0;
        var invalid = amountMinor <= 0 || !isCalendarDate(date) || rows.isEmpty;
        final totalsBySource = <int, int>{};
        for (final row in rows) {
          final sourceId = (row['collection_allocation_id'] as num).toInt();
          final amount = (row['amount_minor'] as num).toInt();
          final rent = (row['rent_amount_minor'] as num).toInt();
          final tax = (row['tax_amount_minor'] as num).toInt();
          allocatedMinor += amount;
          totalsBySource[sourceId] = (totalsBySource[sourceId] ?? 0) + amount;
          final source = acceptedSourceAllocations[sourceId];
          if (amount <= 0 ||
              rent < 0 ||
              tax < 0 ||
              rent + tax != amount ||
              source == null ||
              (source['tenant_id'] as int?) != tenantId ||
              date.compareTo(source['voucher_date']?.toString() ?? '9999') <
                  0) {
            invalid = true;
          }
        }
        if (allocatedMinor != amountMinor) invalid = true;
        for (final entry in totalsBySource.entries) {
          final source = acceptedSourceAllocations[entry.key];
          final cap = (source?['amount_minor'] as int?) ?? 0;
          final previouslyRefunded = refundedBySource[entry.key] ?? 0;
          if (entry.value > cap - previouslyRefunded) invalid = true;
        }
        if (invalid) {
          addException(
            id: id,
            date: date,
            type: 'استرداد',
            tenant: refund['tenant_name']?.toString() ?? 'غير محدد',
            amount: amountMinor,
            reason:
                'استرداد غير مكتمل أو لا يرتبط بقبض تفصيلي موثق تحت سقف المصدر؛ لم يُخصم.',
          );
          continue;
        }
        for (final entry in totalsBySource.entries) {
          refundedBySource[entry.key] =
              (refundedBySource[entry.key] ?? 0) + entry.value;
        }
      }

      final paidByInstallment = <int, int>{};
      for (final entry in acceptedSourceAllocations.entries) {
        final allocation = entry.value;
        final installmentId = allocation['installment_id'] as int;
        final netAmount =
            (allocation['amount_minor'] as int) -
            (refundedBySource[entry.key] ?? 0);
        paidByInstallment[installmentId] =
            (paidByInstallment[installmentId] ?? 0) + netAmount;
      }

      final reportRows = <TenantAgingReportRow>[];
      for (final installment in installments) {
        final installmentId = (installment['installment_id'] as num).toInt();
        final contractId = (installment['contract_id'] as num).toInt();
        final tenantId = (installment['tenant_id'] as num).toInt();
        final tenantName = installment['tenant_name']?.toString() ?? 'غير محدد';
        final dueDate = dateOnly(installment['due_date']);
        final scheduleMinor = minor(installment['installment_amount']);
        final isCancelled =
            installment['installment_status'] == 'Cancelled' ||
            installment['contract_status'] == 'Cancelled';
        if (isCancelled) {
          final invoiceAmount = invoiceAmountByInstallment[installmentId];
          final allocatedPaid = paidByInstallment[installmentId] ?? 0;
          final legacyPaid = minor(installment['legacy_paid_amount']);
          if (invoiceAmount != null || allocatedPaid > 0 || legacyPaid != 0) {
            final reviewAmount = [
              scheduleMinor.abs(),
              invoiceAmount ?? 0,
              allocatedPaid,
              legacyPaid.abs(),
            ].reduce((a, b) => a > b ? a : b);
            addException(
              id: installmentId,
              date: dueDate,
              type: 'قسط ملغى',
              tenant: tenantName,
              amount: reviewAmount,
              reason:
                  'عقد أو قسط ملغى مرتبط بحركة مالية؛ استُبعد من الرصيد المؤكد ويحتاج تسوية ومراجعة.',
            );
          }
          continue;
        }
        if (!isCalendarDate(dueDate)) {
          addException(
            id: installmentId,
            date: dueDate,
            type: 'قسط',
            tenant: tenantName,
            amount: minor(installment['installment_amount']),
            reason: 'تاريخ استحقاق القسط غير صالح؛ لم يدخل في شرائح الأعمار.',
          );
          continue;
        }
        if (scheduleMinor <= 0) {
          addException(
            id: installmentId,
            date: dueDate,
            type: 'قسط',
            tenant: tenantName,
            amount: scheduleMinor,
            reason: 'مبلغ القسط غير موجب؛ لم يدخل في الرصيد المؤكد.',
          );
          continue;
        }
        final grossObligationMinor =
            invoiceAmountByInstallment[installmentId] ?? scheduleMinor;
        final requestedCreditMinor = creditedByInstallment[installmentId] ?? 0;
        if (requestedCreditMinor > grossObligationMinor) {
          addException(
            id: installmentId,
            date: dueDate,
            type: 'إشعار دائن',
            tenant: tenantName,
            amount: requestedCreditMinor - grossObligationMinor,
            reason: 'إجمالي الإشعارات يتجاوز الالتزام؛ عُزلت الزيادة للمراجعة.',
          );
        }
        final obligationMinor =
            grossObligationMinor -
            requestedCreditMinor.clamp(0, grossObligationMinor).toInt();
        final paid = paidByInstallment[installmentId] ?? 0;
        if (paid > obligationMinor) {
          addException(
            id: installmentId,
            date: dueDate,
            type: 'قسط',
            tenant: tenantName,
            amount: paid - obligationMinor,
            reason:
                'القبوضات الصافية تجاوزت الالتزام بعد الإشعارات الدائنة؛ عُزل رصيد العميل الزائد عن أعمار الذمم.',
          );
        }
        final confirmedPaid = paid.clamp(0, obligationMinor).toInt();
        final balance = obligationMinor - confirmedPaid;
        if (balance == 0) continue;
        final dueParts = dueDate.split('-').map(int.parse).toList();
        final due = DateTime.utc(dueParts[0], dueParts[1], dueParts[2]);
        final daysOverdue = due.isAfter(cutoff)
            ? 0
            : cutoff.difference(due).inDays;
        final bucket = due.isAfter(cutoff)
            ? TenantAgingBucket.notDue
            : daysOverdue <= 30
            ? TenantAgingBucket.days0To30
            : daysOverdue <= 60
            ? TenantAgingBucket.days31To60
            : daysOverdue <= 90
            ? TenantAgingBucket.days61To90
            : TenantAgingBucket.days91Plus;
        reportRows.add(
          TenantAgingReportRow(
            installmentId: installmentId,
            contractId: contractId,
            tenantId: tenantId,
            tenantName: tenantName,
            propertyName:
                installment['property_name']?.toString() ?? 'غير محدد',
            unitNumber: installment['unit_number']?.toString() ?? 'غير محدد',
            dueDate: dueDate,
            daysOverdue: daysOverdue,
            bucket: bucket,
            obligationMinor: obligationMinor,
            paidMinor: confirmedPaid,
            balanceMinor: balance,
          ),
        );
      }
      reportRows.sort((a, b) {
        final tenant = a.tenantName.toLowerCase().compareTo(
          b.tenantName.toLowerCase(),
        );
        if (tenant != 0) return tenant;
        final due = a.dueDate.compareTo(b.dueDate);
        return due != 0 ? due : a.installmentId.compareTo(b.installmentId);
      });
      final companyRows = await txn.query(
        'company_info',
        columns: ['default_currency'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final configuredCurrency = companyRows.isEmpty
          ? null
          : companyRows.first['default_currency']?.toString().trim();
      final currency = configuredCurrency == null || configuredCurrency.isEmpty
          ? 'غير محددة'
          : configuredCurrency;
      PermissionRuntime.require('reports', AppPermissionAction.view);
      return TenantAgingReport(
        asOfDate: asOfDate,
        currency: currency,
        rows: reportRows,
        exceptions: exceptions,
      );
    });
  }

  Future<List<Map<String, dynamic>>> getUnitOccupancyStats() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT
        p.name as property_name,
        COUNT(u.id) as total_units,
        SUM(CASE WHEN u.status = 'مؤجرة' THEN 1 ELSE 0 END) as rented_units,
        SUM(CASE WHEN u.status = 'شاغرة' THEN 1 ELSE 0 END) as vacant_units
      FROM properties p
      LEFT JOIN units u ON p.id = u.property_id
      GROUP BY p.id, p.name
    ''');
  }

  /// A deliberately limited, read-only projection for property/unit inquiry.
  /// Do not add owner, tenant, lease, rent, balance, or sale-review fields here.
  /// Properties available to the property statement, with the cost centre each
  /// one owns exclusively. A shared centre is flagged so the reader knows the
  /// statement will disclose rather than attribute those lines.
  Future<List<Map<String, dynamic>>> getPropertyStatementProperties() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT
        p.id AS id,
        p.name AS name,
        p.cost_center_id AS cost_center_id,
        cc.code AS cost_center_code,
        cc.name AS cost_center_name,
        (
          SELECT COUNT(*) FROM properties other
          WHERE other.cost_center_id = p.cost_center_id
        ) AS center_property_count
      FROM properties p
      LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
      ORDER BY p.name COLLATE NOCASE, p.id
    ''');
  }

  Future<List<Map<String, dynamic>>> getPropertyUnitInquiryProperties() async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT id, name
      FROM properties
      ORDER BY name COLLATE NOCASE, id
    ''');
  }

  Future<List<Map<String, dynamic>>> getPropertyUnitInquiryUnits(
    int propertyId,
  ) async {
    PermissionRuntime.require('reports', AppPermissionAction.view);
    if (propertyId <= 0) throw ArgumentError('العقار المحدد غير صالح');
    final db = await instance.database;
    final properties = await db.query(
      'properties',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [propertyId],
      limit: 1,
    );
    if (properties.isEmpty) throw StateError('العقار المحدد غير موجود');

    return db.rawQuery(
      '''
      SELECT
        u.id,
        u.unit_number,
        u.status,
        (SELECT COUNT(*) FROM contracts c
          WHERE c.unit_id = u.id AND c.status = 'Active')
          AS active_contract_count
      FROM units u
      WHERE u.property_id = ?
      ORDER BY u.unit_number COLLATE NOCASE, u.id
      ''',
      [propertyId],
    );
  }

  Future<List<Map<String, dynamic>>> searchTenantsAndContracts(
    String query,
  ) async {
    _requireAnyView(['leasing', 'reports']);
    final db = await instance.database;
    final searchTerm = '%$query%';
    return await db.rawQuery(
      '''
      SELECT
        t.name as tenant_name,
        t.mobile as mobile,
        c.id as contract_id,
        p.name as property_name,
        u.unit_number as unit_number,
        c.status as contract_status,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NULL THEN ci.amount ELSE ti.total_amount END
        ), 0)
          FROM contract_installments ci
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          WHERE ci.contract_id = c.id) as total_amount,
        (SELECT COALESCE(SUM(
          CASE WHEN ti.id IS NULL THEN ci.paid_amount
            ELSE COALESCE((
              SELECT SUM(cab.remaining_minor) / 100.0
              FROM collection_allocation_balances cab
              WHERE cab.invoice_id = ti.id
            ), 0)
          END
        ), 0)
          FROM contract_installments ci
          LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
          WHERE ci.contract_id = c.id) as paid_amount
      FROM tenants t
      LEFT JOIN contracts c ON t.id = c.tenant_id
      LEFT JOIN units u ON c.unit_id = u.id
      LEFT JOIN properties p ON u.property_id = p.id
      WHERE t.name LIKE ? OR t.mobile LIKE ? OR u.unit_number LIKE ?
    ''',
      [searchTerm, searchTerm, searchTerm],
    );
  }

  Future<List<Map<String, dynamic>>> getDueInstallments(int days) async {
    _requireAnyView(['reports', 'system_services']);
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);

    return await db.rawQuery(
      '''
      SELECT
        ci.id as installment_id,
        ci.due_date,
        ci.amount AS installment_amount,
        COALESCE(ti.total_amount, ci.amount) AS amount,
        CASE WHEN ti.id IS NULL THEN ci.paid_amount
          ELSE COALESCE(vip.paid_amount, 0)
        END AS paid_amount,
        CASE WHEN ti.id IS NULL
          THEN ROUND(MAX(ci.amount - ci.paid_amount, 0), 2)
          ELSE ROUND(MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0), 2)
        END AS remaining_amount,
        ti.id AS invoice_id,
        ci.status,
        t.name as tenant_name,
        t.id as tenant_id
      FROM contract_installments ci
      JOIN contracts c ON ci.contract_id = c.id
      JOIN tenants t ON c.tenant_id = t.id
      LEFT JOIN tax_invoices ti ON ti.installment_id = ci.id
      LEFT JOIN (
        SELECT invoice_id, SUM(remaining_minor) / 100.0 AS paid_amount
        FROM collection_allocation_balances
        WHERE invoice_id IS NOT NULL
        GROUP BY invoice_id
      ) vip ON vip.invoice_id = ti.id
      WHERE c.status IN ('Active', 'Terminated')
        AND ci.status != 'Cancelled'
        AND (CASE WHEN ti.id IS NULL
          THEN MAX(ci.amount - ci.paid_amount, 0)
          ELSE MAX(ti.total_amount - COALESCE(vip.paid_amount, 0), 0)
        END) > 0
        AND ci.due_date <= ?
      ORDER BY ci.due_date ASC
    ''',
      [targetDateStr],
    );
  }

  Future<List<Map<String, dynamic>>> getExpiringContracts(int days) async {
    _requireAnyView(['reports', 'system_services']);
    final db = await instance.database;
    final targetDate = DateTime.now().add(Duration(days: days));
    final targetDateStr = targetDate.toIso8601String().substring(0, 10);
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);

    return await db.rawQuery(
      '''
      SELECT
        c.id as contract_id,
        c.end_date,
        t.name as tenant_name,
        p.name as property_name,
        u.unit_number
      FROM contracts c
      JOIN tenants t ON c.tenant_id = t.id
      JOIN units u ON c.unit_id = u.id
      JOIN properties p ON u.property_id = p.id
      WHERE c.status = 'Active' AND c.end_date >= ? AND c.end_date <= ?
      ORDER BY c.end_date ASC
    ''',
      [todayStr, targetDateStr],
    );
  }

  // --- Tenant Notices ---

  Future<List<Map<String, dynamic>>> getTenantNoticeRecipients() async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    final db = await instance.database;
    return db.query(
      'tenants',
      columns: ['id', 'name', 'mobile'],
      orderBy: 'name COLLATE NOCASE, id',
    );
  }

  Future<List<Map<String, dynamic>>> getTenantNoticeContracts(
    int tenantId,
  ) async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    if (tenantId <= 0) throw ArgumentError('معرف المستأجر غير صحيح');
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        c.id AS contract_id,
        c.start_date,
        c.end_date,
        c.status AS contract_status,
        p.name AS property_name,
        u.unit_number
      FROM contracts c
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE c.tenant_id = ?
      ORDER BY c.start_date DESC, c.id DESC
      ''',
      [tenantId],
    );
  }

  Future<List<Map<String, dynamic>>> getTenantNotices() async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    final db = await instance.database;
    return db.query('tenant_notices', orderBy: 'id DESC');
  }

  Future<Map<String, dynamic>?> getTenantNotice(int noticeId) async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    if (noticeId <= 0) throw ArgumentError('معرف الإشعار غير صحيح');
    final db = await instance.database;
    final rows = await db.query(
      'tenant_notices',
      where: 'id = ?',
      whereArgs: [noticeId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getTenantNoticeEvents(int noticeId) async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    if (noticeId <= 0) throw ArgumentError('معرف الإشعار غير صحيح');
    final db = await instance.database;
    return db.query(
      'tenant_notice_events',
      where: 'notice_id = ?',
      whereArgs: [noticeId],
      orderBy: 'id ASC',
    );
  }

  Future<int> createTenantNoticeDraft({
    required int tenantId,
    int? contractId,
    required String subject,
    required String body,
    required String noticeDate,
  }) async {
    PermissionRuntime.require('notices', AppPermissionAction.add);
    final values = _validatedNoticeContent(
      subject: subject,
      body: body,
      noticeDate: noticeDate,
    );
    if (tenantId <= 0) throw ArgumentError('اختر مستأجرًا صحيحًا');

    final db = await instance.database;
    return db.transaction((txn) async {
      final tenantRows = await txn.query(
        'tenants',
        columns: ['id', 'name', 'mobile'],
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر المحدد غير موجود');
      final tenant = tenantRows.first;
      final contract = await _tenantNoticeContractSnapshot(
        txn,
        tenantId: tenantId,
        contractId: contractId,
      );
      final now = DateTime.now().toIso8601String();
      final userId = await _verifiedAuditUserId(txn);
      final noticeId = await txn.insert('tenant_notices', {
        'tenant_id': tenantId,
        'contract_id': contractId,
        'recipient_name_snapshot': tenant['name']?.toString().trim() ?? '',
        'recipient_phone_snapshot': tenant['mobile']?.toString().trim() ?? '',
        'contract_snapshot_json': contract == null
            ? null
            : jsonEncode(contract),
        'subject': values['subject'],
        'body': values['body'],
        'notice_date': values['notice_date'],
        'status': 'Draft',
        'created_by': userId,
        'created_at': now,
        'updated_by': userId,
        'updated_at': now,
      });
      await _recordTenantNoticeEvent(
        txn,
        noticeId: noticeId,
        eventType: 'draft_created',
        details: {'tenant_id': tenantId, 'contract_id': contractId},
        userId: userId,
        timestamp: now,
      );
      return noticeId;
    });
  }

  Future<void> updateTenantNoticeDraft({
    required int noticeId,
    required int tenantId,
    int? contractId,
    required String subject,
    required String body,
    required String noticeDate,
  }) async {
    PermissionRuntime.require('notices', AppPermissionAction.edit);
    if (noticeId <= 0 || tenantId <= 0) {
      throw ArgumentError('معرف الإشعار أو المستأجر غير صحيح');
    }
    final values = _validatedNoticeContent(
      subject: subject,
      body: body,
      noticeDate: noticeDate,
    );
    final db = await instance.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'tenant_notices',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [noticeId],
        limit: 1,
      );
      if (existing.isEmpty) throw StateError('الإشعار غير موجود');
      if (existing.first['status'] != 'Draft') {
        throw StateError('لا يمكن تعديل إشعار سبق إصداره');
      }
      final tenantRows = await txn.query(
        'tenants',
        columns: ['id', 'name', 'mobile'],
        where: 'id = ?',
        whereArgs: [tenantId],
        limit: 1,
      );
      if (tenantRows.isEmpty) throw StateError('المستأجر المحدد غير موجود');
      final tenant = tenantRows.first;
      final contract = await _tenantNoticeContractSnapshot(
        txn,
        tenantId: tenantId,
        contractId: contractId,
      );
      final now = DateTime.now().toIso8601String();
      final userId = await _verifiedAuditUserId(txn);
      final updated = await txn.update(
        'tenant_notices',
        {
          'tenant_id': tenantId,
          'contract_id': contractId,
          'recipient_name_snapshot': tenant['name']?.toString().trim() ?? '',
          'recipient_phone_snapshot': tenant['mobile']?.toString().trim() ?? '',
          'contract_snapshot_json': contract == null
              ? null
              : jsonEncode(contract),
          'subject': values['subject'],
          'body': values['body'],
          'notice_date': values['notice_date'],
          'updated_by': userId,
          'updated_at': now,
        },
        where: "id = ? AND status = 'Draft'",
        whereArgs: [noticeId],
      );
      if (updated != 1) throw StateError('تغيرت حالة الإشعار؛ أعد تحميله');
      await _recordTenantNoticeEvent(
        txn,
        noticeId: noticeId,
        eventType: 'draft_updated',
        details: {'tenant_id': tenantId, 'contract_id': contractId},
        userId: userId,
        timestamp: now,
      );
    });
  }

  Future<void> issueTenantNotice(int noticeId) async {
    PermissionRuntime.require('notices', AppPermissionAction.post);
    if (noticeId <= 0) throw ArgumentError('معرف الإشعار غير صحيح');
    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'tenant_notices',
        where: 'id = ?',
        whereArgs: [noticeId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الإشعار غير موجود');
      if (rows.first['status'] != 'Draft') {
        throw StateError('الإشعار صادر مسبقًا ولا يمكن إصداره مرة أخرى');
      }
      final now = DateTime.now().toIso8601String();
      final userId = await _verifiedAuditUserId(txn);
      final updated = await txn.update(
        'tenant_notices',
        {'status': 'Issued', 'issued_by': userId, 'issued_at': now},
        where: "id = ? AND status = 'Draft'",
        whereArgs: [noticeId],
      );
      if (updated != 1) throw StateError('تعذر إصدار الإشعار؛ أعد تحميله');
      await _recordTenantNoticeEvent(
        txn,
        noticeId: noticeId,
        eventType: 'issued',
        details: const {},
        userId: userId,
        timestamp: now,
      );
    });
  }

  Future<void> recordTenantNoticeWordExport({
    required int noticeId,
    required String fileName,
  }) async {
    PermissionRuntime.require('notices', AppPermissionAction.print);
    if (noticeId <= 0 || fileName.trim().isEmpty) {
      throw ArgumentError('بيانات تصدير Word غير مكتملة');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'tenant_notices',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [noticeId],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['status'] != 'Issued') {
        throw StateError('يجب إصدار الإشعار قبل تصديره إلى Word');
      }
      final now = DateTime.now().toIso8601String();
      await _recordTenantNoticeEvent(
        txn,
        noticeId: noticeId,
        eventType: 'word_exported',
        details: {
          'file_name': fileName.trim().substring(
            0,
            fileName.trim().length.clamp(0, 200),
          ),
        },
        userId: await _verifiedAuditUserId(txn),
        timestamp: now,
      );
    });
  }

  Map<String, Object?> _validatedNoticeContent({
    required String subject,
    required String body,
    required String noticeDate,
  }) {
    final normalizedSubject = subject.trim();
    final normalizedBody = body.trim();
    final normalizedNoticeDate = _normalizeStrictNoticeDate(noticeDate.trim());
    if (normalizedSubject.isEmpty || normalizedSubject.length > 160) {
      throw ArgumentError('موضوع الإشعار مطلوب وبحد أقصى 160 حرفًا');
    }
    if (normalizedBody.isEmpty || normalizedBody.length > 10000) {
      throw ArgumentError('نص الإشعار مطلوب وبحد أقصى 10000 حرف');
    }
    if (normalizedNoticeDate == null) {
      throw ArgumentError(
        'تاريخ الإشعار يجب أن يكون يومًا صحيحًا بصيغة YYYY-MM-DD بين 2000 و2100',
      );
    }
    return {
      'subject': normalizedSubject,
      'body': normalizedBody,
      'notice_date': normalizedNoticeDate,
    };
  }

  String? _normalizeStrictNoticeDate(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    if (year < 2000 || year > 2100) return null;
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return value;
  }

  Future<Map<String, Object?>?> _tenantNoticeContractSnapshot(
    DatabaseExecutor txn, {
    required int tenantId,
    required int? contractId,
  }) async {
    if (contractId == null) return null;
    if (contractId <= 0) throw ArgumentError('معرف العقد غير صحيح');
    final rows = await txn.rawQuery(
      '''
      SELECT
        c.id AS contract_id,
        c.start_date,
        c.end_date,
        c.status AS contract_status,
        c.party_snapshot AS contract_party_snapshot_json,
        p.name AS property_name,
        u.unit_number
      FROM contracts c
      JOIN units u ON u.id = c.unit_id
      JOIN properties p ON p.id = u.property_id
      WHERE c.id = ? AND c.tenant_id = ?
      LIMIT 1
      ''',
      [contractId, tenantId],
    );
    if (rows.isEmpty) {
      throw ArgumentError('العقد المحدد لا يتبع المستأجر المختار');
    }
    final row = rows.first;
    final rawPartySnapshot = row['contract_party_snapshot_json'];
    var partySnapshot = <String, dynamic>{};
    if (rawPartySnapshot is String && rawPartySnapshot.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPartySnapshot);
        if (decoded is Map) {
          partySnapshot = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      } on FormatException {
        partySnapshot = <String, dynamic>{};
      }
    }

    Map<String, dynamic> snapshotSection(String key) {
      final value = partySnapshot[key];
      if (value is! Map) return const <String, dynamic>{};
      return value.map((key, value) => MapEntry(key.toString(), value));
    }

    String? snapshotText(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    final tenantSnapshot = snapshotSection('tenant');
    final ownerSnapshot = snapshotSection('owner');
    final propertySnapshot = snapshotSection('property');
    final unitSnapshot = snapshotSection('unit');
    final snapshotPropertyName = snapshotText(propertySnapshot['name']);
    final snapshotUnitNumber = snapshotText(unitSnapshot['unit_number']);
    final hasPropertySnapshot = snapshotPropertyName != null;
    final hasUnitSnapshot = snapshotUnitNumber != null;
    final propertyUnitSnapshotSource = hasPropertySnapshot && hasUnitSnapshot
        ? 'contract_party_snapshot'
        : hasPropertySnapshot || hasUnitSnapshot
        ? 'partial_contract_party_snapshot'
        : 'current_master_data_at_notice_creation';
    return {
      'contract_id': row['contract_id'],
      'start_date': row['start_date'],
      'end_date': row['end_date'],
      'contract_status': row['contract_status'],
      'contract_tenant_name': snapshotText(tenantSnapshot['name']),
      'contract_owner_name': snapshotText(ownerSnapshot['name']),
      'property_name':
          snapshotPropertyName ?? snapshotText(row['property_name']),
      'unit_number': snapshotUnitNumber ?? snapshotText(row['unit_number']),
      'party_snapshot_source': propertyUnitSnapshotSource,
      'property_name_source': hasPropertySnapshot
          ? 'contract_party_snapshot'
          : 'current_master_data_at_notice_creation',
      'unit_number_source': hasUnitSnapshot
          ? 'contract_party_snapshot'
          : 'current_master_data_at_notice_creation',
      'contract_terms_source': 'current_contract_data_at_notice_creation',
    };
  }

  Future<void> _recordTenantNoticeEvent(
    DatabaseExecutor txn, {
    required int noticeId,
    required String eventType,
    required Map<String, Object?> details,
    required int? userId,
    required String timestamp,
  }) async {
    final eventDetails = <String, Object?>{'notice_id': noticeId, ...details};
    await txn.insert('tenant_notice_events', {
      'notice_id': noticeId,
      'event_type': eventType,
      'user_id': userId,
      'created_at': timestamp,
      'details': jsonEncode(eventDetails),
    });
    await _recordAuditTx(
      txn,
      action: 'tenant_notice_$eventType',
      entityType: 'tenant_notice',
      entityId: noticeId,
      details: eventDetails,
      timestamp: timestamp,
    );
  }

  String? _normalizeSaleDateOnly(String? rawDate) {
    final value = rawDate?.trim() ?? '';
    if (value.isEmpty) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) {
      throw ArgumentError('تاريخ البيع المقترح يجب أن يكون بصيغة YYYY-MM-DD');
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError('تاريخ البيع المقترح غير صالح تقويميًا');
    }
    return value;
  }

  Future<int> _requirePropertySaleActorId(DatabaseExecutor txn) async {
    final actorId = await _verifiedAuditUserId(txn);
    if (actorId == null) {
      throw StateError('يلزم مستخدم مسجل وموثق لتسجيل مراجعة البيع');
    }
    final rows = await txn.query(
      'users',
      columns: ['is_active'],
      where: 'id = ?',
      whereArgs: [actorId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['is_active'] != 1) {
      throw StateError('حساب المستخدم غير نشط؛ تعذر تسجيل مراجعة البيع');
    }
    return actorId;
  }

  Future<List<Map<String, Object?>>> getPropertySaleProperties() async {
    PermissionRuntime.require('property_sales', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT
        p.id,
        p.name,
        p.deed_number,
        p.owner_id,
        o.account_id AS owner_account_id,
        o.name AS owner_name,
        COUNT(DISTINCT u.id) AS unit_count,
        COUNT(DISTINCT CASE WHEN c.status = 'Active' THEN c.id END)
          AS active_contract_count
      FROM properties p
      LEFT JOIN owners o ON o.id = p.owner_id
      LEFT JOIN units u ON u.property_id = p.id
      LEFT JOIN contracts c ON c.unit_id = u.id
      GROUP BY p.id
      ORDER BY p.name COLLATE NOCASE, p.id
    ''');
  }

  Future<List<Map<String, Object?>>> getPropertySaleOwners() async {
    PermissionRuntime.require('property_sales', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT id, name, account_id
      FROM owners
      ORDER BY name COLLATE NOCASE, id
    ''');
  }

  Future<List<Map<String, Object?>>> getPropertySaleUnits(
    int propertyId,
  ) async {
    PermissionRuntime.require('property_sales', AppPermissionAction.view);
    if (propertyId <= 0) throw ArgumentError('العقار المحدد غير صالح');
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT
        u.id,
        u.property_id,
        u.owner_id,
        COALESCE(u.owner_id, p.owner_id) AS effective_owner_id,
        effective_owner.name AS owner_name,
        u.unit_number,
        u.status,
        (SELECT COUNT(*) FROM contracts c
          WHERE c.unit_id = u.id AND c.status = 'Active')
          AS active_contract_count
      FROM units u
      JOIN properties p ON p.id = u.property_id
      LEFT JOIN owners effective_owner
        ON effective_owner.id = COALESCE(u.owner_id, p.owner_id)
      WHERE u.property_id = ?
      ORDER BY u.unit_number COLLATE NOCASE, u.id
      ''',
      [propertyId],
    );
  }

  Future<int> createPropertySaleReview({
    required String targetType,
    required int propertyId,
    int? unitId,
    required String reason,
    required int proposedBuyerOwnerId,
    required int proposedAmountMinor,
    required String proposedSaleDate,
  }) async {
    PermissionRuntime.require('property_sales', AppPermissionAction.add);
    final normalizedReason = reason.trim();
    if (targetType != 'property' && targetType != 'unit') {
      throw ArgumentError('نوع هدف البيع غير معروف');
    }
    if (propertyId <= 0 ||
        (targetType == 'property' && unitId != null) ||
        (targetType == 'unit' && (unitId == null || unitId <= 0))) {
      throw ArgumentError('حدد العقار كاملًا أو وحدة صحيحة تابعة له');
    }
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError('مبرر طلب البيع مطلوب وبحد أقصى 1000 حرف');
    }
    if (proposedBuyerOwnerId <= 0 || proposedAmountMinor <= 0) {
      throw ArgumentError('المشتري والسعر المقترح حقول مطلوبة وبقيم صالحة');
    }
    final normalizedDate = _normalizeSaleDateOnly(proposedSaleDate);
    if (normalizedDate == null) {
      throw ArgumentError('تاريخ البيع المقترح مطلوب بصيغة صحيحة');
    }
    final parsedProposedDate = DateTime.parse(normalizedDate);
    final today = DateTime.now();
    if (parsedProposedDate.isAfter(
      DateTime(today.year, today.month, today.day),
    )) {
      throw ArgumentError('لا يمكن طلب مراجعة بيع بتاريخ مستقبلي');
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final actorId = await _requirePropertySaleActorId(txn);
      final propertyRows = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.deed_number, p.address, p.owner_id,
          o.account_id AS owner_account_id, o.name AS owner_name
        FROM properties p LEFT JOIN owners o ON o.id = p.owner_id
        WHERE p.id = ? LIMIT 1
        ''',
        [propertyId],
      );
      if (propertyRows.isEmpty) throw StateError('العقار المحدد غير موجود');
      final property = propertyRows.single;
      Map<String, Object?>? unit;
      if (targetType == 'unit') {
        final unitRows = await txn.rawQuery(
          '''
          SELECT u.*, COALESCE(u.owner_id, p.owner_id) AS effective_owner_id,
            effective_owner.name AS owner_name,
            effective_owner.account_id AS owner_account_id
          FROM units u
          JOIN properties p ON p.id = u.property_id
          LEFT JOIN owners effective_owner
            ON effective_owner.id = COALESCE(u.owner_id, p.owner_id)
          WHERE u.id = ? AND u.property_id = ? LIMIT 1
          ''',
          [unitId, propertyId],
        );
        if (unitRows.isEmpty) {
          throw StateError('الوحدة غير موجودة أو لا تتبع العقار المحدد');
        }
        unit = unitRows.single;
      }
      Object? sellerOwnerIdValue;
      String? sellerOwnerName;
      Object? sellerOwnerAccountId;
      if (targetType == 'unit') {
        final unitData = unit!;
        sellerOwnerIdValue = unitData['effective_owner_id'];
        sellerOwnerName = unitData['owner_name']?.toString();
        sellerOwnerAccountId = unitData['owner_account_id'];
      } else {
        sellerOwnerIdValue = property['owner_id'];
        sellerOwnerName = property['owner_name']?.toString();
        sellerOwnerAccountId = property['owner_account_id'];
      }
      final sellerOwnerId = sellerOwnerIdValue is num
          ? sellerOwnerIdValue.toInt()
          : null;
      if (sellerOwnerId == null || sellerOwnerName == null) {
        throw StateError('لا يوجد مالك فعلي صالح للهدف المحدد');
      }
      if (sellerOwnerId == proposedBuyerOwnerId) {
        throw ArgumentError('يجب أن يختلف المشتري عن المالك البائع');
      }
      final buyerRows = await txn.query(
        'owners',
        columns: ['id', 'name'],
        where: 'id = ?',
        whereArgs: [proposedBuyerOwnerId],
        limit: 1,
      );
      if (buyerRows.isEmpty) throw StateError('المشتري المحدد غير موجود');
      final proposedBuyerName = buyerRows.single['name']?.toString();
      if (proposedBuyerName == null || proposedBuyerName.trim().isEmpty) {
        throw StateError('اسم المشتري غير صالح');
      }
      final activeContractRows = await txn.rawQuery(
        targetType == 'property'
            ? '''
              SELECT COUNT(DISTINCT c.id) AS count
              FROM contracts c JOIN units u ON u.id = c.unit_id
              WHERE u.property_id = ? AND c.status = 'Active'
            '''
            : '''
              SELECT COUNT(*) AS count FROM contracts
              WHERE unit_id = ? AND status = 'Active'
            ''',
        [targetType == 'property' ? propertyId : unitId],
      );
      final activeContractCount = (activeContractRows.single['count'] as num)
          .toInt();
      final now = DateTime.now().toIso8601String();
      final snapshot = <String, Object?>{
        'source': 'current_master_data_at_request',
        'target_type': targetType,
        'property_id': propertyId,
        'seller_owner_id': sellerOwnerId,
        'seller_owner_name': sellerOwnerName,
        'seller_owner_account_id': sellerOwnerAccountId,
        'proposed_buyer_owner_id': proposedBuyerOwnerId,
        'proposed_buyer_owner_name': proposedBuyerName,
        'property_name': property['name'],
        'deed_number': property['deed_number'],
        'address': property['address'],
        'owner_name': property['owner_name'],
        if (unit != null) ...{
          'unit_id': unit['id'],
          'unit_number': unit['unit_number'],
          'unit_status_at_request': unit['status'],
        },
        'active_contract_count_at_request': activeContractCount,
      };
      final reviewId = await txn.insert('property_sale_reviews', {
        'target_type': targetType,
        'property_id': propertyId,
        'unit_id': unitId,
        'requested_by': actorId,
        'requested_at': now,
        'reason': normalizedReason,
        'proposed_amount_minor': proposedAmountMinor,
        'proposed_sale_date': normalizedDate,
        'proposed_buyer_owner_id': proposedBuyerOwnerId,
        'target_snapshot_json': jsonEncode(snapshot),
        'active_contract_count_at_request': activeContractCount,
        'status': 'pending',
      });
      await _recordPropertySaleReviewEvent(
        txn,
        saleReviewId: reviewId,
        eventType: 'requested',
        userId: actorId,
        timestamp: now,
        reason: normalizedReason,
        details: {
          'target_type': targetType,
          'property_id': propertyId,
          'unit_id': unitId,
          'proposed_buyer_owner_id': proposedBuyerOwnerId,
          'proposed_buyer_owner_name': proposedBuyerName,
          'proposed_amount_minor': proposedAmountMinor,
          'proposed_sale_date': normalizedDate,
          'active_contract_count_at_request': activeContractCount,
        },
      );
      return reviewId;
    });
  }

  Future<List<Map<String, Object?>>> getPropertySaleReviews() async {
    PermissionRuntime.require('property_sales', AppPermissionAction.view);
    final db = await instance.database;
    return db.rawQuery('''
      SELECT
        r.*,
        p.name AS current_property_name,
        u.unit_number AS current_unit_number,
        proposed_buyer.name AS proposed_buyer_name,
        CASE WHEN r.target_type = 'unit'
          THEN COALESCE(u.owner_id, p.owner_id) ELSE p.owner_id END
          AS current_owner_id,
        current_owner.name AS current_owner_name,
        requester.full_name AS requester_name,
        reviewer.full_name AS reviewer_name,
        canceller.full_name AS canceller_name,
        e.id AS sale_execution_id,
        e.buyer_owner_id,
        e.buyer_name_snapshot AS buyer_owner_name_snapshot,
        e.sale_price_minor,
        e.sale_date,
        e.deed_reference,
        e.executed_at,
        e.transfer_applied_at,
        ar.id AS accounting_record_id,
        ar.book_value_minor AS accounting_book_value_minor,
        ar.manual_journal_entry_id,
        ar.accounting_note,
        ar.approved_at AS accounting_approved_at,
        ar.approved_by AS accounting_approved_by,
        (SELECT COUNT(*) FROM contracts c JOIN units cu ON cu.id = c.unit_id
          WHERE c.status = 'Active' AND (
            (r.target_type = 'property' AND cu.property_id = r.property_id)
            OR (r.target_type = 'unit' AND c.unit_id = r.unit_id)
          )) AS active_contract_count_current
      FROM property_sale_reviews r
      JOIN properties p ON p.id = r.property_id
      LEFT JOIN units u ON u.id = r.unit_id
      LEFT JOIN owners current_owner
        ON current_owner.id = CASE WHEN r.target_type = 'unit'
          THEN COALESCE(u.owner_id, p.owner_id) ELSE p.owner_id END
      LEFT JOIN owners proposed_buyer
        ON proposed_buyer.id = r.proposed_buyer_owner_id
      JOIN users requester ON requester.id = r.requested_by
      LEFT JOIN users reviewer ON reviewer.id = r.reviewed_by
      LEFT JOIN users canceller ON canceller.id = r.cancelled_by
      LEFT JOIN property_sale_executions e
        ON e.sale_review_id = r.id AND e.transfer_applied_at IS NOT NULL
      LEFT JOIN property_sale_accounting_records ar ON ar.id = (
        SELECT current_record.id
        FROM property_sale_accounting_records current_record
        WHERE current_record.sale_execution_id = e.id
          AND NOT EXISTS (
            SELECT 1 FROM property_sale_accounting_records successor
            WHERE successor.supersedes_record_id = current_record.id
          )
        ORDER BY current_record.id DESC LIMIT 1
      )
      ORDER BY CASE r.status
        WHEN 'pending' THEN 0 WHEN 'accepted' THEN 1 ELSE 2 END,
        r.requested_at DESC, r.id DESC
    ''');
  }

  Future<List<Map<String, Object?>>> getPropertySaleReviewEvents(
    int saleReviewId,
  ) async {
    PermissionRuntime.require('property_sales', AppPermissionAction.view);
    if (saleReviewId <= 0) throw ArgumentError('طلب البيع المحدد غير صالح');
    final db = await instance.database;
    return db.rawQuery(
      '''
      SELECT * FROM (
        SELECT e.id, 'review' AS event_source, e.event_type, e.user_id,
          e.created_at, e.reason, e.details, u.full_name AS user_name
        FROM property_sale_review_events e
        JOIN users u ON u.id = e.user_id
        WHERE e.sale_review_id = ?
        UNION ALL
        SELECT e.id, 'execution' AS event_source, e.event_type, e.user_id,
          e.created_at, e.reason, e.details, u.full_name AS user_name
        FROM property_sale_execution_events e
        JOIN property_sale_executions x ON x.id = e.sale_execution_id
        JOIN users u ON u.id = e.user_id
        WHERE x.sale_review_id = ?
      ) events
      ORDER BY created_at, event_source, id
      ''',
      [saleReviewId, saleReviewId],
    );
  }

  Future<int> completePropertySaleExecution({
    required int saleReviewId,
    required int buyerOwnerId,
    required int salePriceMinor,
    required String saleDate,
    required String deedReference,
    required String reason,
  }) async {
    PermissionRuntime.require('property_sales', AppPermissionAction.post);
    if (saleReviewId <= 0 || buyerOwnerId <= 0 || salePriceMinor <= 0) {
      throw ArgumentError('طلب البيع والمشتري والسعر النهائي حقول مطلوبة');
    }
    final normalizedDate = _normalizeSaleDateOnly(saleDate);
    if (normalizedDate == null) throw ArgumentError('تاريخ الإتمام مطلوب');
    final effectiveDate = DateTime.utc(
      int.parse(normalizedDate.substring(0, 4)),
      int.parse(normalizedDate.substring(5, 7)),
      int.parse(normalizedDate.substring(8, 10)),
    );
    final today = DateTime.now();
    if (effectiveDate.isAfter(
      DateTime.utc(today.year, today.month, today.day),
    )) {
      throw ArgumentError('لا يمكن تسجيل نقل ملكية بتاريخ مستقبلي');
    }
    final normalizedDeed = deedReference.trim();
    final normalizedReason = reason.trim();
    if (normalizedDeed.isEmpty || normalizedDeed.length > 200) {
      throw ArgumentError('مرجع صك/مستند البيع مطلوب وبحد أقصى 200 حرف');
    }
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError('مبرر إتمام البيع مطلوب وبحد أقصى 1000 حرف');
    }

    final db = await instance.database;
    return db.transaction((txn) async {
      final actorId = await _requirePropertySaleActorId(txn);
      final reviewRows = await txn.query(
        'property_sale_reviews',
        columns: [
          'id',
          'status',
          'target_type',
          'property_id',
          'unit_id',
          'target_snapshot_json',
          'proposed_buyer_owner_id',
          'proposed_amount_minor',
          'proposed_sale_date',
        ],
        where: 'id = ?',
        whereArgs: [saleReviewId],
        limit: 1,
      );
      if (reviewRows.isEmpty) throw StateError('طلب البيع غير موجود');
      final review = reviewRows.single;
      if (review['status'] != 'accepted') {
        throw StateError('يجب اعتماد المراجعة اليدوية قبل إتمام البيع');
      }
      final approvedBuyerOwnerId = review['proposed_buyer_owner_id'] is num
          ? (review['proposed_buyer_owner_id'] as num).toInt()
          : null;
      final approvedSalePriceMinor = review['proposed_amount_minor'] is num
          ? (review['proposed_amount_minor'] as num).toInt()
          : null;
      final approvedSaleDate = _normalizeSaleDateOnly(
        review['proposed_sale_date']?.toString(),
      );
      if (approvedBuyerOwnerId == null ||
          approvedBuyerOwnerId <= 0 ||
          approvedSalePriceMinor == null ||
          approvedSalePriceMinor <= 0 ||
          approvedSaleDate == null) {
        throw StateError(
          'طلب البيع القديم لا يتضمن شروطًا معتمدة كاملة؛ ألغِه وأنشئ طلبًا جديدًا',
        );
      }
      if (buyerOwnerId != approvedBuyerOwnerId ||
          salePriceMinor != approvedSalePriceMinor ||
          normalizedDate != approvedSaleDate) {
        throw StateError(
          'لا تطابق بيانات التنفيذ المشتري والسعر والتاريخ المعتمدة؛ ألغِ الطلب وأعد مراجعته بالشروط الصحيحة',
        );
      }
      final existingExecution = await txn.query(
        'property_sale_executions',
        columns: ['id'],
        where: 'sale_review_id = ?',
        whereArgs: [saleReviewId],
        limit: 1,
      );
      if (existingExecution.isNotEmpty) {
        throw StateError('سبق تسجيل إتمام هذا البيع؛ لا تكرر الإجراء');
      }

      final targetType = review['target_type']?.toString();
      final propertyId = (review['property_id'] as num).toInt();
      final unitId = (review['unit_id'] as num?)?.toInt();
      final snapshot = jsonDecode(
        review['target_snapshot_json']?.toString() ?? '{}',
      );
      if (snapshot is! Map || snapshot['seller_owner_id'] is! num) {
        throw StateError(
          'هذا الطلب قديم ولا يحمل هوية المالك عند الطلب؛ ألغِه وأنشئ طلبًا جديدًا للمراجعة',
        );
      }
      final sellerAtRequest = (snapshot['seller_owner_id'] as num).toInt();
      final targetRows = targetType == 'property'
          ? await txn.rawQuery(
              '''
              SELECT p.owner_id AS effective_owner_id, p.name AS property_name,
                p.deed_number
              FROM properties p WHERE p.id = ? LIMIT 1
              ''',
              [propertyId],
            )
          : await txn.rawQuery(
              '''
              SELECT COALESCE(u.owner_id, p.owner_id) AS effective_owner_id,
                p.name AS property_name, p.deed_number, u.unit_number,
                u.owner_id AS unit_owner_id
              FROM units u JOIN properties p ON p.id = u.property_id
              WHERE u.id = ? AND u.property_id = ? LIMIT 1
              ''',
              [unitId, propertyId],
            );
      if (targetRows.isEmpty) throw StateError('العقار أو الوحدة غير موجودة');
      final target = targetRows.single;
      final sellerOwnerId = (target['effective_owner_id'] as num).toInt();
      if (sellerOwnerId != sellerAtRequest) {
        throw StateError(
          'تغير مالك الهدف منذ إنشاء الطلب؛ ألغِ الطلب القديم وأنشئ مراجعة جديدة',
        );
      }
      final buyerRows = await txn.query(
        'owners',
        columns: ['id', 'name'],
        where: 'id = ?',
        whereArgs: [buyerOwnerId],
        limit: 1,
      );
      if (buyerRows.isEmpty) throw StateError('المشتري المحدد غير موجود');
      if (buyerOwnerId == sellerOwnerId) {
        throw ArgumentError('يجب أن يختلف المشتري عن المالك البائع');
      }

      if (targetType == 'property') {
        final independentlyOwnedUnits = await txn.query(
          'units',
          columns: ['id'],
          where: 'property_id = ? AND owner_id IS NOT NULL',
          whereArgs: [propertyId],
          limit: 1,
        );
        if (independentlyOwnedUnits.isNotEmpty) {
          throw StateError(
            'لا يمكن بيع العقار كاملًا ما دامت فيه وحدة ذات ملكية مستقلة؛ راجع نطاق البيع يدويًا',
          );
        }
      }

      final contractRows = await txn.rawQuery(
        targetType == 'property'
            ? '''
              SELECT c.id FROM contracts c JOIN units u ON u.id = c.unit_id
              WHERE u.property_id = ? AND c.status != 'Cancelled'
                AND (DATE(c.end_date) IS NULL
                  OR DATE(c.end_date) >= DATE(?))
              LIMIT 1
            '''
            : '''
              SELECT c.id FROM contracts c
              WHERE c.unit_id = ? AND c.status != 'Cancelled'
                AND (DATE(c.end_date) IS NULL
                  OR DATE(c.end_date) >= DATE(?))
              LIMIT 1
            ''',
        [targetType == 'property' ? propertyId : unitId, normalizedDate],
      );
      if (contractRows.isNotEmpty) {
        throw StateError(
          'لا يمكن إتمام البيع قبل انتهاء أو تسوية العقود القائمة في تاريخ البيع؛ لا ينقل النظام العقود ولا يلغيها تلقائيًا',
        );
      }

      final previousSales = await txn.query(
        'property_sale_executions',
        columns: ['sale_date'],
        where: unitId == null
            ? 'target_type = ? AND property_id = ? AND unit_id IS NULL'
            : 'target_type = ? AND property_id = ? AND unit_id = ?',
        whereArgs: unitId == null
            ? [targetType, propertyId]
            : [targetType, propertyId, unitId],
        orderBy: 'sale_date DESC, id DESC',
        limit: 1,
      );
      if (previousSales.isNotEmpty &&
          normalizedDate.compareTo(
                previousSales.single['sale_date']!.toString(),
              ) <=
              0) {
        throw StateError('يجب أن يكون تاريخ نقل الملكية بعد آخر نقل مسجل');
      }

      final sellerRows = await txn.query(
        'owners',
        columns: ['id', 'name'],
        where: 'id = ?',
        whereArgs: [sellerOwnerId],
        limit: 1,
      );
      if (sellerRows.isEmpty) throw StateError('المالك البائع غير موجود');
      final executedAt = DateTime.now().toIso8601String();
      final executionId = await txn.insert('property_sale_executions', {
        'sale_review_id': saleReviewId,
        'target_type': targetType,
        'property_id': propertyId,
        'unit_id': unitId,
        'seller_owner_id': sellerOwnerId,
        'buyer_owner_id': buyerOwnerId,
        'seller_name_snapshot': sellerRows.single['name']?.toString() ?? '',
        'buyer_name_snapshot': buyerRows.single['name']?.toString() ?? '',
        'sale_price_minor': salePriceMinor,
        'sale_date': normalizedDate,
        'deed_reference': normalizedDeed,
        'execution_reason': normalizedReason,
        'executed_by': actorId,
        'executed_at': executedAt,
      });

      final changed = targetType == 'property'
          ? await txn.update(
              'properties',
              {'owner_id': buyerOwnerId},
              where: 'id = ? AND owner_id = ?',
              whereArgs: [propertyId, sellerOwnerId],
            )
          : await txn.update(
              'units',
              {'owner_id': buyerOwnerId},
              where: target['unit_owner_id'] == null
                  ? 'id = ? AND owner_id IS NULL'
                  : 'id = ? AND owner_id = ?',
              whereArgs: target['unit_owner_id'] == null
                  ? [unitId]
                  : [unitId, target['unit_owner_id']],
            );
      if (changed != 1) throw StateError('تعذر تحديث الملكية؛ أُلغيت العملية');
      await txn.update(
        'property_sale_executions',
        {'transfer_applied_at': DateTime.now().toIso8601String()},
        where: 'id = ? AND transfer_applied_at IS NULL',
        whereArgs: [executionId],
      );
      final eventDetails = {
        'sale_review_id': saleReviewId,
        'target_type': targetType,
        'property_id': propertyId,
        'unit_id': unitId,
        'seller_owner_id': sellerOwnerId,
        'buyer_owner_id': buyerOwnerId,
        'sale_price_minor': salePriceMinor,
        'sale_date': normalizedDate,
        'deed_reference': normalizedDeed,
        'accounting_status': 'pending',
      };
      await _recordPropertySaleExecutionEvent(
        txn,
        saleExecutionId: executionId,
        eventType: 'executed',
        userId: actorId,
        timestamp: executedAt,
        reason: normalizedReason,
        details: eventDetails,
      );
      await _recordAuditTx(
        txn,
        action: 'PROPERTY_SALE_EXECUTED',
        entityType: 'property_sale_execution',
        entityId: executionId,
        amountMinor: salePriceMinor,
        details: eventDetails,
        timestamp: executedAt,
      );
      return executionId;
    });
  }

  Future<int> recordPropertySaleAccounting({
    required int saleExecutionId,
    required int bookValueMinor,
    required int manualJournalEntryId,
    required String note,
    int? supersedesRecordId,
  }) async {
    PermissionRuntime.require('accounting', AppPermissionAction.post);
    final normalizedNote = note.trim();
    if (saleExecutionId <= 0 ||
        bookValueMinor < 0 ||
        manualJournalEntryId <= 0 ||
        normalizedNote.isEmpty ||
        normalizedNote.length > 1000 ||
        (supersedesRecordId != null && supersedesRecordId <= 0)) {
      throw ArgumentError(
        'القيمة الدفترية والقيد اليدوي ومبرر الاعتماد مطلوبة',
      );
    }
    final db = await instance.database;
    return db.transaction((txn) async {
      final actorId = await _requirePropertySaleActorId(txn);
      final executionRows = await txn.query(
        'property_sale_executions',
        columns: ['id', 'sale_review_id', 'sale_date', 'transfer_applied_at'],
        where: 'id = ?',
        whereArgs: [saleExecutionId],
        limit: 1,
      );
      if (executionRows.isEmpty ||
          executionRows.single['transfer_applied_at'] == null) {
        throw StateError('لا توجد عملية بيع منفذة يمكن تسويتها محاسبيًا');
      }
      final journalRows = await txn.rawQuery(
        '''
        SELECT je.is_posted,
          COUNT(jl.id) AS line_count,
          CAST(ROUND(COALESCE(SUM(jl.debit), 0) * 100) AS INTEGER)
            AS debit_minor,
          CAST(ROUND(COALESCE(SUM(jl.credit), 0) * 100) AS INTEGER)
            AS credit_minor
        FROM journal_entries je
        LEFT JOIN journal_lines jl ON jl.journal_entry_id = je.id
        WHERE je.id = ?
        GROUP BY je.id
        ''',
        [manualJournalEntryId],
      );
      if (journalRows.isEmpty || journalRows.single['is_posted'] != 1) {
        throw StateError('يجب ربط قيد يدوي موجود ومرحّل بالفعل');
      }
      final journal = journalRows.single;
      final lineCount = (journal['line_count'] as num).toInt();
      final debitMinor = (journal['debit_minor'] as num).toInt();
      final creditMinor = (journal['credit_minor'] as num).toInt();
      if (lineCount < 2 ||
          debitMinor <= 0 ||
          creditMinor <= 0 ||
          debitMinor != creditMinor) {
        throw StateError('القيد المرتبط غير متوازن أو لا يحتوي أسطرًا كافية');
      }

      final currentRows = await txn.rawQuery(
        '''
        SELECT current_record.id
        FROM property_sale_accounting_records current_record
        WHERE current_record.sale_execution_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM property_sale_accounting_records successor
            WHERE successor.supersedes_record_id = current_record.id
          )
        ORDER BY current_record.id DESC LIMIT 1
        ''',
        [saleExecutionId],
      );
      final currentRecordId = currentRows.isEmpty
          ? null
          : (currentRows.single['id'] as num).toInt();
      if (currentRecordId == null && supersedesRecordId != null) {
        throw StateError('لا يوجد اعتماد سابق يمكن تصحيحه');
      }
      if (currentRecordId != null && supersedesRecordId != currentRecordId) {
        throw StateError(
          'توجد تسوية محاسبية سابقة؛ حدّث البيانات قبل إضافة التصحيح الموثق',
        );
      }

      final timestamp = DateTime.now().toIso8601String();
      final recordId = await txn.insert('property_sale_accounting_records', {
        'sale_execution_id': saleExecutionId,
        'supersedes_record_id': supersedesRecordId,
        'book_value_minor': bookValueMinor,
        'manual_journal_entry_id': manualJournalEntryId,
        'accounting_note': normalizedNote,
        'approved_by': actorId,
        'approved_at': timestamp,
      });
      final eventType = supersedesRecordId == null
          ? 'accounting_approved'
          : 'accounting_corrected';
      final details = {
        'sale_execution_id': saleExecutionId,
        'accounting_record_id': recordId,
        'supersedes_record_id': supersedesRecordId,
        'book_value_minor': bookValueMinor,
        'manual_journal_entry_id': manualJournalEntryId,
        'journal_debit_minor': debitMinor,
        'journal_credit_minor': creditMinor,
      };
      await _recordPropertySaleExecutionEvent(
        txn,
        saleExecutionId: saleExecutionId,
        eventType: eventType,
        userId: actorId,
        timestamp: timestamp,
        reason: normalizedNote,
        details: details,
      );
      await _recordAuditTx(
        txn,
        action: 'PROPERTY_SALE_$eventType',
        entityType: 'property_sale_execution',
        entityId: saleExecutionId,
        amountMinor: bookValueMinor,
        details: details,
        timestamp: timestamp,
      );
      return recordId;
    });
  }

  Future<void> _recordPropertySaleExecutionEvent(
    DatabaseExecutor txn, {
    required int saleExecutionId,
    required String eventType,
    required int userId,
    required String timestamp,
    required String reason,
    required Map<String, Object?> details,
  }) async {
    final eventDetails = <String, Object?>{
      'sale_execution_id': saleExecutionId,
      ...details,
    };
    await txn.insert('property_sale_execution_events', {
      'sale_execution_id': saleExecutionId,
      'event_type': eventType,
      'user_id': userId,
      'created_at': timestamp,
      'reason': reason,
      'details': jsonEncode(eventDetails),
    });
  }

  Future<void> reviewPropertySaleRequest({
    required int saleReviewId,
    required bool accept,
    required String reason,
  }) async {
    PermissionRuntime.require(
      'property_sales',
      AppPermissionAction.reviewApprove,
    );
    final normalizedReason = reason.trim();
    if (saleReviewId <= 0 ||
        normalizedReason.isEmpty ||
        normalizedReason.length > 1000) {
      throw ArgumentError('قرار المراجعة ومبرره الموثق مطلوبان');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final actorId = await _requirePropertySaleActorId(txn);
      final rows = await txn.query(
        'property_sale_reviews',
        columns: [
          'status',
          'property_id',
          'unit_id',
          'target_type',
          'proposed_buyer_owner_id',
          'proposed_amount_minor',
          'proposed_sale_date',
        ],
        where: 'id = ?',
        whereArgs: [saleReviewId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('طلب البيع غير موجود');
      if (rows.single['status'] != 'pending') {
        throw StateError('لا يمكن مراجعة طلب بيع إلا إذا كان بانتظار المراجعة');
      }
      if (accept &&
          (rows.single['proposed_buyer_owner_id'] is! num ||
              rows.single['proposed_amount_minor'] is! num ||
              (rows.single['proposed_amount_minor'] as num) <= 0 ||
              _normalizeSaleDateOnly(
                    rows.single['proposed_sale_date']?.toString(),
                  ) ==
                  null)) {
        throw StateError(
          'لا يمكن اعتماد طلب قديم بلا مشتري وسعر وتاريخ محددين؛ ألغِه وأنشئ طلبًا جديدًا',
        );
      }
      final status = accept ? 'accepted' : 'rejected';
      final timestamp = DateTime.now().toIso8601String();
      final changed = await txn.update(
        'property_sale_reviews',
        {
          'status': status,
          'reviewed_by': actorId,
          'reviewed_at': timestamp,
          'review_reason': normalizedReason,
        },
        where: "id = ? AND status = 'pending'",
        whereArgs: [saleReviewId],
      );
      if (changed != 1) throw StateError('تغيرت حالة الطلب؛ أعد تحميل القائمة');
      await _recordPropertySaleReviewEvent(
        txn,
        saleReviewId: saleReviewId,
        eventType: status,
        userId: actorId,
        timestamp: timestamp,
        reason: normalizedReason,
        details: {
          'status': status,
          'target_type': rows.single['target_type'],
          'property_id': rows.single['property_id'],
          'unit_id': rows.single['unit_id'],
          'proposed_buyer_owner_id': rows.single['proposed_buyer_owner_id'],
          'proposed_amount_minor': rows.single['proposed_amount_minor'],
          'proposed_sale_date': rows.single['proposed_sale_date'],
        },
      );
    });
  }

  Future<void> cancelPropertySaleReview({
    required int saleReviewId,
    required String reason,
  }) async {
    PermissionRuntime.require('property_sales', AppPermissionAction.edit);
    final normalizedReason = reason.trim();
    if (saleReviewId <= 0 ||
        normalizedReason.isEmpty ||
        normalizedReason.length > 1000) {
      throw ArgumentError('سبب إلغاء طلب البيع مطلوب وبحد أقصى 1000 حرف');
    }
    final db = await instance.database;
    await db.transaction((txn) async {
      final actorId = await _requirePropertySaleActorId(txn);
      final rows = await txn.query(
        'property_sale_reviews',
        columns: ['status', 'property_id', 'unit_id', 'target_type'],
        where: 'id = ?',
        whereArgs: [saleReviewId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('طلب البيع غير موجود');
      if (rows.single['status'] != 'pending' &&
          rows.single['status'] != 'accepted') {
        throw StateError('لا يمكن إلغاء الطلب بعد رفضه أو إلغائه');
      }
      final timestamp = DateTime.now().toIso8601String();
      final changed = await txn.update(
        'property_sale_reviews',
        {
          'status': 'cancelled',
          'cancelled_by': actorId,
          'cancelled_at': timestamp,
          'cancel_reason': normalizedReason,
        },
        where: "id = ? AND status IN ('pending', 'accepted')",
        whereArgs: [saleReviewId],
      );
      if (changed != 1) throw StateError('تغيرت حالة الطلب؛ أعد تحميل القائمة');
      await _recordPropertySaleReviewEvent(
        txn,
        saleReviewId: saleReviewId,
        eventType: 'cancelled',
        userId: actorId,
        timestamp: timestamp,
        reason: normalizedReason,
        details: {
          'status': 'cancelled',
          'target_type': rows.single['target_type'],
          'property_id': rows.single['property_id'],
          'unit_id': rows.single['unit_id'],
        },
      );
    });
  }

  Future<void> _recordPropertySaleReviewEvent(
    DatabaseExecutor txn, {
    required int saleReviewId,
    required String eventType,
    required int userId,
    required String timestamp,
    required String reason,
    required Map<String, Object?> details,
  }) async {
    final eventDetails = <String, Object?>{
      'sale_review_id': saleReviewId,
      ...details,
    };
    await txn.insert('property_sale_review_events', {
      'sale_review_id': saleReviewId,
      'event_type': eventType,
      'user_id': userId,
      'created_at': timestamp,
      'reason': reason,
      'details': jsonEncode(eventDetails),
    });
    await _recordAuditTx(
      txn,
      action: 'property_sale_review_$eventType',
      entityType: 'property_sale_review',
      entityId: saleReviewId,
      details: eventDetails,
      timestamp: timestamp,
    );
  }

  // --- SMS Operations ---

  String _newSmsCredentialId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<void> _deleteSmsCredentialIgnoringFailure(String? credentialId) async {
    if (credentialId == null || credentialId.isEmpty) return;
    try {
      await SmsCredentialStoreRegistry.instance.delete(credentialId);
    } catch (_) {
      // An orphaned encrypted vault entry is not reachable without its DB ref.
    }
  }

  Future<void> _writeAndVerifySmsCredential(
    String credentialId,
    String value,
  ) async {
    final store = SmsCredentialStoreRegistry.instance;
    try {
      await store.write(credentialId, value);
      if (await store.read(credentialId) != value) {
        throw StateError('credential verification mismatch');
      }
    } catch (_) {
      await _deleteSmsCredentialIgnoringFailure(credentialId);
      throw StateError('تعذر التحقق من حفظ مفتاح SMS في مخزن Windows الآمن');
    }
  }

  String _smsSettingsSignature(List<Map<String, Object?>> rows) => jsonEncode([
    for (final row in rows)
      [
        row['id'],
        row['api_url'],
        row['api_key'],
        row['api_key_secret_id'],
        row['sender_name'],
        row['reminder_template'],
        row['receipt_template'],
      ],
  ]);

  Future<({String? id, String? value, bool created})> _resolveSmsCredential(
    Database db,
    Map<String, Object?> settings,
  ) async {
    final rowId = settings['id'];
    final credentialStore = SmsCredentialStoreRegistry.instance;
    final storedId = settings['api_key_secret_id']?.toString();
    if (storedId != null && storedId.isNotEmpty) {
      final storedValue = await credentialStore.read(storedId);
      if (storedValue != null && storedValue.isNotEmpty) {
        return (id: storedId, value: storedValue, created: false);
      }
      await db.update(
        'sms_settings',
        {'api_key_secret_id': null},
        where: 'id = ? AND api_key_secret_id = ?',
        whereArgs: [rowId, storedId],
      );
    }

    final legacyValue = settings['api_key']?.toString().trim() ?? '';
    if (legacyValue.isEmpty) return (id: null, value: null, created: false);

    final newId = _newSmsCredentialId();
    await _writeAndVerifySmsCredential(newId, legacyValue);

    await db.execute('PRAGMA secure_delete = ON');
    final activeId = await db.transaction<String?>((txn) async {
      final currentRows = await txn.query(
        'sms_settings',
        columns: ['api_key', 'api_key_secret_id'],
        where: 'id = ?',
        whereArgs: [rowId],
        limit: 1,
      );
      if (currentRows.isEmpty) return null;
      final current = currentRows.single;
      final currentId = current['api_key_secret_id']?.toString();
      if (currentId != null && currentId.isNotEmpty) return currentId;
      if (current['api_key']?.toString().trim() != legacyValue) return null;
      await txn.update(
        'sms_settings',
        {'api_key': null, 'api_key_secret_id': newId},
        where: 'id = ?',
        whereArgs: [rowId],
      );
      return newId;
    });

    if (activeId != newId) {
      await _deleteSmsCredentialIgnoringFailure(newId);
      if (activeId == null) {
        final latestRows = await db.query(
          'sms_settings',
          where: 'id = ?',
          whereArgs: [rowId],
          limit: 1,
        );
        if (latestRows.isEmpty) {
          return (id: null, value: null, created: false);
        }
        return _resolveSmsCredential(db, latestRows.single);
      }
      final latestValue = await credentialStore.read(activeId);
      if (latestValue == null || latestValue.isEmpty) {
        return (id: null, value: null, created: false);
      }
      return (id: activeId, value: latestValue, created: false);
    }

    // secure_delete zeros deleted cell contents; VACUUM also compacts legacy
    // copies from free pages where supported by the active SQLite driver.
    try {
      await db.execute('VACUUM');
    } catch (_) {
      // The DB pointer and secure_delete update are already committed safely.
    }
    return (id: newId, value: legacyValue, created: true);
  }

  Future<List<({String? id, String? value, bool created})>>
  _resolveAllSmsCredentials(Database db) async {
    final rows = await db.query('sms_settings');
    final credentials = <({String? id, String? value, bool created})>[];
    for (final row in rows) {
      credentials.add(await _resolveSmsCredential(db, row));
    }
    return credentials;
  }

  /// Migrates legacy plaintext SMS keys before normal UI or sending begins.
  /// On vault failure the source column remains untouched and callers may
  /// continue with non-SMS functionality; SMS editing exposes a safe warning.
  Future<void> migrateLegacySmsCredentials() async {
    final db = await database;
    await _resolveAllSmsCredentials(db);
  }

  Future<Map<String, dynamic>?> getSmsSettingsForEditing() async {
    PermissionRuntime.require('sms', AppPermissionAction.edit);
    final db = await instance.database;
    final result = await db.query('sms_settings');
    if (result.isNotEmpty) {
      var configured = false;
      var storageUnavailable = false;
      try {
        final credentials = await _resolveAllSmsCredentials(db);
        configured = credentials.first.value != null;
      } catch (_) {
        storageUnavailable = true;
        final first = result.first;
        configured =
            (first['api_key']?.toString().isNotEmpty ?? false) ||
            (first['api_key_secret_id']?.toString().isNotEmpty ?? false);
      }
      final safeSettings = Map<String, dynamic>.from(result.first)
        ..remove('api_key')
        ..remove('api_key_secret_id')
        ..['api_key_configured'] = configured
        ..['api_key_storage_unavailable'] = storageUnavailable;
      return safeSettings;
    }
    return null;
  }

  Future<Map<String, dynamic>?> getSmsSettingsForDashboard() async {
    PermissionRuntime.require('sms', AppPermissionAction.view);
    final db = await instance.database;
    try {
      await _resolveAllSmsCredentials(db);
    } catch (_) {
      // Public dashboard data remains available; sending stays fail-closed.
    }
    final result = await db.query(
      'sms_settings',
      columns: [
        'id',
        'api_url',
        'sender_name',
        'reminder_template',
        'receipt_template',
      ],
    );
    if (result.isNotEmpty) return result.first;
    return null;
  }

  Future<Map<String, dynamic>?> getSmsSettingsForSending() async {
    PermissionRuntime.require('sms', AppPermissionAction.add);
    final db = await instance.database;
    final credentials = await _resolveAllSmsCredentials(db);
    final result = await db.query('sms_settings');
    if (result.isNotEmpty) {
      final credential = credentials.first;
      final safeSettings = Map<String, dynamic>.from(result.first)
        ..remove('api_key_secret_id')
        ..['api_key'] = credential.value;
      return safeSettings;
    }
    return null;
  }

  Future<void> saveSmsSettings(Map<String, dynamic> settings) async {
    PermissionRuntime.require('sms', AppPermissionAction.edit);
    final settingsSnapshot = Map<String, dynamic>.from(settings);
    final previousSave = _smsSettingsWriteQueue;
    final releaseSave = Completer<void>();
    _smsSettingsWriteQueue = releaseSave.future;
    try {
      await previousSave;
      PermissionRuntime.require('sms', AppPermissionAction.edit);
      await _saveSmsSettingsSerialized(settingsSnapshot);
    } finally {
      releaseSave.complete();
    }
  }

  Future<void> _saveSmsSettingsSerialized(Map<String, dynamic> settings) async {
    final db = await instance.database;
    final initialRows = await db.query('sms_settings', orderBy: 'id ASC');
    final requestedKey = settings['api_key']?.toString().trim() ?? '';
    final clearKey = settings['clear_api_key'] == true;
    final mustResolveExisting = requestedKey.isEmpty && !clearKey;
    final credentials = mustResolveExisting
        ? await _resolveAllSmsCredentials(db)
        : <({String? id, String? value, bool created})>[];
    final existingRows = mustResolveExisting
        ? await db.query('sms_settings', orderBy: 'id ASC')
        : initialRows;
    if (mustResolveExisting &&
        (credentials.length != existingRows.length ||
            List<int>.generate(credentials.length, (index) => index).any(
              (index) =>
                  credentials[index].id !=
                  (existingRows[index]['api_key_secret_id']?.toString()),
            ))) {
      throw StateError('تغيرت إعدادات SMS أثناء قراءتها؛ أعد تحميل الشاشة');
    }
    final expectedSignature = _smsSettingsSignature(existingRows);
    final existing = existingRows.isEmpty ? null : existingRows.first;
    final oldCredential = existing == null
        ? (id: null, value: null, created: false)
        : mustResolveExisting
        ? credentials.first
        : (
            id: existing['api_key_secret_id']?.toString(),
            value: null,
            created: false,
          );
    final oldCredentialIds = <String>{
      ...initialRows
          .map((row) => row['api_key_secret_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty),
      ...existingRows
          .map((row) => row['api_key_secret_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty),
      ...credentials.map((credential) => credential.id).whereType<String>(),
    };
    String? nextCredentialId = mustResolveExisting ? oldCredential.id : null;
    var createdCredential = false;

    if (requestedKey.isNotEmpty) {
      nextCredentialId = _newSmsCredentialId();
      await _writeAndVerifySmsCredential(nextCredentialId, requestedKey);
      createdCredential = true;
    } else if (clearKey) {
      nextCredentialId = null;
    } else if (oldCredential.value == null) {
      throw StateError('أدخل مفتاح API جديدًا قبل حفظ إعدادات الرسائل');
    }

    final values = <String, Object?>{
      'api_url': settings['api_url'],
      'api_key': null,
      'api_key_secret_id': nextCredentialId,
      'sender_name': settings['sender_name'],
      'reminder_template': settings['reminder_template'],
      'receipt_template': settings['receipt_template'],
    };
    try {
      await db.execute('PRAGMA secure_delete = ON');
      await db.transaction((txn) async {
        final latestRows = await txn.query('sms_settings', orderBy: 'id ASC');
        if (_smsSettingsSignature(latestRows) != expectedSignature) {
          throw StateError(
            'تغيرت إعدادات SMS أثناء الحفظ؛ أعد تحميل الشاشة قبل المحاولة',
          );
        }
        await txn.update('sms_settings', {
          'api_key': null,
          'api_key_secret_id': null,
        });
        if (latestRows.isEmpty) {
          await txn.insert('sms_settings', values);
        } else {
          await txn.update(
            'sms_settings',
            values,
            where: 'id = ?',
            whereArgs: [latestRows.first['id']],
          );
        }
      });
    } catch (_) {
      if (createdCredential) {
        await _deleteSmsCredentialIgnoringFailure(nextCredentialId);
      }
      rethrow;
    }
    for (final oldId in oldCredentialIds.difference({?nextCredentialId})) {
      await _deleteSmsCredentialIgnoringFailure(oldId);
    }
  }

  Future<void> insertSmsLog(Map<String, dynamic> log) async {
    PermissionRuntime.require('sms', AppPermissionAction.add);
    final db = await instance.database;
    await db.insert('sms_logs', log);
  }

  Future<List<Map<String, dynamic>>> getAllSmsLogs() async {
    PermissionRuntime.require('sms', AppPermissionAction.view);
    final db = await instance.database;
    return await db.query('sms_logs', orderBy: 'sent_at DESC');
  }

  Future close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
