import 'dart:io';

import 'package:flutter/services.dart';

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';

/// Android decodes and down-samples images natively, including direct SAF URI
/// reads, then writes a lossy WebP without creating a Dart pixel buffer.
class AndroidImageThumbnailBackend {
  static const _channel = MethodChannel('best_viewer/directory_picker');

  Future<ThumbnailArtifact?> encode(String source) async {
    if (!Platform.isAndroid) return null;
    final watch = Stopwatch()..start();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'createImageThumbnail',
      <String, Object>{
        'source': source,
        'maxWidth': thumbnailWidth,
        'quality': thumbnailWebpQuality,
      },
    );
    final bytes = result?['bytes'];
    final width = result?['width'];
    final height = result?['height'];
    if (bytes is! Uint8List || width is! num || height is! num) {
      throw const FormatException('Android returned an invalid thumbnail');
    }
    return ThumbnailArtifact(
      bytes: bytes,
      width: width.toInt(),
      height: height.toInt(),
      sourcePixelCount: (result?['sourcePixelCount'] as num?)?.toInt(),
      encodeMs: watch.elapsedMilliseconds,
    );
  }
}
