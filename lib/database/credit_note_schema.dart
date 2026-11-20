import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema and SQLite guards for the internal credit-note lifecycle.
/// Legacy rows are retained as `legacy_review`; no posting is inferred.
class CreditNoteSchema {
  CreditNoteSchema._();

  static Future<void> createTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE credit_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_id INTEGER,
        note_date TEXT NOT NULL,
        amount REAL NOT NULL,
        reason TEXT,
        status TEXT NOT NULL DEFAULT 'draft'
          CHECK (status IN ('draft', 'posted', 'reversed', 'legacy_review')),
        net_amount_minor INTEGER NOT NULL DEFAULT 0 CHECK (net_amount_minor >= 0),
        tax_amount_minor INTEGER NOT NULL DEFAULT 0 CHECK (tax_amount_minor >= 0),
        total_amount_minor INTEGER NOT NULL DEFAULT 0 CHECK (total_amount_minor >= 0),
        tax_rate_snapshot REAL,
        tax_account_id INTEGER REFERENCES accounts (id),
        journal_entry_id INTEGER UNIQUE REFERENCES journal_entries (id),
        reversal_journal_entry_id INTEGER UNIQUE REFERENCES journal_entries (id),
        reversal_reason TEXT,
        created_by INTEGER REFERENCES users (id),
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        posted_by INTEGER REFERENCES users (id),
        posted_at TEXT,
        reversed_by INTEGER REFERENCES users (id),
        reversed_at TEXT,
        CHECK (net_amount_minor + tax_amount_minor = total_amount_minor),
        FOREIGN KEY (invoice_id) REFERENCES tax_invoices (id)
      )
    ''');
  }

  /// Adds v30 fields without interpreting the legacy `amount` or inventing
  /// journal, tax, rate, account, or source provenance for existing rows.
  static Future<void> upgradeToV30(DatabaseExecutor db) async {
    final columns = (await db.rawQuery('PRAGMA table_info("credit_notes")'))
        .map((row) => row['name']?.toString())
        .toSet();
    const additions = <String, String>{
      'reason': 'TEXT',
      'status': "TEXT NOT NULL DEFAULT 'legacy_review'",
      'net_amount_minor': 'INTEGER NOT NULL DEFAULT 0',
      'tax_amount_minor': 'INTEGER NOT NULL DEFAULT 0',
      'total_amount_minor': 'INTEGER NOT NULL DEFAULT 0',
      'tax_rate_snapshot': 'REAL',
      'tax_account_id': 'INTEGER REFERENCES accounts (id)',
      'journal_entry_id': 'INTEGER REFERENCES journal_entries (id)',
      'reversal_journal_entry_id': 'INTEGER REFERENCES journal_entries (id)',
      'reversal_reason': 'TEXT',
      'created_by': 'INTEGER REFERENCES users (id)',
      'created_at': 'TEXT',
      'posted_by': 'INTEGER REFERENCES users (id)',
      'posted_at': 'TEXT',
      'reversed_by': 'INTEGER REFERENCES users (id)',
      'reversed_at': 'TEXT',
    };
    for (final entry in additions.entries) {
      if (!columns.contains(entry.key)) {
        await db.execute(
          'ALTER TABLE credit_notes ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
    await db.execute('''
      UPDATE credit_notes
      SET status = CASE
        WHEN status IS NULL OR status = '' THEN 'legacy_review'
        ELSE status
      END,
      created_at = COALESCE(created_at, CURRENT_TIMESTAMP)
      WHERE status IS NULL OR status = '' OR created_at IS NULL
    ''');

    final refundColumns = (await db.rawQuery(
      'PRAGMA table_info("refund_allocations")',
    )).map((row) => row['name']?.toString()).toSet();
    if (refundColumns.isNotEmpty && !refundColumns.contains('credit_note_id')) {
      await db.execute('''
        ALTER TABLE refund_allocations
        ADD COLUMN credit_note_id INTEGER REFERENCES credit_notes (id)
      ''');
    }
    await installGuards(db);
  }

  static Future<void> installGuards(DatabaseExecutor db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS credit_notes_invoice_status_idx
      ON credit_notes(invoice_id, status, id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS refund_allocations_credit_note_idx
      ON refund_allocations(credit_note_id)
      WHERE credit_note_id IS NOT NULL
    ''');
    await db.execute('DROP VIEW IF EXISTS credit_note_refund_balances');
    await db.execute('''
      CREATE VIEW credit_note_refund_balances AS
      WITH base AS (
        SELECT note.id, note.invoice_id, note.note_date,
          note.net_amount_minor, note.tax_amount_minor,
          note.total_amount_minor, contract.tenant_id,
          CAST(ROUND(invoice.total_amount * 100) AS INTEGER)
            AS invoice_total_minor,
          COALESCE((
            SELECT SUM(balance.remaining_minor)
            FROM collection_allocations source
            JOIN collection_allocation_balances balance
              ON balance.id = source.id
            WHERE source.invoice_id = note.invoice_id
          ), 0) AS paid_minor,
          COALESCE((
            SELECT SUM(previous.total_amount_minor)
            FROM credit_notes previous
            WHERE previous.invoice_id = note.invoice_id
              AND previous.status = 'posted'
              AND (previous.posted_at < note.posted_at
                OR (previous.posted_at = note.posted_at AND previous.id < note.id))
          ), 0) AS prior_net_credit_minor,
          COALESCE(used.refunded_minor, 0) AS refunded_minor,
          COALESCE(used.refunded_net_minor, 0) AS refunded_net_minor,
          COALESCE(used.refunded_tax_minor, 0) AS refunded_tax_minor
        FROM credit_notes note
        JOIN tax_invoices invoice ON invoice.id = note.invoice_id
        JOIN contracts contract ON contract.id = invoice.contract_id
        LEFT JOIN (
          SELECT credit_note_id,
            SUM(amount_minor) AS refunded_minor,
            SUM(rent_amount_minor) AS refunded_net_minor,
            SUM(tax_amount_minor) AS refunded_tax_minor
          FROM refund_allocations
          WHERE credit_note_id IS NOT NULL
          GROUP BY credit_note_id
        ) used ON used.credit_note_id = note.id
        WHERE note.status = 'posted'
      ), applied AS (
        SELECT base.*,
          MIN(total_amount_minor,
            MAX(invoice_total_minor - paid_minor - prior_net_credit_minor, 0)
          ) AS applied_minor
        FROM base
      ), split AS (
        SELECT applied.*,
          CASE
            WHEN applied_minor = total_amount_minor THEN tax_amount_minor
            WHEN total_amount_minor > 0 THEN CAST(ROUND(
              applied_minor * 1.0 * tax_amount_minor / total_amount_minor
            ) AS INTEGER)
            ELSE 0
          END AS applied_tax_minor
        FROM applied
      )
      SELECT split.*,
        MAX(total_amount_minor - applied_minor - refunded_minor, 0)
          AS refundable_minor,
        MAX(net_amount_minor - (applied_minor - applied_tax_minor)
          - refunded_net_minor, 0) AS refundable_net_minor,
        MAX(tax_amount_minor - applied_tax_minor - refunded_tax_minor, 0)
          AS refundable_tax_minor
      FROM split
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_initial_draft
      BEFORE INSERT ON credit_notes
      WHEN NEW.status != 'draft'
        OR NEW.invoice_id IS NULL
        OR NEW.total_amount_minor <= 0
        OR NEW.net_amount_minor < 0
        OR NEW.tax_amount_minor < 0
        OR NEW.net_amount_minor + NEW.tax_amount_minor != NEW.total_amount_minor
        OR TRIM(COALESCE(NEW.reason, '')) = ''
      BEGIN
        SELECT RAISE(ABORT, 'new credit note must be a complete draft linked to an invoice');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_valid_transition
      BEFORE UPDATE OF status ON credit_notes
      WHEN NOT (
        (OLD.status = 'draft' AND NEW.status IN ('draft', 'posted'))
        OR (OLD.status = 'posted' AND NEW.status IN ('posted', 'reversed'))
        OR (OLD.status IN ('reversed', 'legacy_review') AND NEW.status = OLD.status)
      )
      BEGIN
        SELECT RAISE(ABORT, 'invalid credit note state transition');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_post_requires_journal
      BEFORE UPDATE OF status ON credit_notes
      WHEN OLD.status = 'draft' AND NEW.status = 'posted'
        AND (
          NEW.journal_entry_id IS NULL
          OR NEW.posted_at IS NULL
          OR NOT EXISTS (
            SELECT 1 FROM journal_entries entry
            WHERE entry.id = NEW.journal_entry_id AND entry.is_posted = 1
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'posted credit note requires a posted linked journal and timestamp');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_reversal_requires_journal
      BEFORE UPDATE OF status ON credit_notes
      WHEN OLD.status = 'posted' AND NEW.status = 'reversed'
        AND (NEW.reversal_journal_entry_id IS NULL
          OR NEW.reversed_at IS NULL
          OR TRIM(COALESCE(NEW.reversal_reason, '')) = ''
          OR NOT EXISTS (
            SELECT 1 FROM journal_entries entry
            WHERE entry.id = NEW.reversal_journal_entry_id
              AND entry.is_posted = 1
          ))
      BEGIN
        SELECT RAISE(ABORT, 'reversed credit note requires a posted reversal and reason');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_posted_immutable
      BEFORE UPDATE ON credit_notes
      WHEN OLD.status IN ('posted', 'reversed', 'legacy_review')
        AND NOT (
          OLD.status = 'posted'
          AND NEW.status = 'reversed'
          AND NEW.id = OLD.id
          AND NEW.invoice_id = OLD.invoice_id
          AND NEW.note_date = OLD.note_date
          AND NEW.amount = OLD.amount
          AND NEW.reason = OLD.reason
          AND NEW.net_amount_minor = OLD.net_amount_minor
          AND NEW.tax_amount_minor = OLD.tax_amount_minor
          AND NEW.total_amount_minor = OLD.total_amount_minor
          AND NEW.tax_rate_snapshot IS OLD.tax_rate_snapshot
          AND NEW.tax_account_id IS OLD.tax_account_id
          AND NEW.journal_entry_id IS OLD.journal_entry_id
          AND NEW.created_by IS OLD.created_by
          AND NEW.created_at IS OLD.created_at
          AND NEW.posted_by IS OLD.posted_by
          AND NEW.posted_at IS OLD.posted_at
          AND NEW.reversal_journal_entry_id IS NOT NULL
          AND NEW.reversed_at IS NOT NULL
          AND TRIM(COALESCE(NEW.reversal_reason, '')) != ''
        )
      BEGIN
        SELECT RAISE(ABORT, 'posted and legacy credit notes are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_no_delete
      BEFORE DELETE ON credit_notes
      WHEN OLD.status != 'draft'
      BEGIN
        SELECT RAISE(ABORT, 'posted and legacy credit notes cannot be deleted');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_journal_entries_no_update
      BEFORE UPDATE ON journal_entries
      WHEN EXISTS (
        SELECT 1 FROM credit_notes note
        WHERE note.journal_entry_id = OLD.id
          OR note.reversal_journal_entry_id = OLD.id
      )
      BEGIN
        SELECT RAISE(ABORT, 'credit note journals are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_journal_entries_no_delete
      BEFORE DELETE ON journal_entries
      WHEN EXISTS (
        SELECT 1 FROM credit_notes note
        WHERE note.journal_entry_id = OLD.id
          OR note.reversal_journal_entry_id = OLD.id
      )
      BEGIN
        SELECT RAISE(ABORT, 'credit note journals are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_journal_lines_no_update
      BEFORE UPDATE ON journal_lines
      WHEN EXISTS (
        SELECT 1 FROM credit_notes note
        WHERE note.journal_entry_id = OLD.journal_entry_id
          OR note.reversal_journal_entry_id = OLD.journal_entry_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'credit note journal lines are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS credit_notes_journal_lines_no_delete
      BEFORE DELETE ON journal_lines
      WHEN EXISTS (
        SELECT 1 FROM credit_notes note
        WHERE note.journal_entry_id = OLD.journal_entry_id
          OR note.reversal_journal_entry_id = OLD.journal_entry_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'credit note journal lines are immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_credit_note_match
      BEFORE INSERT ON refund_allocations
      WHEN NEW.credit_note_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM credit_notes note
        JOIN tax_invoices invoice ON invoice.id = note.invoice_id
        JOIN contracts contract ON contract.id = invoice.contract_id
        JOIN collection_allocations source ON source.id = NEW.collection_allocation_id
        JOIN vouchers refund ON refund.id = NEW.refund_voucher_id
        JOIN vouchers receipt ON receipt.id = source.voucher_id
        WHERE note.id = NEW.credit_note_id
          AND note.status = 'posted'
          AND source.invoice_id = note.invoice_id
          AND contract.tenant_id = refund.tenant_id
          AND refund.tenant_id = receipt.tenant_id
          AND refund.voucher_type = 'صرف مستأجر'
          AND receipt.voucher_type = 'قبض مستأجر'
      )
      BEGIN
        SELECT RAISE(ABORT, 'credit note refund must match the posted note, invoice, and tenant');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_credit_note_cap
      BEFORE INSERT ON refund_allocations
      WHEN NEW.credit_note_id IS NOT NULL AND (
        NEW.amount_minor > COALESCE((SELECT refundable_minor
          FROM credit_note_refund_balances
          WHERE id = NEW.credit_note_id), 0)
        OR NEW.rent_amount_minor > COALESCE((SELECT refundable_net_minor
          FROM credit_note_refund_balances
          WHERE id = NEW.credit_note_id), 0)
        OR NEW.tax_amount_minor > COALESCE((SELECT refundable_tax_minor
          FROM credit_note_refund_balances
          WHERE id = NEW.credit_note_id), 0)
      )
      BEGIN
        SELECT RAISE(ABORT, 'refund exceeds the unused credit note amount');
      END
    ''');
  }
}
