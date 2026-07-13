import 'dart:typed_data';

/// Reads dimensions from the WebP container header without decoding pixels.
/// FFmpeg and native encoders use this to avoid a second image decode solely
/// for database metadata.
({int width, int height})? readWebpDimensions(Uint8List bytes) {
  if (bytes.length < 30 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return null;
  }
  final tag = String.fromCharCodes(bytes.sublist(12, 16));
  if (tag == 'VP8X') {
    final width = 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16);
    final height = 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16);
    return (width: width, height: height);
  }
  if (tag == 'VP8 ' && bytes.length >= 30) {
    final width = (bytes[26] | (bytes[27] << 8)) & 0x3fff;
    final height = (bytes[28] | (bytes[29] << 8)) & 0x3fff;
    return width > 0 && height > 0 ? (width: width, height: height) : null;
  }
  if (tag == 'VP8L' && bytes.length >= 25 && bytes[20] == 0x2f) {
    final width = 1 + bytes[21] + ((bytes[22] & 0x3f) << 8);
    final height =
        1 + ((bytes[22] >> 6) | (bytes[23] << 2) | ((bytes[24] & 0x0f) << 10));
    return (width: width, height: height);
  }
  return null;
}
