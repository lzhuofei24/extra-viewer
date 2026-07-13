import 'dart:io';

import 'package:path/path.dart' as p;

import '../sources/platform_directory_picker.dart';
import '../utils/file_fingerprint.dart';

/// Platform-specific source metadata is normalized before the scanner makes
/// any persistence decision. Source adapters deliberately have no database
/// knowledge and never write into the library.
sealed class CandidateSource {
  const CandidateSource();

  String get sourcePath;
  String get name;
  String get relativePath;

  Future<CandidateSourceSnapshot> inspect();
}

class CandidateSourceSnapshot {
  const CandidateSourceSnapshot({
    required this.fingerprint,
    required this.size,
    required this.sourceCreatedAtMs,
    required this.sourceModifiedAtMs,
  });

  final String fingerprint;
  final int size;
  final int sourceCreatedAtMs;
  final int sourceModifiedAtMs;
}

class FileCandidateSource extends CandidateSource {
  const FileCandidateSource({
    required this.file,
    required this.rootPath,
  });

  final File file;
  final String rootPath;

  @override
  String get sourcePath => p.normalize(file.path);

  @override
  String get name => p.basename(file.path);

  @override
  String get relativePath =>
      p.relative(file.path, from: rootPath).replaceAll('\\', '/');

  @override
  Future<CandidateSourceSnapshot> inspect() async {
    final stat = await file.stat();
    return CandidateSourceSnapshot(
      fingerprint: await fingerprintFile(file, size: stat.size),
      size: stat.size,
      sourceCreatedAtMs: stat.changed.toUtc().millisecondsSinceEpoch,
      sourceModifiedAtMs: stat.modified.toUtc().millisecondsSinceEpoch,
    );
  }
}

class FileCandidateSourceProvider {
  const FileCandidateSourceProvider(this.rootPath);

  final String rootPath;

  bool get existsSync => Directory(rootPath).existsSync();

  Stream<FileCandidateSource> enumerate() async* {
    await for (final entry
        in Directory(rootPath).list(recursive: true, followLinks: false)) {
      if (entry is File) {
        yield FileCandidateSource(file: entry, rootPath: rootPath);
      }
    }
  }
}

class SafCandidateSource extends CandidateSource {
  const SafCandidateSource(this.document);

  final SourceDocument document;

  @override
  String get sourcePath => document.source;

  @override
  String get name => document.name;

  @override
  String get relativePath => document.relativePath;

  @override
  Future<CandidateSourceSnapshot> inspect() async {
    final prefix = await PlatformDirectoryPicker.readDocumentPrefix(
      document.source,
      maxBytes: fileFingerprintPrefixBytes,
    );
    return CandidateSourceSnapshot(
      fingerprint: fingerprintFromPrefix(size: document.size, prefix: prefix),
      size: document.size,
      sourceCreatedAtMs: document.modifiedAtMs,
      sourceModifiedAtMs: document.modifiedAtMs,
    );
  }

  Future<File> materialize({String cacheScope = 'session'}) async {
    final path = await PlatformDirectoryPicker.materializeDocument(
      document.source,
      name: document.name,
      cacheScope: cacheScope,
    );
    return File(path);
  }
}

class SafCandidateSourceProvider {
  const SafCandidateSourceProvider(this.rootSource);

  final String rootSource;

  static bool get isSupported => PlatformDirectoryPicker.isSupported;

  Stream<int> get discoveryProgress =>
      PlatformDirectoryPicker.directoryDiscoveryProgress;

  Future<int> begin({String? relativeScope}) =>
      PlatformDirectoryPicker.beginDirectoryTreeScan(
        rootSource,
        relativeScope: relativeScope,
      );

  Stream<List<SafCandidateSource>> readBatches() =>
      PlatformDirectoryPicker.readDirectoryTreeBatches().map(
        (batch) => batch.map(SafCandidateSource.new).toList(growable: false),
      );

  Future<void> cancel() => PlatformDirectoryPicker.cancelDirectoryTreeScan();

  Future<void> clearTransientDocuments() =>
      PlatformDirectoryPicker.clearTransientDocuments();
}
