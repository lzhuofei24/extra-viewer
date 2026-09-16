import '../../core/domain/models.dart';

abstract interface class LibraryQueries {
  Future<NodeSearchPage> searchNodes(NodeSearchQuery query);
}
