import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    expect(first, startsWith('fp2:71680:'));
  });
}
