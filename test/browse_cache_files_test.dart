import 'dart:io';
import 'package:best_viewer/src/core/database/browse_cache_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('cache cleanup preserves live sessions and unrelated files', () async {
    final dir = await Directory.systemTemp.createTemp('cache_lease_');
    addTearDown(() => dir.delete(recursive: true));
    final unrelated = File(p.join(dir.path, 'library.db'));
    await unrelated.writeAsString('keep');
    final orphan = File(p.join(dir.path, 'browse-123.cache.db'));
    await orphan.writeAsString('orphan');
    await File('${orphan.path}.lock').create();
    final first = await BrowseCacheFiles.create(dir.path);
    addTearDown(first.close);
    await File(first.path).writeAsString('active');
    final second = await BrowseCacheFiles.create(dir.path);
    addTearDown(second.close);
    expect(await orphan.exists(), isFalse);
    expect(await File(first.path).readAsString(), 'active');
    expect(await unrelated.readAsString(), 'keep');
    await first.close();
    expect(await File(first.path).exists(), isFalse);
    expect(await File('${first.path}.lock').exists(), isFalse);
  });
}
