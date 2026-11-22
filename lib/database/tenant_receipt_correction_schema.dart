import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Append-only links for correcting a posted tenant receipt without treating
/// the accounting reversal as a cash refund.
class TenantReceiptCorrectionSchema {
  TenantReceiptCorrectionSchema._();

  static Future<void> install(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tenant_receipt_corrections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_receipt_voucher_id INTEGER NOT NULL UNIQUE,
        reversal_voucher_id INTEGER NOT NULL UNIQUE,
        replacement_receipt_voucher_id INTEGER NOT NULL UNIQUE,
        reason TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 500),
        created_at TEXT NOT NULL,
        created_by INTEGER,
        FOREIGN KEY (source_receipt_voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (reversal_voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (replacement_receipt_voucher_id) REFERENCES vouchers (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tenant_receipt_correction_allocations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        correction_id INTEGER NOT NULL,
        collection_allocation_id INTEGER NOT NULL UNIQUE,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by INTEGER,
        UNIQUE (correction_id, collection_allocation_id),
        FOREIGN KEY (correction_id)
          REFERENCES tenant_receipt_corrections (id),
        FOREIGN KEY (collection_allocation_id)
          REFERENCES collection_allocations (id),
        FOREIGN KEY (created_by) REFERENCES users (id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS tenant_receipt_corrections_reversal_idx
      ON tenant_receipt_corrections(reversal_voucher_id, replacement_receipt_voucher_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS tenant_receipt_correction_alloc_source_idx
      ON tenant_receipt_correction_allocations(collection_allocation_id)
    ''');
    await db.execute('DROP TRIGGER IF EXISTS tenant_receipt_corrections_valid');
    await db.execute('''
      CREATE TRIGGER tenant_receipt_corrections_valid
      BEFORE INSERT ON tenant_receipt_corrections
      WHEN NOT EXISTS (
        SELECT 1
        FROM vouchers source
        JOIN journal_entries source_journal
          ON source_journal.id = source.journal_entry_id
        JOIN vouchers reversal ON reversal.id = NEW.reversal_voucher_id
        JOIN journal_entries reversal_journal
          ON reversal_journal.id = reversal.journal_entry_id
        JOIN vouchers replacement
          ON replacement.id = NEW.replacement_receipt_voucher_id
        JOIN journal_entries replacement_journal
          ON replacement_journal.id = replacement.journal_entry_id
        WHERE source.id = NEW.source_receipt_voucher_id
          AND source.voucher_type = 'قبض مستأجر'
          AND source.tenant_id IS NOT NULL
          AND source_journal.is_posted = 1
          AND reversal.voucher_type = 'عكس قبض مستأجر'
          AND reversal.tenant_id = source.tenant_id
          AND reversal_journal.is_posted = 1
          AND replacement.voucher_type = 'قبض مستأجر'
          AND replacement.tenant_id = source.tenant_id
          AND replacement_journal.is_posted = 1
          AND replacement.id != source.id
          AND reversal.id != source.id
          AND replacement.id != reversal.id
          AND CAST(ROUND(source.amount * 100) AS INTEGER) =
              CAST(ROUND(reversal.amount * 100) AS INTEGER)
          AND date(substr(reversal.voucher_date, 1, 10)) >=
              date(substr(source.voucher_date, 1, 10))
          AND NOT EXISTS (
            SELECT 1 FROM voucher_invoice_allocations invoice_allocation
            WHERE invoice_allocation.voucher_id = source.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM collection_allocations allocation
            WHERE allocation.voucher_id = source.id
              AND allocation.invoice_id IS NOT NULL
          )
          AND NOT EXISTS (
            SELECT 1
            FROM collection_allocations allocation
            JOIN refund_allocations refund
              ON refund.collection_allocation_id = allocation.id
            WHERE allocation.voucher_id = source.id
          )
          AND CAST(ROUND(source.amount * 100) AS INTEGER) = COALESCE((
            SELECT SUM(allocation.amount_minor)
            FROM collection_allocations allocation
            WHERE allocation.voucher_id = source.id
          ), 0)
      )
      BEGIN
        SELECT RAISE(ABORT, 'receipt correction links do not match posted standard vouchers');
      END
    ''');
    await db.execute(
      'DROP TRIGGER IF EXISTS tenant_receipt_correction_allocations_valid',
    );
    await db.execute('''
      CREATE TRIGGER tenant_receipt_correction_allocations_valid
      BEFORE INSERT ON tenant_receipt_correction_allocations
      WHEN NOT EXISTS (
        SELECT 1
        FROM tenant_receipt_corrections correction
        JOIN collection_allocations source
          ON source.id = NEW.collection_allocation_id
        JOIN vouchers receipt ON receipt.id = source.voucher_id
        WHERE correction.id = NEW.correction_id
          AND receipt.id = correction.source_receipt_voucher_id
          AND source.invoice_id IS NULL
          AND source.tax_amount_minor = 0
          AND source.rent_amount_minor = source.amount_minor
          AND NEW.amount_minor = source.amount_minor
          AND NOT EXISTS (
            SELECT 1 FROM refund_allocations refund
            WHERE refund.collection_allocation_id = source.id
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'correction allocation must reverse a full standard receipt allocation');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_receipt_corrections_no_update
      BEFORE UPDATE ON tenant_receipt_corrections
      BEGIN
        SELECT RAISE(ABORT, 'tenant receipt corrections are append-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_receipt_corrections_no_delete
      BEFORE DELETE ON tenant_receipt_corrections
      BEGIN
        SELECT RAISE(ABORT, 'tenant receipt corrections are append-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_receipt_correction_allocations_no_update
      BEFORE UPDATE ON tenant_receipt_correction_allocations
      BEGIN
        SELECT RAISE(ABORT, 'receipt correction allocations are append-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS tenant_receipt_correction_allocations_no_delete
      BEFORE DELETE ON tenant_receipt_correction_allocations
      BEGIN
        SELECT RAISE(ABORT, 'receipt correction allocations are append-only');
      END
    ''');

    await db.execute('DROP TRIGGER IF EXISTS refund_allocations_source_cap');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS refund_allocations_source_cap
      BEFORE INSERT ON refund_allocations
      WHEN NEW.amount_minor > COALESCE((
        SELECT ca.amount_minor
          - COALESCE((SELECT SUM(ra.amount_minor) FROM refund_allocations ra
                      WHERE ra.collection_allocation_id = ca.id), 0)
          - COALESCE((SELECT SUM(corrected.amount_minor)
                      FROM tenant_receipt_correction_allocations corrected
                      WHERE corrected.collection_allocation_id = ca.id), 0)
        FROM collection_allocations ca WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      OR NEW.rent_amount_minor > COALESCE((
        SELECT ca.rent_amount_minor
          - COALESCE((SELECT SUM(ra.rent_amount_minor) FROM refund_allocations ra
                      WHERE ra.collection_allocation_id = ca.id), 0)
          - COALESCE((SELECT SUM(corrected.amount_minor)
                      FROM tenant_receipt_correction_allocations corrected
                      WHERE corrected.collection_allocation_id = ca.id), 0)
        FROM collection_allocations ca WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      OR NEW.tax_amount_minor > COALESCE((
        SELECT ca.tax_amount_minor
          - COALESCE((SELECT SUM(ra.tax_amount_minor) FROM refund_allocations ra
                      WHERE ra.collection_allocation_id = ca.id), 0)
        FROM collection_allocations ca WHERE ca.id = NEW.collection_allocation_id
      ), 0)
      BEGIN
        SELECT RAISE(ABORT, 'refund exceeds unrefunded and uncorrected collection allocation');
      END
    ''');

    await db.execute(
      'DROP VIEW IF EXISTS tenant_receipt_correction_journal_integrity',
    );
    await db.execute('''
      CREATE VIEW tenant_receipt_correction_journal_integrity AS
      SELECT correction.id AS correction_id,
        CASE WHEN
          source.voucher_type = 'قبض مستأجر'
          AND reversal.voucher_type = 'عكس قبض مستأجر'
          AND replacement.voucher_type = 'قبض مستأجر'
          AND source.tenant_id IS NOT NULL
          AND reversal.tenant_id = source.tenant_id
          AND replacement.tenant_id = source.tenant_id
          AND source_journal.is_posted = 1
          AND reversal_journal.is_posted = 1
          AND replacement_journal.is_posted = 1
          AND source.journal_entry_id IS NOT NULL
          AND reversal.journal_entry_id IS NOT NULL
          AND replacement.journal_entry_id IS NOT NULL
          AND source.journal_entry_id != reversal.journal_entry_id
          AND source.journal_entry_id != replacement.journal_entry_id
          AND reversal.journal_entry_id != replacement.journal_entry_id
          AND (SELECT COUNT(*) FROM vouchers linked
            WHERE linked.journal_entry_id = source.journal_entry_id) = 1
          AND (SELECT COUNT(*) FROM vouchers linked
            WHERE linked.journal_entry_id = reversal.journal_entry_id) = 1
          AND (SELECT COUNT(*) FROM vouchers linked
            WHERE linked.journal_entry_id = replacement.journal_entry_id) = 1
          AND date(substr(source_journal.entry_date, 1, 10)) =
              date(substr(source.voucher_date, 1, 10))
          AND date(substr(reversal_journal.entry_date, 1, 10)) =
              date(substr(reversal.voucher_date, 1, 10))
          AND date(substr(replacement_journal.entry_date, 1, 10)) =
              date(substr(replacement.voucher_date, 1, 10))
          AND date(substr(reversal.voucher_date, 1, 10)) =
              date(substr(replacement.voucher_date, 1, 10))
          AND date(substr(reversal.voucher_date, 1, 10)) >=
              date(substr(source.voucher_date, 1, 10))
          AND CAST(ROUND(source.amount * 100) AS INTEGER) > 0
          AND CAST(ROUND(reversal.amount * 100) AS INTEGER) =
              CAST(ROUND(source.amount * 100) AS INTEGER)
          AND CAST(ROUND(replacement.amount * 100) AS INTEGER) > 0
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(source.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(source.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            WHERE line.journal_entry_id = reversal.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(reversal.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            WHERE line.journal_entry_id = reversal.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(reversal.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            WHERE line.journal_entry_id = replacement.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(replacement.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            WHERE line.journal_entry_id = replacement.journal_entry_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(replacement.amount * 100) AS INTEGER)
          AND (SELECT COUNT(*) FROM (
            SELECT line.account_id
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)
            GROUP BY line.account_id
          )) = 2
          AND (SELECT COUNT(*) FROM (
            SELECT line.account_id
            FROM journal_lines line
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)
            GROUP BY line.account_id
          )) = 2
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id
              AND line.account_id = tenant.account_id), 0) * 100)
              AS INTEGER) = 0
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id
              AND line.account_id = tenant.account_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(source.amount * 100) AS INTEGER)
          AND (SELECT COUNT(DISTINCT line.account_id)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = source.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)) = 1
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = source.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'), 0) * 100)
              AS INTEGER) = CAST(ROUND(source.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = source.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'), 0) * 100)
              AS INTEGER) = 0
          AND (SELECT COUNT(*)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = source.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)) = 1
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND line.account_id = tenant.account_id), 0) * 100)
              AS INTEGER) = 0
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND line.account_id = tenant.account_id), 0) * 100)
              AS INTEGER) = CAST(ROUND(replacement.amount * 100) AS INTEGER)
          AND (SELECT COUNT(DISTINCT line.account_id)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)) = 1
          AND CAST(ROUND(COALESCE((SELECT SUM(line.debit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'), 0) * 100)
              AS INTEGER) = CAST(ROUND(replacement.amount * 100) AS INTEGER)
          AND CAST(ROUND(COALESCE((SELECT SUM(line.credit)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'), 0) * 100)
              AS INTEGER) = 0
          AND (SELECT COUNT(*)
            FROM journal_lines line
            JOIN accounts cash ON cash.id = line.account_id
            WHERE line.journal_entry_id = replacement.journal_entry_id
              AND cash.account_type = 'Asset' AND cash.code LIKE '11%'
              AND (COALESCE(line.debit, 0) != 0
                OR COALESCE(line.credit, 0) != 0)) = 1
          AND (SELECT COUNT(*) FROM collection_allocations allocation
            WHERE allocation.voucher_id = source.id) > 0
          AND NOT EXISTS (SELECT 1 FROM voucher_invoice_allocations invoice
            WHERE invoice.voucher_id = source.id)
          AND (SELECT COALESCE(SUM(allocation.amount_minor), 0)
            FROM collection_allocations allocation
            WHERE allocation.voucher_id = source.id) =
              CAST(ROUND(source.amount * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1
            FROM collection_allocations allocation
            LEFT JOIN contract_installments installment
              ON installment.id = allocation.installment_id
            LEFT JOIN contracts contract
              ON contract.id = installment.contract_id
            WHERE allocation.voucher_id = source.id
              AND (allocation.installment_id IS NULL
                OR installment.id IS NULL
                OR contract.tenant_id IS NULL
                OR contract.tenant_id != source.tenant_id
                OR allocation.invoice_id IS NOT NULL
                OR allocation.amount_minor <= 0
                OR allocation.amount_minor != allocation.rent_amount_minor
                OR allocation.tax_amount_minor != 0
                OR EXISTS (SELECT 1 FROM tax_invoices invoice
                  WHERE invoice.installment_id = allocation.installment_id)
                OR EXISTS (SELECT 1 FROM refund_allocations refund
                  WHERE refund.collection_allocation_id = allocation.id))
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              SELECT installment_id,
                SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS amount_minor
              FROM voucher_installment_allocations
              WHERE voucher_id = source.id
              GROUP BY installment_id
            ) legacy
            LEFT JOIN (
              SELECT installment_id, SUM(rent_amount_minor) AS amount_minor
              FROM collection_allocations
              WHERE voucher_id = source.id
              GROUP BY installment_id
            ) detailed ON detailed.installment_id = legacy.installment_id
            WHERE legacy.amount_minor != COALESCE(detailed.amount_minor, 0)
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              SELECT installment_id, SUM(rent_amount_minor) AS amount_minor
              FROM collection_allocations
              WHERE voucher_id = source.id
              GROUP BY installment_id
            ) detailed
            LEFT JOIN (
              SELECT installment_id
              FROM voucher_installment_allocations
              WHERE voucher_id = source.id
              GROUP BY installment_id
            ) legacy ON legacy.installment_id = detailed.installment_id
            WHERE detailed.amount_minor > 0
              AND legacy.installment_id IS NULL
          )
          AND (SELECT COUNT(*)
            FROM tenant_receipt_correction_allocations correction_allocation
            WHERE correction_allocation.correction_id = correction.id) =
              (SELECT COUNT(*) FROM collection_allocations allocation
               WHERE allocation.voucher_id = source.id)
          AND (SELECT COALESCE(SUM(correction_allocation.amount_minor), 0)
            FROM tenant_receipt_correction_allocations correction_allocation
            WHERE correction_allocation.correction_id = correction.id) =
              CAST(ROUND(source.amount * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1
            FROM tenant_receipt_correction_allocations correction_allocation
            LEFT JOIN collection_allocations allocation
              ON allocation.id = correction_allocation.collection_allocation_id
            LEFT JOIN contract_installments installment
              ON installment.id = allocation.installment_id
            LEFT JOIN contracts contract
              ON contract.id = installment.contract_id
            WHERE correction_allocation.correction_id = correction.id
              AND (allocation.id IS NULL
                OR allocation.voucher_id != source.id
                OR correction_allocation.amount_minor != allocation.amount_minor
                OR allocation.installment_id IS NULL
                OR installment.id IS NULL
                OR contract.tenant_id IS NULL
                OR contract.tenant_id != source.tenant_id
                OR allocation.invoice_id IS NOT NULL
                OR allocation.amount_minor <= 0
                OR allocation.amount_minor != allocation.rent_amount_minor
                OR allocation.tax_amount_minor != 0
                OR EXISTS (SELECT 1 FROM tax_invoices invoice
                  WHERE invoice.installment_id = allocation.installment_id)
                OR EXISTS (SELECT 1 FROM refund_allocations refund
                  WHERE refund.collection_allocation_id = allocation.id))
          )
          AND (SELECT COUNT(*) FROM collection_allocations allocation
            WHERE allocation.voucher_id = replacement.id) > 0
          AND NOT EXISTS (SELECT 1 FROM voucher_invoice_allocations invoice
            WHERE invoice.voucher_id = replacement.id)
          AND (SELECT COALESCE(SUM(allocation.amount_minor), 0)
            FROM collection_allocations allocation
            WHERE allocation.voucher_id = replacement.id) =
              CAST(ROUND(replacement.amount * 100) AS INTEGER)
          AND NOT EXISTS (
            SELECT 1
            FROM collection_allocations allocation
            LEFT JOIN contract_installments installment
              ON installment.id = allocation.installment_id
            LEFT JOIN contracts contract
              ON contract.id = installment.contract_id
            WHERE allocation.voucher_id = replacement.id
              AND (allocation.installment_id IS NULL
                OR installment.id IS NULL
                OR contract.tenant_id IS NULL
                OR contract.tenant_id != replacement.tenant_id
                OR allocation.invoice_id IS NOT NULL
                OR allocation.amount_minor <= 0
                OR allocation.amount_minor != allocation.rent_amount_minor
                OR allocation.tax_amount_minor != 0
                OR EXISTS (SELECT 1 FROM tax_invoices invoice
                  WHERE invoice.installment_id = allocation.installment_id))
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              SELECT installment_id,
                SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS amount_minor
              FROM voucher_installment_allocations
              WHERE voucher_id = replacement.id
              GROUP BY installment_id
            ) legacy
            LEFT JOIN (
              SELECT installment_id, SUM(rent_amount_minor) AS amount_minor
              FROM collection_allocations
              WHERE voucher_id = replacement.id
              GROUP BY installment_id
            ) detailed ON detailed.installment_id = legacy.installment_id
            WHERE legacy.amount_minor != COALESCE(detailed.amount_minor, 0)
          )
          AND NOT EXISTS (
            SELECT 1
            FROM (
              SELECT installment_id, SUM(rent_amount_minor) AS amount_minor
              FROM collection_allocations
              WHERE voucher_id = replacement.id
              GROUP BY installment_id
            ) detailed
            LEFT JOIN (
              SELECT installment_id
              FROM voucher_installment_allocations
              WHERE voucher_id = replacement.id
              GROUP BY installment_id
            ) legacy ON legacy.installment_id = detailed.installment_id
            WHERE detailed.amount_minor > 0
              AND legacy.installment_id IS NULL
          )
          AND NOT EXISTS (
            SELECT line.account_id,
              CAST(ROUND(COALESCE(SUM(line.debit), 0) * 100) AS INTEGER),
              CAST(ROUND(COALESCE(SUM(line.credit), 0) * 100) AS INTEGER)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id
            GROUP BY line.account_id
            EXCEPT
            SELECT line.account_id,
              CAST(ROUND(COALESCE(SUM(line.credit), 0) * 100) AS INTEGER),
              CAST(ROUND(COALESCE(SUM(line.debit), 0) * 100) AS INTEGER)
            FROM journal_lines line
            WHERE line.journal_entry_id = reversal.journal_entry_id
            GROUP BY line.account_id
          )
          AND NOT EXISTS (
            SELECT line.account_id,
              CAST(ROUND(COALESCE(SUM(line.debit), 0) * 100) AS INTEGER),
              CAST(ROUND(COALESCE(SUM(line.credit), 0) * 100) AS INTEGER)
            FROM journal_lines line
            WHERE line.journal_entry_id = reversal.journal_entry_id
            GROUP BY line.account_id
            EXCEPT
            SELECT line.account_id,
              CAST(ROUND(COALESCE(SUM(line.credit), 0) * 100) AS INTEGER),
              CAST(ROUND(COALESCE(SUM(line.debit), 0) * 100) AS INTEGER)
            FROM journal_lines line
            WHERE line.journal_entry_id = source.journal_entry_id
            GROUP BY line.account_id
          )
          AND NOT EXISTS (SELECT 1 FROM collection_allocations allocation
            WHERE allocation.voucher_id = reversal.id)
          AND NOT EXISTS (SELECT 1 FROM refund_allocations refund
            WHERE refund.refund_voucher_id = reversal.id)
        THEN 1 ELSE 0 END AS journals_match
      FROM tenant_receipt_corrections correction
      JOIN vouchers source
        ON source.id = correction.source_receipt_voucher_id
      JOIN vouchers reversal
        ON reversal.id = correction.reversal_voucher_id
      JOIN vouchers replacement
        ON replacement.id = correction.replacement_receipt_voucher_id
      LEFT JOIN tenants tenant ON tenant.id = source.tenant_id
      LEFT JOIN journal_entries source_journal
        ON source_journal.id = source.journal_entry_id
      LEFT JOIN journal_entries reversal_journal
        ON reversal_journal.id = reversal.journal_entry_id
      LEFT JOIN journal_entries replacement_journal
        ON replacement_journal.id = replacement.journal_entry_id
    ''');

    await db.execute('DROP VIEW IF EXISTS collection_allocation_balances');
    await db.execute('''
      CREATE VIEW collection_allocation_balances AS
      WITH refund_totals AS (
        SELECT collection_allocation_id,
          SUM(amount_minor) AS refunded_minor,
          SUM(rent_amount_minor) AS refunded_rent_minor,
          SUM(tax_amount_minor) AS refunded_tax_minor
        FROM refund_allocations GROUP BY collection_allocation_id
      ), correction_totals AS (
        SELECT collection_allocation_id, SUM(amount_minor) AS corrected_minor
        FROM tenant_receipt_correction_allocations
        GROUP BY collection_allocation_id
      )
      SELECT
        ca.id,
        ca.voucher_id,
        ca.installment_id,
        ca.invoice_id,
        ca.amount_minor,
        ca.rent_amount_minor,
        ca.tax_amount_minor,
        COALESCE(refunds.refunded_minor, 0) AS refunded_minor,
        COALESCE(refunds.refunded_rent_minor, 0) AS refunded_rent_minor,
        COALESCE(refunds.refunded_tax_minor, 0) AS refunded_tax_minor,
        COALESCE(corrections.corrected_minor, 0) AS corrected_minor,
        ca.amount_minor
          - COALESCE(refunds.refunded_minor, 0)
          - COALESCE(corrections.corrected_minor, 0) AS remaining_minor,
        ca.rent_amount_minor
          - COALESCE(refunds.refunded_rent_minor, 0)
          - COALESCE(corrections.corrected_minor, 0) AS remaining_rent_minor,
        ca.tax_amount_minor
          - COALESCE(refunds.refunded_tax_minor, 0) AS remaining_tax_minor
      FROM collection_allocations ca
      LEFT JOIN refund_totals refunds
        ON refunds.collection_allocation_id = ca.id
      LEFT JOIN correction_totals corrections
        ON corrections.collection_allocation_id = ca.id
    ''');
  }
}
