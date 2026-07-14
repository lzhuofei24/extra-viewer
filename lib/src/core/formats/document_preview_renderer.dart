import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../readers/archive_session.dart';
import '../thumbnails/webp_encoder.dart';
import 'thumbnail_spec.dart';

/// Builds a content preview: the first usable image in the source, otherwise
/// the first three readable lines. It never renders a whole document page.
Future<Uint8List?> buildDocumentPreviewPng(File source) async {
  final format = p.extension(source.path).replaceFirst('.', '').toLowerCase();
  return switch (format) {
    'pdf' => _buildPdfContentPreview(source),
    'docx' => _buildArchiveContentPreview(source),
    'epub' => _buildArchiveContentPreview(source),
    _ => throw FileSystemException('Unsupported document preview', source.path),
  };
}

/// Persistent document previews are written directly as WebP. Keeping the
/// legacy PNG builder above prevents breaking callers that still need PNG.
Future<Uint8List?> buildDocumentPreviewWebp(File source) async {
  final format = p.extension(source.path).replaceFirst('.', '').toLowerCase();
  return switch (format) {
    'pdf' => _buildPdfContentPreviewWebp(source),
    'docx' => _buildArchiveContentPreviewWebp(source),
    'epub' => _buildArchiveContentPreviewWebp(source),
    _ => throw FileSystemException('Unsupported document preview', source.path),
  };
}

Future<Uint8List?> _buildArchiveContentPreview(File source) async {
  final session = await ArchiveSession.open(source);
  try {
    final image = _selectArchivePreviewImage(session);
    return image == null
        ? null
        : Uint8List.fromList(img.encodePng(_resizePreviewImage(image)));
  } finally {
    session.close();
  }
}

Future<Uint8List?> _buildArchiveContentPreviewWebp(File source) async {
  final session = await ArchiveSession.open(source);
  try {
    final image = _selectArchivePreviewImage(session);
    return image == null
        ? null
        : encodeThumbnailWebp(_resizePreviewImage(image));
  } finally {
    session.close();
  }
}

Future<Uint8List?> _buildPdfContentPreview(File source) async {
  final image = await _renderPdfFirstPage(source);
  return image == null ? null : Uint8List.fromList(img.encodePng(image));
}

Future<Uint8List?> _buildPdfContentPreviewWebp(File source) async {
  final image = await _renderPdfFirstPage(source);
  return image == null ? null : encodeThumbnailWebp(image);
}

img.Image? _selectArchivePreviewImage(ArchiveSession session) {
  final images = session.fileNames
      .where(_isPreviewImage)
      .map((name) => (name: name, size: session.entry(name)?.size ?? 0))
      .toList(growable: false)
    ..sort((left, right) {
      final leftCover = _looksLikeCover(left.name) ? 0 : 1;
      final rightCover = _looksLikeCover(right.name) ? 0 : 1;
      if (leftCover != rightCover) return leftCover.compareTo(rightCover);
      return right.size.compareTo(left.size);
    });
  for (final entry in images.take(12)) {
    final bytes = session.readBytes(entry.name);
    final image = bytes == null ? null : img.decodeImage(bytes);
    if (image != null && image.width >= 96 && image.height >= 96) return image;
  }
  return null;
}

bool _looksLikeCover(String name) =>
    RegExp(r'(cover|front|title|folder)', caseSensitive: false).hasMatch(name);

Future<img.Image?> _renderPdfFirstPage(File source) async {
  final document = await PdfDocument.openFile(source.path);
  try {
    if (document.pages.isEmpty) return null;
    final page = document.pages.first;
    final width = thumbnailWidth.toDouble();
    final height = width * page.height / page.width;
    final rendered = await page.render(fullWidth: width, fullHeight: height);
    if (rendered == null) return null;
    try {
      return img.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rendered.pixels.buffer,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
    } finally {
      rendered.dispose();
    }
  } finally {
    await document.dispose();
  }
}

bool _isPreviewImage(String name) =>
    RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false).hasMatch(name);

img.Image _resizePreviewImage(img.Image source) {
  final targetWidth = source.width.clamp(1, thumbnailWidth).toInt();
  return img.copyResize(
    source,
    width: targetWidth,
    height: (source.height * targetWidth / source.width)
        .round()
        .clamp(1, 1 << 30)
        .toInt(),
  );
}
