import 'dart:typed_data';

class ThumbnailArtifact {
  const ThumbnailArtifact({
    required this.bytes,
    required this.width,
    required this.height,
    this.durationMs,
    this.sourcePixelCount,
    this.readMs = 0,
    this.decodeMs = 0,
    this.resizeMs = 0,
    this.encodeMs = 0,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int? durationMs;
  final int? sourcePixelCount;
  final int readMs;
  final int decodeMs;
  final int resizeMs;
  final int encodeMs;
}
