import 'package:path/path.dart' as p;

/// Provider IDs are opaque: never split, lowercase, or infer physical paths.
class SourceIdentity {
  const SourceIdentity(
      {required this.kind,
      required this.authority,
      required this.rootId,
      required this.documentId,
      required this.locator});
  final String kind, authority, rootId, documentId, locator;
  String get rootLocator => kind == 'saf'
      ? Uri(scheme: 'content', host: authority, pathSegments: ['tree', rootId])
          .toString()
      : rootId;
  static SourceIdentity? parse(String locator, {String? rootLocator}) {
    final uri = Uri.tryParse(locator);
    if (uri?.scheme == 'content') {
      final parts = uri!.pathSegments;
      final tree = parts.indexOf('tree');
      final document = parts.lastIndexOf('document');
      if (tree < 0 ||
          tree + 1 >= parts.length ||
          document < 0 ||
          document + 1 >= parts.length) {
        return null;
      }
      return SourceIdentity(
          kind: 'saf',
          authority: uri.authority,
          rootId: parts[tree + 1],
          documentId: parts[document + 1],
          locator: locator);
    }
    if (uri != null &&
        uri.hasScheme &&
        uri.scheme != 'file' &&
        !p.isAbsolute(locator)) {
      return null;
    }
    final path = p.normalize(
        p.absolute(uri?.scheme == 'file' ? uri!.toFilePath() : locator));
    final root = p.normalize(p.absolute(rootLocator ?? p.dirname(path)));
    return SourceIdentity(
        kind: 'local',
        authority: '',
        rootId: root,
        documentId: path,
        locator: path);
  }
}
