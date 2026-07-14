import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('fresh database creates the current clean schema baseline', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);

    expect(database.db.userVersion, AppDatabase.currentSchemaVersion);
    expect(
      database.db
          .select("SELECT name FROM sqlite_master WHERE name = 'entities'"),
      isNotEmpty,
    );
    expect(
      database.db.select(
        "SELECT name FROM sqlite_master WHERE name = 'library_build_jobs'",
      ),
      isNotEmpty,
    );
    expect(
      database.db.select(
        "SELECT name FROM sqlite_master WHERE name = 'node_preview_assets'",
      ),
      isNotEmpty,
    );
  });

  test('existing historical database requires an explicit local reset', () {
    final raw = sqlite3.openInMemory();
    raw.userVersion = 34;

    expect(
      () => AppDatabase.openForTesting(raw),
      throwsA(isA<AppDatabaseResetRequired>()),
    );
  });

}
