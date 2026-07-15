import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

import '../database/library_repository.dart';
import '../domain/models.dart';
import 'webp_encoder.dart';

/// Builds visual node preview files without decoding or encoding on Flutter's
/// isolate. Repository reads and the final asset-row mutation deliberately
/// remain on the caller isolate; the expensive image work is fully portable.
class NodePreviewCompositeService {
  NodePreviewCompositeService(this.repository);

  final LibraryRepository repository;

  Future<Map<String, NodePreviewCompositeOutcome>> rebuildNodesAsync(
    Iterable<String> nodeIds,
  ) async {
    final outcomes = <String, NodePreviewCompositeOutcome>{};
    final requests = <Map<String, Object?>>[];
    for (final preview in repository.listIndexNodePreviews(nodeIds).values) {
      if (preview.kind != IndexNodePreviewKind.singleVisual &&
          preview.kind != IndexNodePreviewKind.visualGrid) {
        outcomes[preview.nodeId] = const NodePreviewCompositeOutcome.remove();
        continue;
      }
      if (preview.customOrderTopToBottom &&
          preview.tiles
              .any((tile) => tile.kind != IndexNodePreviewTileKind.visual)) {
        outcomes[preview.nodeId] = const NodePreviewCompositeOutcome.remove();
        continue;
      }
      final tiles = preview.tiles
          .where((tile) =>
              tile.kind == IndexNodePreviewTileKind.visual &&
              tile.thumbnailPath != null)
          .map(
            (tile) => <String, Object?>{
              'path': tile.thumbnailPath!,
              'aspectRatio': tile.aspectRatio,
            },
          )
          .toList(growable: false);
      if (tiles.isEmpty) {
        outcomes[preview.nodeId] = const NodePreviewCompositeOutcome.remove();
        continue;
      }
      requests.add(<String, Object?>{
        'nodeId': preview.nodeId,
        'signature': _signature(preview),
        'assetKey': 'node_${preview.nodeId}',
        'outputPath': repository.nodePreviewAssetPath(
          'node_${preview.nodeId}',
          'webp',
        ),
        'height': Platform.isAndroid ? 640 : 440,
        'tiles': tiles,
      });
    }
    if (requests.isNotEmpty) {
      // One isolate handles the bounded work batch. This avoids eight isolate
      // startups for a page and prevents simultaneous image decoders from
      // exhausting Android memory.
      final results = await Isolate.run<List<Map<String, Object?>>>(
        () => _composeRequests(requests),
      );
      for (final result in results) {
        final nodeId = result['nodeId']! as String;
        final error = result['error'] as String?;
        if (error != null) {
          outcomes[nodeId] = NodePreviewCompositeOutcome.failed(error);
          continue;
        }
        if (result['written'] != true) {
          outcomes[nodeId] = const NodePreviewCompositeOutcome.remove();
          continue;
        }
        outcomes[nodeId] = NodePreviewCompositeOutcome.written(
          signature: result['signature']! as String,
          assetKey: result['assetKey']! as String,
          width: result['width']! as int,
          height: result['height']! as int,
        );
      }
    }
    for (final entry in outcomes.entries) {
      final outcome = entry.value;
      if (outcome.removeAsset) {
        repository.removeNodePreviewAsset(entry.key);
      } else if (outcome.succeeded) {
        repository.recordNodePreviewAsset(
          nodeId: entry.key,
          signature: outcome.signature!,
          assetKey: outcome.assetKey!,
          format: 'webp',
          width: outcome.width!,
          height: outcome.height!,
        );
      }
    }
    return outcomes;
  }

  static String _signature(IndexNodePreview preview) => preview.tiles
      .map((tile) =>
          '${tile.kind.name}:${tile.entityId ?? tile.nodeId ?? tile.title}:${tile.thumbnailKey ?? ''}:${tile.aspectRatio}')
      .join('|');
}

class NodePreviewCompositeOutcome {
  const NodePreviewCompositeOutcome._({
    this.removeAsset = false,
    this.error,
    this.signature,
    this.assetKey,
    this.width,
    this.height,
  });

  const NodePreviewCompositeOutcome.remove() : this._(removeAsset: true);

  factory NodePreviewCompositeOutcome.failed(String error) =>
      NodePreviewCompositeOutcome._(error: error);

  factory NodePreviewCompositeOutcome.written({
    required String signature,
    required String assetKey,
    required int width,
    required int height,
  }) =>
      NodePreviewCompositeOutcome._(
        signature: signature,
        assetKey: assetKey,
        width: width,
        height: height,
      );

  final bool removeAsset;
  final String? error;
  final String? signature;
  final String? assetKey;
  final int? width;
  final int? height;

  bool get succeeded => error == null && !removeAsset && width != null;
}

List<Map<String, Object?>> _composeRequests(
  List<Map<String, Object?>> requests,
) =>
    requests.map(_composeRequest).toList(growable: false);

