import '../../core/domain/models.dart';
import '../library/library_access.dart';

/// Converts an Android SAF document URI to a user-facing location without
/// changing the URI used for opening, caching, or directory lookup.
String formatSafDisplayPath(String locator, {String? fallback}) {
  final uri = Uri.tryParse(locator);
  if (uri?.scheme != 'content') return fallback ?? locator;
  final segments = uri!.pathSegments;
  final documentIndex = segments.lastIndexOf('document');
  if (documentIndex < 0 || documentIndex + 1 >= segments.length) {
    return fallback ?? locator;
  }
  final rawId = segments[documentIndex + 1];
  final documentId = _decodeSafSegment(rawId);
  final separator = documentId.indexOf(':');
  if (separator <= 0 || separator == documentId.length - 1) {
    return fallback ?? locator;
  }
  final volume = documentId.substring(0, separator);
  final relative = documentId.substring(separator + 1);
  final parts = relative
      .split('/')
      .map(_decodeSafSegment)
      .where((part) => part.isNotEmpty && part != '.')
      .toList(growable: false);
  if (parts.isEmpty) return fallback ?? locator;
  final volumeLabel = volume.toLowerCase() == 'primary' ? '内部存储' : volume;
  return [volumeLabel, ...parts].join(' / ');
}

String _decodeSafSegment(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

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
