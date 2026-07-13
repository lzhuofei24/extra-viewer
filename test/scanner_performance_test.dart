import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/scanner/library_scanner.dart';

void main() {
  test(
    'scanner benchmark imports 2000 nested text entities',
    () async {
      final temp =
          await Directory.systemTemp.createTemp('best_viewer_benchmark_');
      addTearDown(() => temp.delete(recursive: true));
      for (var index = 0; index < 2000; index++) {
        final file = File(p.join(
          temp.path,
          'group-${index ~/ 20}',
          'item-$index.txt',
        ));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('benchmark item $index');
      }
      final database = AppDatabase.openInMemory();
      addTearDown(database.close);
      final repository = LibraryRepository(database);
      final stopwatch = Stopwatch()..start();

      final summary = await LibraryScanner(repository).scanPath(temp.path);
      stopwatch.stop();

      expect(summary.scanned, 2000);
      expect(summary.imported, 2000);
      expect(repository.listRecoverableIndexJobs(), isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 45)));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
