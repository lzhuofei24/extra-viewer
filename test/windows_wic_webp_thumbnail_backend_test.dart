import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:best_viewer/src/core/thumbnails/windows_wic_webp_thumbnail_backend.dart';

void main() {
  test('Windows WIC backend emits a resized WebP thumbnail', () async {
    if (!Platform.isWindows) return;
    final temp = await Directory.systemTemp.createTemp('best_viewer_wic_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}source.png');
    final image = img.Image(width: 1600, height: 1000);
    img.fill(image, color: img.ColorRgba8(50, 130, 220, 255));
    await source.writeAsBytes(img.encodePng(image));

    final result = await WindowsWicWebpThumbnailBackend().encode(source);

    expect(result, isNotNull);
    expect(result!.width, 640);
    expect(result.height, 400);
    expect(result.bytes.take(4), [0x52, 0x49, 0x46, 0x46]);
  });
}
