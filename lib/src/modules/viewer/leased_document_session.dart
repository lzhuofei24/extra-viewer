import '../sources/source_file_cache.dart';

/// Owns the native document and its source lease in that order. The renderer
/// must detach before close; it must not independently dispose the document.
class LeasedDocumentSession<T> {
  LeasedDocumentSession({
    required Future<SourceFileLease> source,
    required Future<T> Function(SourceFileLease) open,
    required Future<void> Function(T) disposeDocument,
  }) : _disposeDocument = disposeDocument {
    document = _open(source, open);
  }

  final Future<void> Function(T) _disposeDocument;
  late final Future<T> document;
  SourceFileLease? _lease;
  Future<void>? _closing;
  bool _stopped = false;

  Future<T> _open(Future<SourceFileLease> source,
      Future<T> Function(SourceFileLease) open) async {
    final lease = await source;
    _lease = lease;
    try {
      if (_stopped) throw StateError('Document session is closed');
      return await open(lease);
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  Future<void> close() {
    _stopped = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    final T loaded;
    try {
      loaded = await document;
    } catch (_) {
      // Reuse the release future so a cleanup failure still reaches shutdown.
      await _lease?.close();
      return;
    }
    await _disposeDocument(loaded);
    // A failed native close must not remove a file the native code may use.
    await _lease?.close();
  }
}
