import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/media/media_source_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('large visual sources use a read-only descriptor and release it once',
      () async {
    const channel = MethodChannel('best_viewer/directory_picker');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'openSourceDescriptor') {
        return {'token': 'lease-1', 'path': '/proc/self/fd/77'};
      }
      expect(call.method, 'closeSourceDescriptor');
      expect(call.arguments['token'], 'lease-1');
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    for (final type in [EntityType.image, EntityType.video]) {
      final entity = EntityListItem(
          id: 'large',
          title: 'large',
          entityType: type,
          path: 'content://source/large',
          format: 'mp4',
          size: 50 * 1024 * 1024 + 1,
          modifiedAtMs: 0);
      expect(MediaSourceResolver.bypassSourceCache(entity), isTrue);
      final lease = await const MediaSourceResolver().acquireFile(entity);
      expect(lease.file.path, '/proc/self/fd/77');
      await lease.close();
      await lease.close();
    }
    expect(calls, [
      'openSourceDescriptor',
      'closeSourceDescriptor',
      'openSourceDescriptor',
      'closeSourceDescriptor'
    ]);
  });

  test('50 MiB boundary remains cacheable', () {
    const entity = EntityListItem(
        id: 'small',
        title: 'small',
        entityType: EntityType.video,
        path: 'content://source/small',
        format: 'mp4',
        size: 50 * 1024 * 1024,
        modifiedAtMs: 0);
    expect(MediaSourceResolver.bypassSourceCache(entity), isFalse);
  });
  test('local file entity resolves to file uri based media sources', () {
    const resolver = MediaSourceResolver();
    const entity = EntityListItem(
      id: 'entity-1',
      title: 'sample.mp4',
      entityType: EntityType.video,
      path: r'D:\media\sample.mp4',
      format: 'mp4',
      size: 100,
      modifiedAtMs: 123,
    );

    expect(resolver.localFile(entity).path, entity.path);
    expect(resolver.launchUri(entity).scheme, 'file');
    expect(
        resolver.playerSource(entity), resolver.launchUri(entity).toString());
    expect(resolver.displayLocation(entity), entity.path);
  });

  test('content URI entity uses its materialized local copy for reading', () {
    const resolver = MediaSourceResolver();
    const entity = EntityListItem(
      id: 'entity-2',
      title: 'sample.mp4',
      entityType: EntityType.video,
      path: 'content://media/external/video/media/42',
      localPath: r'C:\app-data\saf\sample.mp4',
      format: 'mp4',
      size: 100,
      modifiedAtMs: 123,
    );

    expect(resolver.localFile(entity).path, entity.localPath);
    expect(resolver.launchUri(entity).scheme, 'content');
  });
}
