import '../core/domain/models.dart';
import 'browser_node_cache.dart';
import 'browser_state.dart';

class BrowserLocationSession {
  const BrowserLocationSession(
      {required this.root,
      required this.node,
      required this.page,
      required this.sortMode,
      required this.dataRevision,
      required this.loading,
      required this.contentScope});
  final IndexNode? root, node;
  final EntityPageSnapshot page;
  final EntitySortMode sortMode;
  final BrowserContentScope contentScope;
  final int dataRevision;
  final bool loading;
}
