import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/node_search_query.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  test('node search ranks, filters and hides staging subtrees', () async {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final directory = repository.ensureDirectoryIndexRoot('/media');
    final child = await repository.ensureDirectoryFolderAsync(
      parentId: directory.id,
      name: '银狼资料',
      relativePath: '银狼资料',
    );
    final result = queryNodes(database.db, const NodeSearchQuery(text: '银狼资'));
    expect(result.items.single.node.name, '银狼资料');
    expect(result.items.single.root.id, directory.id);
    expect(result.items.single.breadcrumb.map((node) => node.name),
        ['media', '银狼资料']);

    final collection = repository.ensureCollectionIndexRoot('游戏资料');
    repository.createCustomNode(parentId: collection.id, name: '银狼资料');
    expect(
      queryNodes(
        database.db,
        const NodeSearchQuery(
          text: '银狼资',
          scope: NodeSearchScope.collection,
        ),
      ).items,
      hasLength(1),
    );
    final staging =
        repository.ensureDirectoryIndexRoot('/staging', staging: true);
    repository.ensureIndexNode(
      parentId: staging.id,
      name: '银狼资料',
      nodeType: NodeType.folder,
      viewType: ViewType.tree,
    );
    expect(queryNodes(database.db, const NodeSearchQuery(text: '银狼资')).items,
        hasLength(2));

    repository.renameIndexNode(child.id, '星穹资料');
    expect(queryNodes(database.db, const NodeSearchQuery(text: '银狼资')).items,
        hasLength(1));
  });
}
