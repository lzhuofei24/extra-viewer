import 'package:sqlite3/sqlite3.dart';

/// A separate version is required for already-built schema-12 applications.
void migrateSchemaV13(Database db) {
  if (db
      .select('PRAGMA table_info(index_nodes)')
      .any((row) => row['name'] == 'view_type')) {
    db.execute('ALTER TABLE index_nodes DROP COLUMN view_type');
  }
}
