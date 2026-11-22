import 'package:sqflite_common_ffi/sqflite_ffi.dart';

abstract final class FinancialQueryIndexesSchema {
  static const indexNames = <String>{
    'idx_journal_lines_entry',
    'idx_journal_lines_account_entry',
    'idx_vouchers_journal_entry',
    'idx_journal_entries_date',
    'idx_contract_installments_contract_due',
    'idx_contract_installments_due_date',
  };

  static Future<void> install(DatabaseExecutor db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_journal_lines_entry
      ON journal_lines (journal_entry_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_journal_lines_account_entry
      ON journal_lines (account_id, journal_entry_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_vouchers_journal_entry
      ON vouchers (journal_entry_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_journal_entries_date
      ON journal_entries (entry_date)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contract_installments_contract_due
      ON contract_installments (contract_id, due_date)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contract_installments_due_date
      ON contract_installments (due_date)
    ''');
  }
}
