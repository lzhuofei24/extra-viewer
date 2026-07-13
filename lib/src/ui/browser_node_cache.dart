import '../core/domain/models.dart';

class BrowserNodeCache {
  BrowserNodeCache({this.maxWarmEntityReferences = 20000});

  /// A safety valve for one-level lookahead. Path pages always remain cacheable.
  final int maxWarmEntityReferences;
  final Map<BrowserNodeCacheKey, EntityPageSnapshot> _entries = {};
  final Set<BrowserNodeCacheKey> _pinnedKeys = {};
  final Set<BrowserNodeCacheKey> _lookaheadKeys = {};
  int _entityReferences = 0;

  EntityPageSnapshot? get(BrowserNodeCacheKey key) {
    return _entries[key];
  }

  bool put(
    BrowserNodeCacheKey key,
    EntityPageSnapshot entry, {
    required BrowserNodeCachePriority priority,
  }) {
    final previous = _entries[key];
    final additionalReferences =
        entry.entities.length - (previous?.entities.length ?? 0);
    if (priority == BrowserNodeCachePriority.lookahead &&
        _entityReferences + additionalReferences > maxWarmEntityReferences) {
      return false;
    }
    if (previous != null) _entityReferences -= previous.entities.length;
    _entries[key] = entry;
    _entityReferences += entry.entities.length;
    if (priority == BrowserNodeCachePriority.pinned) {
      _pinnedKeys.add(key);
      _lookaheadKeys.remove(key);
    } else {
      _lookaheadKeys.add(key);
      _pinnedKeys.remove(key);
    }
    return true;
  }

  void setNavigationScope({
    required String indexRootId,
    required List<IndexNode> path,
    required List<IndexNode> directChildren,
    required EntitySortMode sortMode,
    required bool recursive,
  }) {
    final pinned = path
        .map(
          (node) => BrowserNodeCacheKey(
            indexRootId: indexRootId,
            nodeId: node.id,
            sortMode: sortMode,
            recursive: recursive,
          ),
        )
        .toSet();
    final lookahead = directChildren
        .map(
          (node) => BrowserNodeCacheKey(
            indexRootId: indexRootId,
            nodeId: node.id,
            sortMode: sortMode,
            recursive: recursive,
          ),
        )
        .where((key) => !pinned.contains(key))
        .toSet();
    final retained = {...pinned, ...lookahead};
    for (final key in _entries.keys.toList()) {
      if (!retained.contains(key)) {
        _entityReferences -= _entries.remove(key)!.entities.length;
      }
    }
    _pinnedKeys
      ..clear()
      ..addAll(pinned);
    _lookaheadKeys
      ..clear()
      ..addAll(lookahead);
  }

  bool canWarm(BrowserNodeCacheKey key) {
    return _lookaheadKeys.contains(key) && !_entries.containsKey(key);
  }

  void clear() {
    _entries.clear();
    _pinnedKeys.clear();
    _lookaheadKeys.clear();
    _entityReferences = 0;
  }
}

enum BrowserNodeCachePriority { pinned, lookahead }

class BrowserNodeCacheKey {
  const BrowserNodeCacheKey({
    required this.indexRootId,
    required this.nodeId,
    required this.sortMode,
    required this.recursive,
  });

  final String indexRootId;
  final String nodeId;
  final EntitySortMode sortMode;
  final bool recursive;

  @override
  bool operator ==(Object other) =>
      other is BrowserNodeCacheKey &&
      other.indexRootId == indexRootId &&
      other.nodeId == nodeId &&
      other.sortMode == sortMode &&
      other.recursive == recursive;

  @override
  int get hashCode => Object.hash(indexRootId, nodeId, sortMode, recursive);
}

class EntityPageSnapshot {
  const EntityPageSnapshot({
    required this.childNodes,
    required this.entities,
    required this.nodePath,
    required this.nodeSummaries,
    required this.nodePreviews,
    this.recursiveCursor,
    this.hasMore = false,
  });

  final List<IndexNode> childNodes;
  final List<EntityListItem> entities;
  final List<IndexNode> nodePath;
  final Map<String, IndexNodeSummary> nodeSummaries;
  final Map<String, IndexNodePreview> nodePreviews;
  final RecursiveEntityPageCursor? recursiveCursor;
  final bool hasMore;
}
