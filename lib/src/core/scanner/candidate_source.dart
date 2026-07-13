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
}
