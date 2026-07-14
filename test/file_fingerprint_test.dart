import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:best_viewer/src/core/scanner/candidate_source.dart';
import 'package:best_viewer/src/core/utils/file_fingerprint.dart';

void main() {
  test('file fingerprint is stable across modified-time changes', () async {
    final directory = await Directory.systemTemp.createTemp('best_viewer_fp_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}source.bin');
    await file
        .writeAsBytes(List<int>.generate(70 * 1024, (index) => index % 251));

    final first = await fingerprintFile(file, size: await file.length());
    await file.setLastModified(DateTime(2030));
    final second = await fingerprintFile(file, size: await file.length());

    expect(first, second);
    expect(first, startsWith('fp3:71680:'));
  });

  test('file candidate source normalizes metadata for the scanner', () async {
    final directory =
        await Directory.systemTemp.createTemp('best_viewer_source_');
    addTearDown(() => directory.delete(recursive: true));
    final nested = Directory('${directory.path}${Platform.pathSeparator}child');
    await nested.create();
    final file = File('${nested.path}${Platform.pathSeparator}source.txt');
    await file.writeAsString('candidate source');

    final source = FileCandidateSource(file: file, rootPath: directory.path);
    final snapshot = await source.inspect();

    expect(source.name, 'source.txt');
    expect(source.relativePath, 'child/source.txt');
    expect(snapshot.size, 16);
    expect(snapshot.fingerprint, startsWith('fp3:16:'));
  });
}
