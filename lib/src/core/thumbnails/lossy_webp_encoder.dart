import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../formats/thumbnail_spec.dart';
import 'webp_encoder.dart';

const _androidChannel = MethodChannel('best_viewer/directory_picker');

/// Encodes an opaque RGBA canvas as a persistent lossy WebP.
///
/// Android writes through Bitmap.compress on the worker executor. The Dart
/// encoder remains available for host-side tests.
Future<LossyWebpArtifact> encodeRgbaCanvasToWebp({
  required Uint8List pixels,
  required int width,
  required int height,
  required String outputPath,
}) async {
  if (Platform.isAndroid) {
    final result = await _androidChannel.invokeMapMethod<String, dynamic>(
      'encodeNodePreview',
      <String, Object>{
        'pixels': pixels,
        'width': width,
        'height': height,
        'outputPath': outputPath,
        'quality': thumbnailWebpQuality,
      },
    );
    if (result?['outputPath'] is! String) {
      throw const FormatException('Android node WebP encoder returned no path');
    }
    return LossyWebpArtifact(
      width: (result?['width'] as num?)?.toInt() ?? width,
      height: (result?['height'] as num?)?.toInt() ?? height,
      persistedPath: result!['outputPath'] as String,
    );
  }

  final bytes = await Isolate.run<Uint8List>(
    () => _encodeLosslessFallback(pixels, width, height),
  );
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  final temporary = File(
    '${output.path}.tmp',
  );
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (await output.exists()) {
      throw StateError('Refusing to replace an immutable preview asset');
    }
    await temporary.rename(output.path);
  } catch (_) {
    if (temporary.existsSync()) await temporary.delete();
    rethrow;
  }
  return LossyWebpArtifact(
      width: width, height: height, persistedPath: output.path);
}

Uint8List _encodeLosslessFallback(
  Uint8List pixels,
  int width,
  int height,
) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return encodeThumbnailWebp(image);
}

class LossyWebpArtifact {
  const LossyWebpArtifact({
    required this.width,
    required this.height,
    required this.persistedPath,
  });

  final int width;
  final int height;
  final String persistedPath;
}
