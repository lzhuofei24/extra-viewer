import '../database/library_repository.dart';
import '../domain/models.dart';

/// Kept as a compatibility boundary for callers that rebuild an index after a
/// scan or collection edit. Node artwork is now a lightweight Flutter render
/// description, so there is no recursive PNG composition or SQLite BLOB write.
class IndexNodeThumbnailService {
  IndexNodeThumbnailService(this.repository);

  final LibraryRepository repository;

  Future<int> rebuildForRoot(IndexNode root) async {
    repository.clearLegacyIndexNodeThumbnails(root.id);
    repository.rebuildIndexNodePreviewCache(root.id);
    return 0;
  }

  Future<int> rebuildForNode(IndexNode node) async {
    repository.clearLegacyIndexNodeThumbnails(node.id);
    repository.rebuildIndexNodePreviewCache(node.id);
    final ancestors = repository.listIndexNodeAncestors(node.id);
    // The subtree pass has already refreshed [node]. Each parent only needs
    // its one representative recalculated from child cache entries.
    for (final ancestor in ancestors.skip(1)) {
      repository.rebuildIndexNodePreviewCacheForNode(ancestor.id);
    }
    return 0;
  }
}
