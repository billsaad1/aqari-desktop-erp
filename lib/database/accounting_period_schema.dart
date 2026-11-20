import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SQLite schema and guards for accounting-period lifecycle management.
///
/// The guards are deliberately attached to journal headers and lines rather
/// than individual posting screens so every current and future posting path
/// shares the same locked-period barrier.
class AccountingPeriodSchema {
  AccountingPeriodSchema._();

  static Future<void> install(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounting_periods (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'open'
          CHECK (status IN ('open', 'locked', 'closed')),
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by_user_id INTEGER NOT NULL,
        CHECK (length(start_date) = 10 AND date(start_date) = start_date),
        CHECK (length(end_date) = 10 AND date(end_date) = end_date),
        CHECK (substr(start_date, 1, 4) != '0000'),
        CHECK (substr(end_date, 1, 4) != '0000'),
        CHECK (start_date <= end_date)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounting_period_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period_id INTEGER NOT NULL,
        action TEXT NOT NULL
          CHECK (action IN ('created', 'locked', 'closed', 'reopened')),
        actor_user_id INTEGER NOT NULL,
        actor_name TEXT NOT NULL CHECK (length(trim(actor_name)) > 0),
        reason TEXT,
        readiness_summary TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CHECK (action != 'reopened' OR length(trim(COALESCE(reason, ''))) > 0),
        FOREIGN KEY (period_id) REFERENCES accounting_periods (id)
          ON DELETE RESTRICT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS accounting_period_events_period_idx
      ON accounting_period_events (period_id, id)
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_initially_open
      BEFORE INSERT ON accounting_periods
      WHEN NEW.status != 'open'
      BEGIN
        SELECT RAISE(ABORT, 'accounting periods must start open');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_no_overlap_insert
      BEFORE INSERT ON accounting_periods
      WHEN EXISTS (
        SELECT 1 FROM accounting_periods existing
        WHERE NEW.start_date <= existing.end_date
          AND NEW.end_date >= existing.start_date
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting periods cannot overlap');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_no_overlap_update
      BEFORE UPDATE OF start_date, end_date ON accounting_periods
      WHEN EXISTS (
        SELECT 1 FROM accounting_periods existing
        WHERE existing.id != OLD.id
          AND NEW.start_date <= existing.end_date
          AND NEW.end_date >= existing.start_date
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting periods cannot overlap');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_identity_immutable
      BEFORE UPDATE OF start_date, end_date, created_at, created_by_user_id
      ON accounting_periods
      BEGIN
        SELECT RAISE(ABORT, 'accounting period identity is immutable');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_valid_transition
      BEFORE UPDATE OF status ON accounting_periods
      WHEN NOT (
        (OLD.status = 'open' AND NEW.status = 'locked') OR
        (OLD.status = 'locked' AND NEW.status = 'closed') OR
        (OLD.status IN ('locked', 'closed') AND NEW.status = 'open')
      )
      BEGIN
        SELECT RAISE(ABORT, 'invalid accounting period transition');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_transition_audited
      BEFORE UPDATE OF status ON accounting_periods
      WHEN COALESCE((
        SELECT action
        FROM accounting_period_events
        WHERE period_id = OLD.id
        ORDER BY id DESC
        LIMIT 1
      ), '') != CASE
        WHEN OLD.status = 'open' AND NEW.status = 'locked' THEN 'locked'
        WHEN OLD.status = 'locked' AND NEW.status = 'closed' THEN 'closed'
        WHEN OLD.status IN ('locked', 'closed') AND NEW.status = 'open'
          THEN 'reopened'
        ELSE ''
      END
      BEGIN
        SELECT RAISE(ABORT, 'accounting period transition requires an event');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_periods_no_delete
      BEFORE DELETE ON accounting_periods
      BEGIN
        SELECT RAISE(ABORT, 'accounting periods cannot be deleted');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_events_state_valid
      BEFORE INSERT ON accounting_period_events
      WHEN NOT EXISTS (
        SELECT 1 FROM accounting_periods p
        WHERE p.id = NEW.period_id
          AND (
            (NEW.action = 'created' AND p.status = 'open'
              AND NOT EXISTS (
                SELECT 1 FROM accounting_period_events old
                WHERE old.period_id = p.id
              )) OR
            (NEW.action = 'locked' AND p.status = 'open') OR
            (NEW.action = 'closed' AND p.status = 'locked') OR
            (NEW.action = 'reopened' AND p.status IN ('locked', 'closed')
              AND length(trim(COALESCE(NEW.reason, ''))) > 0)
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting period event does not match state');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_events_no_update
      BEFORE UPDATE ON accounting_period_events
      BEGIN
        SELECT RAISE(ABORT, 'accounting period events are append-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_events_no_delete
      BEFORE DELETE ON accounting_period_events
      BEGIN
        SELECT RAISE(ABORT, 'accounting period events are append-only');
      END
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_journal_insert_guard
      BEFORE INSERT ON journal_entries
      BEGIN
        SELECT CASE WHEN
          length(substr(NEW.entry_date, 1, 10)) != 10 OR
          date(substr(NEW.entry_date, 1, 10)) IS NULL OR
          date(substr(NEW.entry_date, 1, 10)) != substr(NEW.entry_date, 1, 10)
        THEN RAISE(ABORT, 'journal entry date must be a valid calendar date') END;
        SELECT CASE WHEN EXISTS (
          SELECT 1 FROM accounting_periods p
          WHERE p.status IN ('locked', 'closed')
            AND substr(NEW.entry_date, 1, 10)
              BETWEEN p.start_date AND p.end_date
        ) THEN RAISE(ABORT, 'accounting period is locked') END;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_journal_update_guard
      BEFORE UPDATE ON journal_entries
      BEGIN
        SELECT CASE WHEN
          length(substr(NEW.entry_date, 1, 10)) != 10 OR
          date(substr(NEW.entry_date, 1, 10)) IS NULL OR
          date(substr(NEW.entry_date, 1, 10)) != substr(NEW.entry_date, 1, 10)
        THEN RAISE(ABORT, 'journal entry date must be a valid calendar date') END;
        SELECT CASE WHEN EXISTS (
          SELECT 1 FROM accounting_periods p
          WHERE p.status IN ('locked', 'closed')
            AND (
              substr(OLD.entry_date, 1, 10)
                BETWEEN p.start_date AND p.end_date OR
              substr(NEW.entry_date, 1, 10)
                BETWEEN p.start_date AND p.end_date
            )
        ) THEN RAISE(ABORT, 'accounting period is locked') END;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_journal_delete_guard
      BEFORE DELETE ON journal_entries
      WHEN EXISTS (
        SELECT 1 FROM accounting_periods p
        WHERE p.status IN ('locked', 'closed')
          AND substr(OLD.entry_date, 1, 10)
            BETWEEN p.start_date AND p.end_date
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting period is locked');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_lines_insert_guard
      BEFORE INSERT ON journal_lines
      WHEN EXISTS (
        SELECT 1
        FROM journal_entries je
        JOIN accounting_periods p
          ON substr(je.entry_date, 1, 10) BETWEEN p.start_date AND p.end_date
        WHERE je.id = NEW.journal_entry_id
          AND p.status IN ('locked', 'closed')
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting period is locked');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_lines_update_guard
      BEFORE UPDATE ON journal_lines
      WHEN EXISTS (
        SELECT 1
        FROM journal_entries je
        JOIN accounting_periods p
          ON substr(je.entry_date, 1, 10) BETWEEN p.start_date AND p.end_date
        WHERE je.id IN (OLD.journal_entry_id, NEW.journal_entry_id)
          AND p.status IN ('locked', 'closed')
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting period is locked');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS accounting_period_lines_delete_guard
      BEFORE DELETE ON journal_lines
      WHEN EXISTS (
        SELECT 1
        FROM journal_entries je
        JOIN accounting_periods p
          ON substr(je.entry_date, 1, 10) BETWEEN p.start_date AND p.end_date
        WHERE je.id = OLD.journal_entry_id
          AND p.status IN ('locked', 'closed')
      )
      BEGIN
        SELECT RAISE(ABORT, 'accounting period is locked');
      END
    ''');
  }
}
