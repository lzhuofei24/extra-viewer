import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/media/media_source_resolver.dart';

void main() {
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
