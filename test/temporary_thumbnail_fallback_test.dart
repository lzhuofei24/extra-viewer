import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/thumbnails/temporary_thumbnail_fallback.dart';

void main() {
  for (final fails in [false, true]) {
    test('temporary source cleaned after decode fails=$fails', () async {
      final dir = await Directory.systemTemp.createTemp('preview-fallback');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/copy').writeAsString('test');
      final result = withTemporaryThumbnailSource(
        firstError: 'native failed',
        materialize: () async => file.path,
        decode: (path) async {
          expect(await File(path).readAsString(), 'test');
          if (fails) throw StateError('decode failed');
          return 42;
        },
      );
      if (fails) {
        await expectLater(result, throwsA(predicate((e) =>
            '$e'.contains('native failed') && '$e'.contains('decode failed'))));
      } else {
        expect(await result, 42);
      }
      expect(await file.exists(), isFalse);
    });
  }
  test('materialization errors preserve the original decoder error', () async {
    await expectLater(withTemporaryThumbnailSource(
      firstError: 'no frame',
      materialize: () async => throw StateError('copy failed'),
      decode: (_) async => fail('must not decode'),
    ), throwsA(predicate((e) =>
        '$e'.contains('no frame') && '$e'.contains('copy failed'))));
  });
}
