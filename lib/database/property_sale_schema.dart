import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates the append-only execution and manual-accounting records for sales.
/// The sale review itself remains a separate, non-financial approval step.
Future<void> createPropertySaleExecutionSchema(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS property_sale_executions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_review_id INTEGER NOT NULL UNIQUE,
      target_type TEXT NOT NULL CHECK (target_type IN ('property', 'unit')),
      property_id INTEGER NOT NULL,
      unit_id INTEGER,
      seller_owner_id INTEGER NOT NULL,
      buyer_owner_id INTEGER NOT NULL,
      seller_name_snapshot TEXT NOT NULL,
      buyer_name_snapshot TEXT NOT NULL,
      sale_price_minor INTEGER NOT NULL CHECK (sale_price_minor > 0),
      sale_date TEXT NOT NULL,
      deed_reference TEXT NOT NULL CHECK (length(trim(deed_reference)) BETWEEN 1 AND 200),
      execution_reason TEXT NOT NULL CHECK (length(trim(execution_reason)) BETWEEN 1 AND 1000),
      executed_by INTEGER NOT NULL,
      executed_at TEXT NOT NULL,
      transfer_applied_at TEXT,
      FOREIGN KEY (sale_review_id) REFERENCES property_sale_reviews (id) ON DELETE RESTRICT,
      FOREIGN KEY (property_id) REFERENCES properties (id) ON DELETE RESTRICT,
      FOREIGN KEY (unit_id) REFERENCES units (id) ON DELETE RESTRICT,
      FOREIGN KEY (seller_owner_id) REFERENCES owners (id) ON DELETE RESTRICT,
      FOREIGN KEY (buyer_owner_id) REFERENCES owners (id) ON DELETE RESTRICT,
      FOREIGN KEY (executed_by) REFERENCES users (id) ON DELETE RESTRICT,
      CHECK (seller_owner_id != buyer_owner_id),
      CHECK (DATE(sale_date) = sale_date),
      CHECK ((target_type = 'property' AND unit_id IS NULL)
        OR (target_type = 'unit' AND unit_id IS NOT NULL))
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS property_sale_execution_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_execution_id INTEGER NOT NULL,
      event_type TEXT NOT NULL CHECK (event_type IN (
        'executed', 'accounting_approved', 'accounting_corrected'
      )),
      user_id INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      reason TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 1000),
      details TEXT,
      FOREIGN KEY (sale_execution_id) REFERENCES property_sale_executions (id) ON DELETE RESTRICT,
      FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE RESTRICT
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS property_sale_accounting_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_execution_id INTEGER NOT NULL,
      supersedes_record_id INTEGER,
      book_value_minor INTEGER NOT NULL CHECK (book_value_minor >= 0),
      manual_journal_entry_id INTEGER NOT NULL,
      accounting_note TEXT NOT NULL CHECK (length(trim(accounting_note)) BETWEEN 1 AND 1000),
      approved_by INTEGER NOT NULL,
      approved_at TEXT NOT NULL,
      FOREIGN KEY (sale_execution_id) REFERENCES property_sale_executions (id) ON DELETE RESTRICT,
      FOREIGN KEY (supersedes_record_id) REFERENCES property_sale_accounting_records (id) ON DELETE RESTRICT,
      FOREIGN KEY (manual_journal_entry_id) REFERENCES journal_entries (id) ON DELETE RESTRICT,
      FOREIGN KEY (approved_by) REFERENCES users (id) ON DELETE RESTRICT
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS property_sale_executions_property_date_idx
    ON property_sale_executions(property_id, sale_date DESC, id DESC)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS property_sale_executions_unit_date_idx
    ON property_sale_executions(unit_id, sale_date DESC, id DESC)
    WHERE unit_id IS NOT NULL
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS property_sale_execution_events_execution_idx
    ON property_sale_execution_events(sale_execution_id, id)
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS property_sale_accounting_root_unique
    ON property_sale_accounting_records(sale_execution_id)
    WHERE supersedes_record_id IS NULL
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS property_sale_accounting_successor_unique
    ON property_sale_accounting_records(supersedes_record_id)
    WHERE supersedes_record_id IS NOT NULL
  ''');

  for (final trigger in const [
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
  ]) {
    await db.execute('DROP TRIGGER IF EXISTS $trigger');
  }

  // A completed execution closes the accepted review, so it no longer blocks a
  // later, separately reviewed sale of the same asset.
  await db.execute(
    'DROP INDEX IF EXISTS property_sale_reviews_property_open_unique',
  );
  await db.execute(
    'DROP INDEX IF EXISTS property_sale_reviews_unit_open_unique',
  );
  await db.execute(
    'DROP TRIGGER IF EXISTS property_sale_reviews_no_overlap_insert',
  );
  await db.execute(
    'DROP TRIGGER IF EXISTS property_sale_reviews_no_overlap_update',
  );
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_no_overlap_insert
    BEFORE INSERT ON property_sale_reviews
    WHEN NEW.status IN ('pending', 'accepted') AND EXISTS (
      SELECT 1 FROM property_sale_reviews prior
      LEFT JOIN property_sale_executions completed
        ON completed.sale_review_id = prior.id
        AND completed.transfer_applied_at IS NOT NULL
      WHERE prior.property_id = NEW.property_id
        AND prior.status IN ('pending', 'accepted')
        AND completed.id IS NULL
        AND (prior.target_type = 'property' OR NEW.target_type = 'property'
          OR prior.unit_id = NEW.unit_id)
    )
    BEGIN
      SELECT RAISE(ABORT, 'overlapping open property sale review exists');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_no_overlap_update
    BEFORE UPDATE OF status ON property_sale_reviews
    WHEN NEW.status IN ('pending', 'accepted') AND NOT EXISTS (
      SELECT 1 FROM property_sale_executions current_execution
      WHERE current_execution.sale_review_id = NEW.id
        AND current_execution.transfer_applied_at IS NOT NULL
    ) AND EXISTS (
      SELECT 1 FROM property_sale_reviews prior
      LEFT JOIN property_sale_executions completed
        ON completed.sale_review_id = prior.id
        AND completed.transfer_applied_at IS NOT NULL
      WHERE prior.id != NEW.id AND prior.property_id = NEW.property_id
        AND prior.status IN ('pending', 'accepted')
        AND completed.id IS NULL
        AND (prior.target_type = 'property' OR NEW.target_type = 'property'
          OR prior.unit_id = NEW.unit_id)
    )
    BEGIN
      SELECT RAISE(ABORT, 'overlapping open property sale review exists');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_terms_required_insert
    BEFORE INSERT ON property_sale_reviews
    WHEN NEW.proposed_buyer_owner_id IS NULL
      OR NEW.proposed_amount_minor IS NULL OR NEW.proposed_amount_minor <= 0
      OR NEW.proposed_sale_date IS NULL
      OR DATE(NEW.proposed_sale_date) IS NULL
      OR DATE(NEW.proposed_sale_date) != NEW.proposed_sale_date
      OR DATE(NEW.proposed_sale_date) > DATE('now', 'localtime')
    BEGIN
      SELECT RAISE(ABORT, 'property sale review requires buyer, price and date');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_buyer_not_seller_insert
    BEFORE INSERT ON property_sale_reviews
    WHEN NEW.proposed_buyer_owner_id = (
      SELECT CASE WHEN NEW.target_type = 'unit'
        THEN COALESCE(u.owner_id, p.owner_id) ELSE p.owner_id END
      FROM properties p
      LEFT JOIN units u ON u.id = NEW.unit_id AND u.property_id = p.id
      WHERE p.id = NEW.property_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'sale buyer must differ from target owner');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_accepted_terms_required
    BEFORE UPDATE OF status ON property_sale_reviews
    WHEN NEW.status = 'accepted' AND (
      NEW.proposed_buyer_owner_id IS NULL
      OR NEW.proposed_amount_minor IS NULL OR NEW.proposed_amount_minor <= 0
      OR NEW.proposed_sale_date IS NULL
      OR DATE(NEW.proposed_sale_date) IS NULL
      OR DATE(NEW.proposed_sale_date) != NEW.proposed_sale_date
      OR DATE(NEW.proposed_sale_date) > DATE('now', 'localtime')
    )
    BEGIN
      SELECT RAISE(ABORT, 'cannot accept a sale review without fixed terms');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_terms_immutable
    BEFORE UPDATE OF proposed_buyer_owner_id, proposed_amount_minor,
      proposed_sale_date ON property_sale_reviews
    WHEN OLD.proposed_buyer_owner_id IS NOT NEW.proposed_buyer_owner_id
      OR OLD.proposed_amount_minor IS NOT NEW.proposed_amount_minor
      OR OLD.proposed_sale_date IS NOT NEW.proposed_sale_date
    BEGIN
      SELECT RAISE(ABORT, 'reviewed sale terms are immutable');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_reviews_cannot_cancel_executed
    BEFORE UPDATE OF status ON property_sale_reviews
    WHEN NEW.status = 'cancelled' AND EXISTS (
      SELECT 1 FROM property_sale_executions e
      WHERE e.sale_review_id = OLD.id AND e.transfer_applied_at IS NOT NULL
    )
    BEGIN
      SELECT RAISE(ABORT, 'an executed property sale review cannot be cancelled');
    END
  ''');

  await db.execute('''
    CREATE TRIGGER property_sale_executions_valid_insert
    BEFORE INSERT ON property_sale_executions
    WHEN NEW.transfer_applied_at IS NOT NULL
      OR NOT EXISTS (
        SELECT 1 FROM property_sale_reviews r
        WHERE r.id = NEW.sale_review_id
          AND r.status = 'accepted'
          AND r.target_type = NEW.target_type
          AND r.property_id = NEW.property_id
          AND r.unit_id IS NEW.unit_id
      )
      OR EXISTS (
        SELECT 1 FROM property_sale_executions old
        WHERE old.sale_review_id = NEW.sale_review_id
      )
      OR (NEW.target_type = 'property' AND NOT EXISTS (
        SELECT 1 FROM properties p
        WHERE p.id = NEW.property_id AND p.owner_id = NEW.seller_owner_id
      ))
      OR (NEW.target_type = 'unit' AND NOT EXISTS (
        SELECT 1 FROM units u JOIN properties p ON p.id = u.property_id
        WHERE u.id = NEW.unit_id AND u.property_id = NEW.property_id
          AND COALESCE(u.owner_id, p.owner_id) = NEW.seller_owner_id
      ))
      OR (NEW.target_type = 'property' AND EXISTS (
        SELECT 1 FROM units u
        WHERE u.property_id = NEW.property_id AND u.owner_id IS NOT NULL
      ))
      OR (NEW.target_type = 'property' AND EXISTS (
        SELECT 1 FROM contracts c JOIN units u ON u.id = c.unit_id
        WHERE u.property_id = NEW.property_id AND c.status != 'Cancelled'
          AND (DATE(c.end_date) IS NULL
            OR DATE(c.end_date) >= DATE(NEW.sale_date))
      ))
      OR (NEW.target_type = 'unit' AND EXISTS (
        SELECT 1 FROM contracts c
        WHERE c.unit_id = NEW.unit_id AND c.status != 'Cancelled'
          AND (DATE(c.end_date) IS NULL
            OR DATE(c.end_date) >= DATE(NEW.sale_date))
      ))
      OR (SELECT MAX(old.sale_date) FROM property_sale_executions old
          WHERE old.target_type = NEW.target_type
            AND old.property_id = NEW.property_id
            AND old.unit_id IS NEW.unit_id) IS NOT NULL
          AND NEW.sale_date <= (SELECT MAX(old.sale_date)
            FROM property_sale_executions old
            WHERE old.target_type = NEW.target_type
              AND old.property_id = NEW.property_id
              AND old.unit_id IS NEW.unit_id)
    BEGIN
      SELECT RAISE(ABORT, 'property sale execution validation failed');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_executions_apply_transfer_once
    BEFORE UPDATE ON property_sale_executions
    WHEN OLD.transfer_applied_at IS NOT NULL
      OR NEW.transfer_applied_at IS NULL
      OR OLD.id IS NOT NEW.id
      OR OLD.sale_review_id IS NOT NEW.sale_review_id
      OR OLD.target_type IS NOT NEW.target_type
      OR OLD.property_id IS NOT NEW.property_id
      OR OLD.unit_id IS NOT NEW.unit_id
      OR OLD.seller_owner_id IS NOT NEW.seller_owner_id
      OR OLD.buyer_owner_id IS NOT NEW.buyer_owner_id
      OR OLD.seller_name_snapshot IS NOT NEW.seller_name_snapshot
      OR OLD.buyer_name_snapshot IS NOT NEW.buyer_name_snapshot
      OR OLD.sale_price_minor IS NOT NEW.sale_price_minor
      OR OLD.sale_date IS NOT NEW.sale_date
      OR OLD.deed_reference IS NOT NEW.deed_reference
      OR OLD.execution_reason IS NOT NEW.execution_reason
      OR OLD.executed_by IS NOT NEW.executed_by
      OR OLD.executed_at IS NOT NEW.executed_at
      OR (NEW.target_type = 'property' AND NOT EXISTS (
        SELECT 1 FROM properties p
        WHERE p.id = NEW.property_id AND p.owner_id = NEW.buyer_owner_id
      ))
      OR (NEW.target_type = 'unit' AND NOT EXISTS (
        SELECT 1 FROM units u
        WHERE u.id = NEW.unit_id AND u.owner_id = NEW.buyer_owner_id
      ))
    BEGIN
      SELECT RAISE(ABORT, 'property sale transfer can be applied once only');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_executions_no_delete
    BEFORE DELETE ON property_sale_executions
    BEGIN
      SELECT RAISE(ABORT, 'property sale executions cannot be deleted');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER properties_owner_change_requires_sale
    BEFORE UPDATE OF owner_id ON properties
    WHEN NEW.owner_id IS NOT OLD.owner_id AND NOT EXISTS (
      SELECT 1 FROM property_sale_executions e
      WHERE e.target_type = 'property' AND e.property_id = OLD.id
        AND e.seller_owner_id = OLD.owner_id AND e.buyer_owner_id = NEW.owner_id
        AND e.transfer_applied_at IS NULL
    )
    BEGIN
      SELECT RAISE(ABORT, 'property owner changes require a reviewed sale execution');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER units_owner_change_requires_sale
    BEFORE UPDATE OF owner_id ON units
    WHEN NEW.owner_id IS NOT OLD.owner_id AND NOT EXISTS (
      SELECT 1 FROM property_sale_executions e
      JOIN properties p ON p.id = OLD.property_id
      WHERE e.target_type = 'unit' AND e.unit_id = OLD.id
        AND e.property_id = OLD.property_id
        AND e.seller_owner_id = COALESCE(OLD.owner_id, p.owner_id)
        AND e.buyer_owner_id = NEW.owner_id
        AND e.transfer_applied_at IS NULL
    )
    BEGIN
      SELECT RAISE(ABORT, 'unit owner changes require a reviewed sale execution');
    END
  ''');

  await db.execute('''
    CREATE TRIGGER property_sale_accounting_valid_insert
    BEFORE INSERT ON property_sale_accounting_records
    WHEN NOT EXISTS (
        SELECT 1 FROM property_sale_executions e
        WHERE e.id = NEW.sale_execution_id AND e.transfer_applied_at IS NOT NULL
      )
      OR (NEW.supersedes_record_id IS NULL AND EXISTS (
        SELECT 1 FROM property_sale_accounting_records old
        WHERE old.sale_execution_id = NEW.sale_execution_id
          AND old.supersedes_record_id IS NULL
      ))
      OR (NEW.supersedes_record_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM property_sale_accounting_records old
        WHERE old.id = NEW.supersedes_record_id
          AND old.sale_execution_id = NEW.sale_execution_id
          AND NOT EXISTS (
            SELECT 1 FROM property_sale_accounting_records successor
            WHERE successor.supersedes_record_id = old.id
          )
      ))
      OR NOT EXISTS (
        SELECT 1 FROM journal_entries je
        WHERE je.id = NEW.manual_journal_entry_id AND je.is_posted = 1
          AND (SELECT COUNT(*) FROM journal_lines jl
               WHERE jl.journal_entry_id = je.id) >= 2
          AND CAST(ROUND(COALESCE((SELECT SUM(jl.debit) FROM journal_lines jl
               WHERE jl.journal_entry_id = je.id), 0) * 100) AS INTEGER)
            = CAST(ROUND(COALESCE((SELECT SUM(jl.credit) FROM journal_lines jl
               WHERE jl.journal_entry_id = je.id), 0) * 100) AS INTEGER)
          AND EXISTS (SELECT 1 FROM journal_lines jl
               WHERE jl.journal_entry_id = je.id AND jl.debit > 0)
          AND EXISTS (SELECT 1 FROM journal_lines jl
               WHERE jl.journal_entry_id = je.id AND jl.credit > 0)
      )
    BEGIN
      SELECT RAISE(ABORT, 'property sale accounting record validation failed');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_accounting_records_no_update
    BEFORE UPDATE ON property_sale_accounting_records
    BEGIN
      SELECT RAISE(ABORT, 'property sale accounting records are immutable');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_accounting_records_no_delete
    BEFORE DELETE ON property_sale_accounting_records
    BEGIN
      SELECT RAISE(ABORT, 'property sale accounting records cannot be deleted');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_execution_events_no_update
    BEFORE UPDATE ON property_sale_execution_events
    BEGIN
      SELECT RAISE(ABORT, 'property sale execution events are immutable');
    END
  ''');
  await db.execute('''
    CREATE TRIGGER property_sale_execution_events_no_delete
    BEFORE DELETE ON property_sale_execution_events
    BEGIN
      SELECT RAISE(ABORT, 'property sale execution events cannot be deleted');
    END
  ''');
}
