enum SourceKind { localFile, androidContentUri }

class SourceHandle {
  const SourceHandle._({
    required this.raw,
    required this.kind,
  });

  final String raw;
  final SourceKind kind;

  bool get isLocalFile => kind == SourceKind.localFile;
  bool get isAndroidContentUri => kind == SourceKind.androidContentUri;

  factory SourceHandle.parse(String raw) {
    final value = raw.trim();
    if (value.startsWith('content://')) {
      return SourceHandle._(raw: value, kind: SourceKind.androidContentUri);
    }
    return SourceHandle._(raw: value, kind: SourceKind.localFile);
  }
}
