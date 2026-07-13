import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Centralizes persistent preview encoding so a bundled libwebp FFI backend can
/// replace this implementation without touching individual format handlers.
Uint8List encodeThumbnailWebp(img.Image image) {
  return Uint8List.fromList(img.encodeWebP(image));
}
