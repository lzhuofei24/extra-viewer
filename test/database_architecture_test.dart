import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'widgets and build controller cannot import SQLite or concrete repositories',
      () {
    final files = [
      ...Directory('lib/src/ui').listSync(recursive: true).whereType<File>(),
      File('lib/src/core/controllers/library_build_task_controller.dart'),
    ].where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final content = file.readAsStringSync();
      expect(content, isNot(contains('package:sqlite3/')), reason: file.path);
      expect(content, isNot(contains("database/library_repository.dart'")),
          reason: file.path);
      expect(
          content, isNot(contains("database/library_build_repository.dart'")),
          reason: file.path);
      expect(content, isNot(contains('database.db.')), reason: file.path);
    }
    expect(File('lib/src/app.dart').readAsStringSync(),
        isNot(contains('database.db.')));
  });
}
