import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates the append-only owner-settlement link between the payment voucher,
/// owner liability account, cash account, and posted journal entry.
Future<void> createOwnerSettlementSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS owner_settlements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      voucher_id INTEGER NOT NULL UNIQUE,
      owner_id INTEGER NOT NULL,
      owner_account_id INTEGER NOT NULL,
      cash_account_id INTEGER NOT NULL,
      journal_entry_id INTEGER NOT NULL UNIQUE,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      settlement_date TEXT NOT NULL CHECK (DATE(settlement_date) = settlement_date),
      owner_name_snapshot TEXT NOT NULL CHECK (length(trim(owner_name_snapshot)) > 0),
      description TEXT NOT NULL CHECK (length(trim(description)) > 0),
      created_by INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (voucher_id) REFERENCES vouchers(id) ON DELETE RESTRICT,
      FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE RESTRICT,
      FOREIGN KEY (owner_account_id) REFERENCES accounts(id) ON DELETE RESTRICT,
      FOREIGN KEY (cash_account_id) REFERENCES accounts(id) ON DELETE RESTRICT,
      FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id) ON DELETE RESTRICT,
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS owner_settlement_journal_intents (
      journal_entry_id INTEGER PRIMARY KEY,
      owner_id INTEGER NOT NULL,
      owner_account_id INTEGER NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id) ON DELETE CASCADE,
      FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE RESTRICT,
      FOREIGN KEY (owner_account_id) REFERENCES accounts(id) ON DELETE RESTRICT
    )
  ''');

  await db.execute('''
    CREATE INDEX IF NOT EXISTS owner_settlements_owner_date_idx
    ON owner_settlements(owner_id, settlement_date, id)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS owner_settlements_cash_date_idx
    ON owner_settlements(cash_account_id, settlement_date, id)
  ''');

  // A general cash disbursement must not silently act as an unlinked owner
  // payout. Owner payments use their own voucher type and immutable link.
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_account_general_disbursement_block
    BEFORE INSERT ON vouchers
    WHEN NEW.voucher_type = 'صرف عام'
      AND EXISTS (
        SELECT 1
        FROM journal_lines jl
        JOIN owners o ON o.account_id = jl.account_id
        WHERE jl.journal_entry_id = NEW.journal_entry_id
          AND jl.debit > 0
          AND jl.credit = 0
      )
    BEGIN
      SELECT RAISE(ABORT, 'Owner liability disbursements require the owner settlement workflow');
    END
  ''');

  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_intent_valid_insert
    BEFORE INSERT ON owner_settlement_journal_intents
    BEGIN
      SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM journal_entries je
        JOIN owners o ON o.id = NEW.owner_id
        JOIN accounts owner_account ON owner_account.id = o.account_id
        JOIN accounts owner_parent ON owner_parent.id = owner_account.parent_id
        WHERE je.id = NEW.journal_entry_id
          AND je.is_posted = 1
          AND owner_account.id = NEW.owner_account_id
          AND owner_account.account_type = 'Liability'
          AND owner_parent.code = '2101'
          AND NOT EXISTS (
            SELECT 1 FROM accounts child
            WHERE child.parent_id = owner_account.id
          )
          AND (SELECT COUNT(*) FROM owners linked
               WHERE linked.account_id = owner_account.id) = 1
          AND NEW.amount_minor > 0
      ) THEN RAISE(ABORT, 'Owner settlement journal intent is invalid') END;
    END
  ''');

  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_lines_owner_debit_requires_link
    BEFORE INSERT ON journal_lines
    WHEN NEW.debit > 0
      AND EXISTS (SELECT 1 FROM owners o WHERE o.account_id = NEW.account_id)
      AND NOT EXISTS (
        SELECT 1 FROM owner_settlement_journal_intents intent
        WHERE intent.journal_entry_id = NEW.journal_entry_id
          AND intent.owner_account_id = NEW.account_id
          AND intent.amount_minor = CAST(ROUND(NEW.debit * 100) AS INTEGER)
      )
    BEGIN
      SELECT RAISE(ABORT, 'Owner liability debits require a linked owner settlement');
    END
  ''');

  // Require a structurally valid, balanced, posted and funded voucher before
  // its owner-specific immutable link is accepted.
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_valid_insert
    BEFORE INSERT ON owner_settlements
    BEGIN
      SELECT CASE WHEN NOT EXISTS (
        SELECT 1
        FROM owners o
        JOIN accounts owner_account ON owner_account.id = o.account_id
        JOIN accounts owner_parent ON owner_parent.id = owner_account.parent_id
        JOIN accounts cash_account ON cash_account.id = NEW.cash_account_id
        JOIN vouchers v ON v.id = NEW.voucher_id
        JOIN journal_entries je ON je.id = NEW.journal_entry_id
        WHERE o.id = NEW.owner_id
          AND owner_account.id = NEW.owner_account_id
          AND owner_account.account_type = 'Liability'
          AND owner_parent.code = '2101'
          AND owner_account.parent_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM accounts child
            WHERE child.parent_id = owner_account.id
          )
          AND (SELECT COUNT(*) FROM owners linked
               WHERE linked.account_id = owner_account.id) = 1
          AND cash_account.account_type = 'Asset'
          AND cash_account.parent_id IS NOT NULL
          AND cash_account.code LIKE '11%'
          AND EXISTS (
            WITH RECURSIVE cash_ancestors(id, parent_id, code) AS (
              SELECT cash_account.id, cash_account.parent_id, cash_account.code
              UNION ALL
              SELECT parent.id, parent.parent_id, parent.code
              FROM accounts parent
              JOIN cash_ancestors child ON parent.id = child.parent_id
            )
            SELECT 1 FROM cash_ancestors WHERE code = '11'
          )
          AND NOT EXISTS (
            SELECT 1 FROM accounts child
            WHERE child.parent_id = cash_account.id
          )
          AND v.voucher_type = 'صرف مستحقات مالك'
          AND v.voucher_date = NEW.settlement_date
          AND v.party_name = NEW.owner_name_snapshot
          AND CAST(ROUND(v.amount * 100) AS INTEGER) = NEW.amount_minor
          AND v.journal_entry_id = NEW.journal_entry_id
          AND EXISTS (
            SELECT 1 FROM owner_settlement_journal_intents intent
            WHERE intent.journal_entry_id = NEW.journal_entry_id
              AND intent.owner_id = NEW.owner_id
              AND intent.owner_account_id = NEW.owner_account_id
              AND intent.amount_minor = NEW.amount_minor
          )
          AND je.is_posted = 1
          AND je.entry_date = NEW.settlement_date
          AND DATE(NEW.settlement_date) <= DATE('now', 'localtime')
          AND NEW.amount_minor > 0
          AND length(trim(NEW.description)) > 0
          AND (SELECT COUNT(*) FROM journal_lines jl
               WHERE jl.journal_entry_id = NEW.journal_entry_id) = 2
          AND NOT EXISTS (
            SELECT 1 FROM journal_lines jl
            WHERE jl.journal_entry_id = NEW.journal_entry_id
              AND (jl.debit < 0 OR jl.credit < 0
                OR (jl.debit > 0 AND jl.credit > 0)
                OR (jl.debit = 0 AND jl.credit = 0)
                OR ABS(jl.debit * 100 - ROUND(jl.debit * 100)) > 0.000001
                OR ABS(jl.credit * 100 - ROUND(jl.credit * 100)) > 0.000001)
          )
          AND (SELECT SUM(CAST(ROUND(jl.debit * 100) AS INTEGER))
               FROM journal_lines jl
               WHERE jl.journal_entry_id = NEW.journal_entry_id)
              = (SELECT SUM(CAST(ROUND(jl.credit * 100) AS INTEGER))
                 FROM journal_lines jl
                 WHERE jl.journal_entry_id = NEW.journal_entry_id)
          AND EXISTS (
            SELECT 1 FROM journal_lines debit_line
            WHERE debit_line.journal_entry_id = NEW.journal_entry_id
              AND debit_line.account_id = owner_account.id
              AND debit_line.debit > 0
              AND debit_line.credit = 0
              AND debit_line.cost_center_id IS NULL
              AND CAST(ROUND(debit_line.debit * 100) AS INTEGER) = NEW.amount_minor
          )
          AND EXISTS (
            SELECT 1 FROM journal_lines credit_line
            WHERE credit_line.journal_entry_id = NEW.journal_entry_id
              AND credit_line.account_id = cash_account.id
              AND credit_line.credit > 0
              AND credit_line.debit = 0
              AND credit_line.cost_center_id IS NULL
              AND CAST(ROUND(credit_line.credit * 100) AS INTEGER) = NEW.amount_minor
          )
          AND NEW.cash_account_id != NEW.owner_account_id
          AND NEW.created_by > 0
          AND length(trim(NEW.created_at)) > 0
          AND NEW.owner_name_snapshot = o.name
      ) THEN RAISE(ABORT, 'Owner settlement does not match its owner, voucher, accounts, or journal') END;

      SELECT CASE WHEN NEW.amount_minor > COALESCE((
        SELECT SUM(CAST(ROUND(jl.credit * 100) AS INTEGER)
                 - CAST(ROUND(jl.debit * 100) AS INTEGER))
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = NEW.owner_account_id
          AND je.is_posted = 1
          AND je.id != NEW.journal_entry_id
      ), 0) THEN RAISE(ABORT, 'Owner settlement exceeds the posted owner payable balance') END;

      SELECT CASE WHEN NEW.amount_minor > COALESCE((
        SELECT SUM(CAST(ROUND(jl.credit * 100) AS INTEGER)
                 - CAST(ROUND(jl.debit * 100) AS INTEGER))
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = NEW.owner_account_id
          AND je.is_posted = 1
          AND je.id != NEW.journal_entry_id
          AND DATE(je.entry_date) <= DATE(NEW.settlement_date)
      ), 0) THEN RAISE(ABORT, 'Owner settlement exceeds the owner payable balance on its date') END;

      SELECT CASE WHEN NEW.amount_minor > COALESCE((
        SELECT SUM(CAST(ROUND(jl.debit * 100) AS INTEGER)
                 - CAST(ROUND(jl.credit * 100) AS INTEGER))
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = NEW.cash_account_id
          AND je.is_posted = 1
          AND je.id != NEW.journal_entry_id
      ), 0) THEN RAISE(ABORT, 'Owner settlement exceeds the posted cash balance') END;

      SELECT CASE WHEN NEW.amount_minor > COALESCE((
        SELECT SUM(CAST(ROUND(jl.debit * 100) AS INTEGER)
                 - CAST(ROUND(jl.credit * 100) AS INTEGER))
        FROM journal_lines jl
        JOIN journal_entries je ON je.id = jl.journal_entry_id
        WHERE jl.account_id = NEW.cash_account_id
          AND je.is_posted = 1
          AND je.id != NEW.journal_entry_id
          AND DATE(je.entry_date) <= DATE(NEW.settlement_date)
      ), 0) THEN RAISE(ABORT, 'Owner settlement exceeds the cash balance on its date') END;
    END
  ''');

  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_consume_journal_intent
    AFTER INSERT ON owner_settlements
    BEGIN
      DELETE FROM owner_settlement_journal_intents
      WHERE journal_entry_id = NEW.journal_entry_id;
    END
  ''');

  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlements_no_update
    BEFORE UPDATE ON owner_settlements
    BEGIN
      SELECT RAISE(ABORT, 'Owner settlement records are immutable; post a correcting entry');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlements_no_delete
    BEFORE DELETE ON owner_settlements
    BEGIN
      SELECT RAISE(ABORT, 'Owner settlement records cannot be deleted');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_vouchers_no_update
    BEFORE UPDATE ON vouchers
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.voucher_id = OLD.id
    ) OR OLD.voucher_type = 'صرف مستحقات مالك'
    BEGIN
      SELECT RAISE(ABORT, 'An owner settlement voucher cannot be edited');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_vouchers_no_delete
    BEFORE DELETE ON vouchers
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.voucher_id = OLD.id
    ) OR OLD.voucher_type = 'صرف مستحقات مالك'
    BEGIN
      SELECT RAISE(ABORT, 'An owner settlement voucher cannot be deleted');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_entries_no_update
    BEFORE UPDATE ON journal_entries
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.journal_entry_id = OLD.id
    )
    BEGIN
      SELECT RAISE(ABORT, 'An owner settlement journal entry cannot be edited');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_entries_no_delete
    BEFORE DELETE ON journal_entries
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.journal_entry_id = OLD.id
    )
    BEGIN
      SELECT RAISE(ABORT, 'An owner settlement journal entry cannot be deleted');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_lines_no_update
    BEFORE UPDATE ON journal_lines
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.journal_entry_id = OLD.journal_entry_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'Owner settlement journal lines are immutable');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER IF NOT EXISTS owner_settlement_journal_lines_no_delete
    BEFORE DELETE ON journal_lines
    WHEN EXISTS (
      SELECT 1 FROM owner_settlements s WHERE s.journal_entry_id = OLD.journal_entry_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'Owner settlement journal lines cannot be deleted');
    END
  ''');
}
