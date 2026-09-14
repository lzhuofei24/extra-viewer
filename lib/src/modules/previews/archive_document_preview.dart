import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/formats/thumbnail_spec.dart';
import '../../core/readers/archive_session.dart';
import '../../core/readers/docx_decoder.dart';
import '../../core/readers/epub_decoder.dart';

class ArchiveDocumentPreview {
  const ArchiveDocumentPreview(this.excerpt,
      {this.pixels, this.width = 0, this.height = 0});
  final String excerpt;
  final Uint8List? pixels;
  final int width;
  final int height;
}

/// One archive handle supplies both text and the first decodable illustration.
/// Call in the cancellable composition worker, never on the UI isolate.
Future<ArchiveDocumentPreview> readArchiveDocumentPreview(
    String path, String format,
    {bool includeCover = true}) async {
  final session = await ArchiveSession.open(File(path));
  try {
    final text = switch (format) {
      'epub' => readEpubPreviewText(session),
      'docx' => readDocxPreviewText(session),
      _ => throw ArgumentError.value(format, 'format'),
    };
    final runes = text.trim().runes.take(501).toList();
    final excerpt =
        String.fromCharCodes(runes.take(500)) + (runes.length > 500 ? '…' : '');
    if (!includeCover) return ArchiveDocumentPreview(excerpt);
    final names = session.fileNames.where((name) =>
        RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false)
            .hasMatch(name));
    var hasImage = false;
    for (final name in names) {
      hasImage = true;
      final bytes = session.readBytes(name);
      img.Image? image;
      try {
        image = bytes == null ? null : img.decodeImage(bytes);
      } catch (_) {
        continue;
      }
      if (image == null) continue;
      final dimensions =
          thumbnailDimensionsForTargetPixelCount(image.width, image.height);
      final resized = img.copyResize(image,
          width: dimensions.width, height: dimensions.height);
      return ArchiveDocumentPreview(excerpt,
          pixels: resized.getBytes(order: img.ChannelOrder.rgba),
          width: resized.width,
          height: resized.height);
    }
    if (hasImage) {
      throw const FormatException(
          'Document illustrations could not be decoded');
    }
    return ArchiveDocumentPreview(excerpt);
  } finally {
    session.close();
  }
}

Future<ArchiveDocumentPreview> Function() archiveDocumentPreviewAction(
        String path, String format,
        {bool includeCover = true}) =>
    () => readArchiveDocumentPreview(path, format, includeCover: includeCover);
