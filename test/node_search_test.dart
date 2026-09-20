import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/database/app_database.dart';
import 'package:best_viewer/src/core/database/library_repository.dart';
import 'package:best_viewer/src/core/database/node_search_query.dart';
import 'package:best_viewer/src/core/domain/models.dart';

void main() {
  test('search cursor survives deletion before the next page', () {
    final database = AppDatabase.openInMemory();
    addTearDown(database.close);
    final repository = LibraryRepository(database);
    final root = repository.ensureCollectionIndexRoot('Search root');
    for (final name in ['Match A', 'Match B', 'Match C', 'Match D']) {
      repository.createCustomNode(parentId: root.id, name: name);
    }
    final first =
        queryNodes(database.db, const NodeSearchQuery(text: 'Match', limit: 2));
    final cursor = NodeSearchPage.fromMessage(first.toMessage()).nextCursor;
    database.db.execute(
        'DELETE FROM index_nodes WHERE id = ?', [first.items.first.node.id]);
    final second = queryNodes(
        database.db, NodeSearchQuery(text: 'Match', limit: 2, after: cursor));
    expect(second.items.map((item) => item.node.name), ['Match C', 'Match D']);
    expect(second.hasMore, isFalse);
    expect(second.items.every((item) => item.breadcrumb.first.id == root.id),
        isTrue);
  });

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
