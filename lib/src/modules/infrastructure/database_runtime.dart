import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/database/app_database.dart';
import 'database_host.dart';

/// Read-only storage identity; never carries a SQLite connection into widgets.
class DatabaseDescriptor {
  const DatabaseDescriptor(this.databasePath, this.storageDirectoryPath);
  final String databasePath;
  final String storageDirectoryPath;
  static const schemaVersion = AppDatabase.currentSchemaVersion;
}

class DatabaseRuntime {
  DatabaseRuntime._(this.host);
  final DatabaseHost host;
  DatabaseDescriptor get descriptor =>
      DatabaseDescriptor(host.databasePath, host.storageDirectoryPath);

  static Future<DatabaseRuntime> open({
    Future<AppDatabase> Function()? testDatabaseFactory,
  }) async {
    final String path;
    if (testDatabaseFactory != null) {
      final database = await testDatabaseFactory();
      try {
        path = database.databasePath ??
            p.join(database.storageDirectoryPath, 'test-library.db');
        if (database.databasePath == null) {
          database.db.execute('VACUUM INTO ?', [path]);
        }
      } finally {
        database.close();
      }
    } else {
      final directory = await getApplicationSupportDirectory();
      path = p.join(directory.path, 'best_viewer.db');
    }
    return DatabaseRuntime._(await DatabaseHost.start(databasePath: path));
  }
}
