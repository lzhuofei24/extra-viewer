import 'dart:io';

import 'package:image/image.dart' as img;

import '../database/library_repository.dart';
import '../domain/models.dart';
import 'webp_encoder.dart';

/// Builds one WebP for a visual node preview after its metadata changes.
class NodePreviewCompositeService {
  NodePreviewCompositeService(this.repository);

  final LibraryRepository repository;

  void rebuildNodes(Iterable<String> nodeIds) {
    for (final preview in repository.listIndexNodePreviews(nodeIds).values) {
      if (preview.kind != IndexNodePreviewKind.singleVisual &&
          preview.kind != IndexNodePreviewKind.visualGrid) {
        repository.removeNodePreviewAsset(preview.nodeId);
        continue;
      }
      final signature = _signature(preview);
      final result = _write(preview);
      if (result == null) {
        repository.removeNodePreviewAsset(preview.nodeId);
        continue;
      }
      repository.recordNodePreviewAsset(
        nodeId: preview.nodeId,
        signature: signature,
        assetKey: 'node_${preview.nodeId}',
        format: 'webp',
        width: result.width,
        height: result.height,
      );
    }
  }

  _CompositeResult? _write(IndexNodePreview preview) {
    final tiles = preview.tiles
        .where((tile) =>
            tile.kind == IndexNodePreviewTileKind.visual &&
            tile.thumbnailPath != null &&
            File(tile.thumbnailPath!).existsSync())
        .toList(growable: false);
    if (tiles.isEmpty) return null;
    final height = Platform.isAndroid ? 640 : 440;
    final widths = tiles
        .map((tile) => tile.aspectRatio.clamp(.12, 1.0).toDouble())
        .toList(growable: false);
    var aspect = 0.0;
    for (var index = 0; index < widths.length; index++) {
      aspect += index == widths.length - 1
          ? widths[index]
          : widths[index].clamp(0, .4);
    }
    final width = (height * aspect).ceil().clamp(height ~/ 8, height * 4);
    final canvas = img.Image(width: width, height: height, numChannels: 4);
    img.fill(canvas, color: img.ColorRgba8(22, 35, 31, 255));
    var left = 0;
    for (var index = 0; index < tiles.length; index++) {
      final tileWidth = (widths[index] * height).round().clamp(1, width - left);
      final source =
          img.decodeImage(File(tiles[index].thumbnailPath!).readAsBytesSync());
      if (source == null) return null;
      final cover = _cover(source, tileWidth, height);
      img.compositeImage(canvas, cover, dstX: left, dstY: 0);
      if (index < tiles.length - 1) {
        _shadow(canvas, left + (height * .25).round());
      }
      left += index == tiles.length - 1 ? tileWidth : (height * .4).round();
    }
    final output = File(repository.nodePreviewAssetPath(
      'node_${preview.nodeId}',
      'webp',
    ));
    output.parent.createSync(recursive: true);
    final temp = File('${output.path}.tmp');
    temp.writeAsBytesSync(encodeThumbnailWebp(canvas));
    if (output.existsSync()) output.deleteSync();
    temp.renameSync(output.path);
    return _CompositeResult(width: width, height: height);
  }

  String _signature(IndexNodePreview preview) => preview.tiles
      .map((tile) =>
          '${tile.kind.name}:${tile.entityId ?? tile.nodeId ?? tile.title}:${tile.thumbnailKey ?? ''}:${tile.aspectRatio}')
      .join('|');

  img.Image _cover(img.Image source, int width, int height) {
    final target = width / height;
    final sourceRatio = source.width / source.height;
    final cropWidth =
        sourceRatio > target ? (source.height * target).round() : source.width;
    final cropHeight =
        sourceRatio > target ? source.height : (source.width / target).round();
    return img.copyResize(
      img.copyCrop(source,
          x: (source.width - cropWidth) ~/ 2,
          y: (source.height - cropHeight) ~/ 2,
          width: cropWidth,
          height: cropHeight),
      width: width,
      height: height,
    );
  }

  void _shadow(img.Image image, int startX) {
    final endX =
        (startX + image.height * .15).round().clamp(startX + 1, image.width);
    for (var x = startX.clamp(0, image.width); x < endX; x++) {
      final alpha = (102 * (x - startX) / (endX - startX)).round();
      final factor = (255 - alpha) / 255;
      for (var y = 0; y < image.height; y++) {
        final pixel = image.getPixel(x, y);
        image.setPixelRgba(
            x,
            y,
            (pixel.r * factor).round(),
            (pixel.g * factor).round(),
            (pixel.b * factor).round(),
            pixel.a.toInt());
      }
    }
  }
}

class _CompositeResult {
  const _CompositeResult({required this.width, required this.height});

  final int width;
  final int height;
}
