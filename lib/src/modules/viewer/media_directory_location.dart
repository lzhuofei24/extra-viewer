import '../../core/domain/models.dart';
import '../library/library_access.dart';

Future<List<IndexNode>> resolveMediaDirectoryPath(
    LibraryAccess library, String entityId) async {
  final entity = await library.getEntity(entityId);
  final rootId = entity?.directoryRootId;
  if (rootId == null) return const [];
  final root = await library.getIndexNode(rootId);
  if (root?.nodeType != NodeType.directoryIndexRoot) return const [];
  var best = <IndexNode>[root!];
  final ids = (await library.listIndexNodeIdsForEntity(entityId)).toList()
    ..sort();
  for (final id in ids) {
    final node = await library.getIndexNode(id);
    if (node?.nodeType != NodeType.folder) continue;
    final path = await library.listNodePath(rootId, id);
    if (path.isNotEmpty &&
        path.first.id == rootId &&
        path.length > best.length) {
      best = path;
    }
  }
  return best;
}
