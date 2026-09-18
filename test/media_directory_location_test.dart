import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/modules/viewer/media_directory_location.dart';

void main() {
  test('media return resolves actual folder rather than classification or root',
      () async {
    final db = AppDatabase.openInMemory();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    final root = repo.ensureDirectoryIndexRoot('/source');
    final folder = await repo.ensureDirectoryFolderAsync(
        parentId: root.id, name: 'photos', relativePath: 'photos');
    final collection = repo.ensureCollectionIndexRoot('分类');
    final entity = repo
        .upsertEntity(
            path: '/source/photos/a.jpg',
            name: 'a',
            format: 'jpg',
            entityType: EntityType.image,
            hash: 'a',
            size: 1,
            sourceCreatedAtMs: 1,
            sourceModifiedAtMs: 1)
        .entity;
    db.db.execute('UPDATE entities SET directory_root_id = ? WHERE id = ?',
        [root.id, entity.id]);
    repo.linkEntityToIndexNode(entityId: entity.id, indexNodeId: folder.id);
    repo.linkEntityToIndexNode(entityId: entity.id, indexNodeId: collection.id);
    expect((await resolveMediaDirectoryPath(repo, entity.id)).map((n) => n.id),
        [root.id, folder.id]);
    expect(await resolveMediaDirectoryPath(repo, 'missing'), isEmpty);
  });
}