Map<String, Object?> _composeRequest(Map<String, Object?> request) {
  final nodeId = request['nodeId']! as String;
  try {
    final height = request['height']! as int;
    final rawTiles = request['tiles']! as List<Object?>;
    final tiles = <({String path, double aspectRatio})>[];
    for (final rawTile in rawTiles) {
      final tile = rawTile! as Map<Object?, Object?>;
      final path = tile['path']! as String;
      if (File(path).existsSync()) {
        tiles.add((
          path: path,
          aspectRatio: (tile['aspectRatio']! as num).toDouble(),
        ));
      }
    }
    if (tiles.isEmpty) {
      return <String, Object?>{'nodeId': nodeId, 'written': false};
    }
    final lowerCoverWidth = (height * .4).round();
    // The top cover can preserve a portrait source ratio, but must not become
    // thinner than a lower 0.4H spine.
    final topCoverWidth =
        (tiles.last.aspectRatio.clamp(.4, 1.0) * height).round();
    // Lower layers are real 0.4H frames, rather than full-width images hidden
    // by the following cover. Their source is cover-cropped into that frame.
    final width = (lowerCoverWidth * (tiles.length - 1) + topCoverWidth)
        .clamp(height ~/ 8, height * 4);
    final canvas = img.Image(width: width, height: height, numChannels: 4);
    // The runtime preview used the app scaffold beneath transparent covers.
    // Keep the persistent artifact opaque with the same deep-green base.
    img.fill(canvas, color: img.ColorRgba8(31, 38, 33, 255));
    var left = 0;
    for (var index = 0; index < tiles.length; index++) {
      final tileWidth = index == tiles.length - 1
          ? topCoverWidth.clamp(1, width - left)
          : lowerCoverWidth.clamp(1, width - left);
      final source = img.decodeImage(File(tiles[index].path).readAsBytesSync());
      if (source == null) {
        return <String, Object?>{'nodeId': nodeId, 'written': false};
      }
      // Every source has a fixed height and is cover-cropped, never stretched.
      // Each lower layer is exactly 0.4H wide; only the top layer keeps the
      // source-derived width (up to one full H).
      _compositeCoverWithRoundedLeft(
        canvas,
        _cover(source, tileWidth, height),
        left: left,
        // Only the outermost leading edge is rounded. Internal stacked
        // seams are square so covers read as one layered composition.
        radius: index == 0 ? 32 : 0,
      );
      if (index < tiles.length - 1) {
        final shadowWidth = (height * .15).round().clamp(1, tileWidth);
        _interleaveShadow(
          canvas,
          left: left + tileWidth - shadowWidth,
          width: shadowWidth,
        );
      }
      left += tileWidth;
    }
    final output = File(request['outputPath']! as String);
    output.parent.createSync(recursive: true);
    final temp = File('${output.path}.tmp');
    temp.writeAsBytesSync(encodeThumbnailWebp(canvas));
    if (output.existsSync()) output.deleteSync();
    temp.renameSync(output.path);
    return <String, Object?>{
      'nodeId': nodeId,
      'written': true,
      'signature': request['signature'],
      'assetKey': request['assetKey'],
      'width': width,
      'height': height,
    };
  } catch (error) {
    return <String, Object?>{
      'nodeId': nodeId,
      'error': '$error',
    };
  }
}

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

/// Renders one book-like cover with the 16dp leading corners from the old
/// runtime widget. The output is rendered at 2x, so the stored radius is 32px.
void _compositeCoverWithRoundedLeft(
  img.Image canvas,
  img.Image cover, {
  required int left,
  required int radius,
}) {
  final effectiveRadius = radius.clamp(0, cover.height ~/ 2);
  for (var y = 0; y < cover.height; y++) {
    for (var x = 0; x < cover.width; x++) {
      final targetX = left + x;
      if (targetX < 0 || targetX >= canvas.width) continue;
      if (effectiveRadius > 0 &&
          !_insideLeadingRoundedRect(x, y, cover.height, effectiveRadius)) {
        // DecoratedBox's translucent black background remains visible in the
        // clipped-away corner and joins naturally to the outer shadow.
        _darken(canvas, targetX, y, .40);
        continue;
      }
      final pixel = cover.getPixel(x, y);
      final base = canvas.getPixel(targetX, y);
      final alpha = pixel.a.toDouble() / 255;
      canvas.setPixelRgba(
        targetX,
        y,
        (pixel.r * alpha + base.r * (1 - alpha)).round(),
        (pixel.g * alpha + base.g * (1 - alpha)).round(),
        (pixel.b * alpha + base.b * (1 - alpha)).round(),
        255,
      );
    }
  }
}

bool _insideLeadingRoundedRect(int x, int y, int height, int radius) {
  if (x >= radius || (y >= radius && y < height - radius)) return true;
  final centerY = y < radius ? radius : height - radius - 1;
  final dx = x - radius;
  final dy = y - centerY;
  return dx * dx + dy * dy <= radius * radius;
}

/// The final 0.15H of every lower 0.4H cover fades from transparent on the
/// left to dark on the right, giving the following cover a clear layered edge.
void _interleaveShadow(
  img.Image image, {
  required int left,
  required int width,
}) {
  final startX = left.clamp(0, image.width);
  final endX = (left + width).clamp(startX + 1, image.width);
  for (var x = startX; x < endX; x++) {
    final opacity = .50 * (x - startX) / (endX - startX);
    for (var y = 0; y < image.height; y++) {
      _darken(image, x, y, opacity);
    }
  }
}

void _darken(img.Image image, int x, int y, double opacity) {
  final pixel = image.getPixel(x, y);
  final factor = 1 - opacity.clamp(0.0, 1.0);
  image.setPixelRgba(
    x,
    y,
    (pixel.r * factor).round(),
    (pixel.g * factor).round(),
    (pixel.b * factor).round(),
    pixel.a.toInt(),
  );
}
