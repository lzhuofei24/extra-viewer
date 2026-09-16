import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:best_viewer/src/core/thumbnails/software_video_thumbnail_backend.dart';

void main() {
  test('software frame crosses isolate boundary and keeps target pixel budget',
      () async {
    final bytes =
        Uint8List.fromList(img.encodePng(img.Image(width: 1600, height: 900)));
    final result = await prepareVideoThumbnailPixelsInWorker(bytes);
    expect(result.$2 / result.$3, closeTo(16 / 9, .01));
    expect(result.$2 * result.$3, closeTo(360000, 1500));
    expect(result.$1.length, result.$2 * result.$3 * 4);
  });
  test('invalid capture is an error rather than a successful empty preview',
      () async {
    await expectLater(prepareVideoThumbnailPixelsInWorker(Uint8List(0)),
        throwsFormatException);
  });
}
