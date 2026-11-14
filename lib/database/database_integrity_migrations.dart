import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Integrity migrations for entity relationships and legacy unit identifiers.
class DatabaseIntegrityMigrations {
  DatabaseIntegrityMigrations._();

  /// Applies the v12 schema additions to a v11 database without rewriting rows.
  static Future<void> upgradeToV12(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info("contracts")');
    if (!columns.any((row) => row['name'] == 'party_snapshot')) {
      await db.execute('ALTER TABLE contracts ADD COLUMN party_snapshot TEXT');
    }
    await installUnitNumberGuards(db);
  }

  /// Blocks future duplicate unit numbers, retaining any legacy duplicates for
  /// explicit user review instead of silently renumbering or deleting records.
  static Future<void> installUnitNumberGuards(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS units_unique_number_insert
      BEFORE INSERT ON units
      WHEN EXISTS (
        SELECT 1 FROM units
        WHERE property_id = NEW.property_id
          AND lower(trim(unit_number)) = lower(trim(NEW.unit_number))
      )
      BEGIN
        SELECT RAISE(ABORT, 'duplicate_unit_number');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS units_unique_number_update
      BEFORE UPDATE OF property_id, unit_number ON units
      WHEN (NEW.property_id != OLD.property_id OR
            lower(trim(NEW.unit_number)) != lower(trim(OLD.unit_number)))
       AND EXISTS (
        SELECT 1 FROM units
        WHERE property_id = NEW.property_id
          AND lower(trim(unit_number)) = lower(trim(NEW.unit_number))
          AND id != NEW.id
      )
      BEGIN
        SELECT RAISE(ABORT, 'duplicate_unit_number');
      END
    ''');
  }
}
