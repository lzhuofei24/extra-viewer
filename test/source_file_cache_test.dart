import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/modules/sources/source_file_cache.dart';

void main() {
  final throwsFileSystemException = throwsA(isA<FileSystemException>());
  late Directory directory;
  late SourceFileCache cache;
  var copies = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source_lease_');
    cache = SourceFileCache(budgetBytes: 10);
    copies = 0;
  });
  tearDown(() => directory.delete(recursive: true));
  Future<File> produce(int size) async {
    final file = File('${directory.path}/${copies++}');
    return file.writeAsBytes(List.filled(size, 0));
  }

  test('concurrent readers share one copy and neither can evict an active file',
      () async {
    final leases = await Future.wait([
      cache.acquire('a:1', 6, (_) => produce(6)),
      cache.acquire('a:1', 6, (_) => produce(6)),
    ]);
    expect(copies, 1);
    await leases.first.close();
    await leases.first.close();
    await expectLater(
        cache.acquire('b:1', 6, (_) => produce(6)), throwsFileSystemException);
    expect(await leases.last.file.exists(), isTrue);
    await leases.last.close();
    final next = await cache.acquire('b:1', 6, (_) => produce(6));
    expect(await leases.last.file.exists(), isFalse);
    await next.close();
  });

  test('a changed source revision creates a different file', () async {
    final old = await cache.acquire('a:1', 4, (_) => produce(4));
    final fresh = await cache.acquire('a:2', 4, (_) => produce(4));
    expect(old.file.path, isNot(fresh.file.path));
    expect(await old.file.exists(), isTrue);
    await old.close();
    await fresh.close();
  });

  test('failed copies release reservations and oversized output is removed',
      () async {
    await expectLater(
        cache.acquire(
            'a', 5, (_) async => throw const FileSystemException('offline')),
        throwsFileSystemException);
    await expectLater(
        cache.acquire('a', 5, (_) => produce(11)), throwsFileSystemException);
    expect(await directory.list().length, 0);
    final lease = await cache.acquire('a', 5, (_) => produce(5));
    await lease.close();
  });

  test('known large videos reserve exclusively and are removed after closing',
      () async {
    final lease = await cache.acquire('large', 20, (limit) {
      expect(limit, 20);
      return produce(20);
    });
    await expectLater(cache.acquire('other', 1, (_) => produce(1)),
        throwsFileSystemException);
    expect(await lease.file.exists(), isTrue);
    await lease.close();
    expect(await lease.file.exists(), isFalse);
  });

  test('local source leases never delete original files', () async {
    final source = await produce(3);
    await SourceFileLease(source).close();
    expect(await source.exists(), isTrue);
  });
}
