import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../modules/library/library_access.dart';
import '../domain/models.dart';
import 'lossy_webp_encoder.dart';
import 'thumbnail_cancellation.dart';
import 'cancellable_thumbnail_task.dart';

/// Builds visual node preview files without decoding or encoding on Flutter's
/// isolate. Repository reads and the final asset-row mutation deliberately
/// remain on the caller isolate; the expensive image work is fully portable.
class NodePreviewCompositeService {
  NodePreviewCompositeService(this.repository);

  final LibraryAccess repository;

  Future<Map<String, NodePreviewCompositeOutcome>> rebuildNodesAsync(
    Iterable<String> nodeIds, {
    ThumbnailCancellationToken? cancellationToken,
    void Function(String, NodePreviewCompositeOutcome)? onCompleted,
  }) async {
    cancellationToken?.throwIfCancelled();
    final outcomes = <String, NodePreviewCompositeOutcome>{};
    final requests = <Map<String, Object?>>[];
    final inputs = await repository.prepareNodePreviewBuilds(nodeIds);
    final tickets = {
      for (final input in inputs) input.ticket.nodeId: input.ticket
    };
    final published = <String>{};
    Future<void> publish(String nodeId) async {
      cancellationToken?.throwIfCancelled();
      final outcome = outcomes[nodeId]!;
      if (outcome.removeAsset) {
        final accepted = await repository.publishNodePreview(tickets[nodeId]!);
        if (!accepted) {
          outcomes[nodeId] =
              NodePreviewCompositeOutcome.failed('节点已改变，旧预览结果已丢弃');
        }
      } else if (outcome.succeeded) {
        final accepted = await repository.publishNodePreview(tickets[nodeId]!,
            signature: outcome.signature!,
            width: outcome.width!,
            height: outcome.height!);
        if (!accepted) {
          outcomes[nodeId] =
              NodePreviewCompositeOutcome.failed('节点已改变，旧预览结果已丢弃');
        }
      }
      onCompleted?.call(nodeId, outcomes[nodeId]!);

      published.add(nodeId);
    }

    for (final input in inputs) {
      cancellationToken?.throwIfCancelled();
      final preview = input.preview;
      if (preview.kind != IndexNodePreviewKind.singleVisual &&
          preview.kind != IndexNodePreviewKind.visualGrid) {
        outcomes[preview.nodeId] = const NodePreviewCompositeOutcome.remove();
        continue;
      }
      if (preview.customOrderTopToBottom &&
          preview.tiles
              .any((tile) => tile.kind != IndexNodePreviewTileKind.visual)) {
        // A custom preview containing semantic tiles is intentionally rendered
        // by Flutter. It must not keep a stale visual composite around.
        outcomes[preview.nodeId] = const NodePreviewCompositeOutcome.remove();
        continue;
      }
      final visualTiles = preview.tiles
          .where((tile) => tile.kind == IndexNodePreviewTileKind.visual)
          .toList(growable: false);
      if (visualTiles.isEmpty) {
        // This is a visual preview description, but no source is available.
        // Treat it as a retryable failure instead of deleting a working asset.
        outcomes[preview.nodeId] = NodePreviewCompositeOutcome.failed(
          '视觉预览没有可用图片源',
        );
        continue;
      }
      final missingSource = visualTiles.any(
        (tile) => tile.thumbnailPath == null || tile.thumbnailPath!.isEmpty,
      );
      if (missingSource) {
        outcomes[preview.nodeId] = NodePreviewCompositeOutcome.failed(
          '视觉预览的实体缩略图尚未生成',
        );
        continue;
      }
      final tiles = visualTiles
          .map(
            (tile) => <String, Object?>{
              'path': tile.thumbnailPath!,
              'aspectRatio': tile.aspectRatio,
            },
          )
          .toList(growable: false);
      final signature = _signature(preview);
      // Each build gets a new final path. This makes the commit safe on both
      // Android and Windows: a process interruption can never remove the
      // asset currently referenced by SQLite.
      final assetKey = input.ticket.assetKey;
      requests.add(<String, Object?>{
        'nodeId': preview.nodeId,
        'signature': signature,
        'assetKey': assetKey,
        'outputPath': (await repository.nodePreviewAssetPath(
          assetKey,
          'webp',
        )),
        'height': Platform.isAndroid ? 640 : 440,
        'tiles': tiles,
      });
    }
    if (requests.isNotEmpty) {
      // One isolate handles the bounded work batch. This avoids eight isolate
      // startups for a page and prevents simultaneous image decoders from
      // exhausting Android memory.
      final results =
          await runCancellableThumbnailTask<List<Map<String, Object?>>>(
        _compositionAction(requests),
        cancellationToken: cancellationToken,
      );
      for (final result in results) {
        cancellationToken?.throwIfCancelled();
        final nodeId = result['nodeId']! as String;
        final error = result['error'] as String?;
        if (error != null) {
          outcomes[nodeId] = NodePreviewCompositeOutcome.failed(error);
          continue;
        }
        final rawPixels = result['pixels'];
        if (rawPixels is! TransferableTypedData) {
          outcomes[nodeId] = NodePreviewCompositeOutcome.failed(
            '节点预览像素数据未生成',
          );
          continue;
        }
        try {
          final pixels = rawPixels.materialize().asUint8List();
          final artifact = await encodeRgbaCanvasToWebp(
            pixels: pixels,
            width: result['width']! as int,
            height: result['height']! as int,
            outputPath: result['outputPath']! as String,
          );
          outcomes[nodeId] = NodePreviewCompositeOutcome.written(
            signature: result['signature']! as String,
            assetKey: result['assetKey']! as String,
            width: artifact.width,
            height: artifact.height,
          );
        } catch (error) {
          outcomes[nodeId] = NodePreviewCompositeOutcome.failed('$error');
        }
        await publish(nodeId);
      }
    }
    for (final nodeId in outcomes.keys.toList()) {
      if (!published.contains(nodeId)) await publish(nodeId);
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

List<Map<String, Object?>> Function() _compositionAction(
        List<Map<String, Object?>> requests) =>
    () => _composeRequests(requests);

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
      return <String, Object?>{
        'nodeId': nodeId,
        'written': false,
        'error': '节点预览的缩略图文件不存在',
      };
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
        return <String, Object?>{
          'nodeId': nodeId,
          'written': false,
          'error': '节点预览的缩略图无法解码',
        };
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
    return <String, Object?>{
      'nodeId': nodeId,
      'signature': request['signature'],
      'assetKey': request['assetKey'],
      'outputPath': request['outputPath'],
      'width': width,
      'height': height,
      'pixels': TransferableTypedData.fromList(<Uint8List>[_rgba(canvas)]),
    };
  } catch (error) {
    return <String, Object?>{
      'nodeId': nodeId,
      'error': '$error',
    };
  }
}

Uint8List _rgba(img.Image image) {
  final pixels = Uint8List(image.width * image.height * 4);
  var offset = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      pixels[offset++] = pixel.r.toInt().clamp(0, 255);
      pixels[offset++] = pixel.g.toInt().clamp(0, 255);
      pixels[offset++] = pixel.b.toInt().clamp(0, 255);
      pixels[offset++] = pixel.a.toInt().clamp(0, 255);
    }
  }
  return pixels;
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
