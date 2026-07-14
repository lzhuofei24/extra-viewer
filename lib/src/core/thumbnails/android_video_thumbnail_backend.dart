import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';
import 'thumbnail_cancellation.dart';
import '../utils/ids.dart';

/// Android's media stack extracts a key frame from SAF URIs directly. This
/// avoids requiring an FFmpeg executable inside the APK.
class AndroidVideoThumbnailBackend {
  static const _channel = MethodChannel('best_viewer/directory_picker');

  Future<ThumbnailArtifact?> encode(
    String source, {
    required String outputPath,
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    if (!Platform.isAndroid) return null;
    cancellationToken?.throwIfCancelled();
    final requestId = newId();
    void cancel() {
      unawaited(_channel.invokeMethod<void>(
        'cancelThumbnail',
        <String, Object>{'requestId': requestId},
      ));
    }

    cancellationToken?.addListener(cancel);
    late final Map<String, dynamic>? result;
    try {
      result = await _channel.invokeMapMethod<String, dynamic>(
        'createVideoThumbnail',
        <String, Object>{
          'source': source,
          'outputPath': outputPath,
          'requestId': requestId,
          'targetPixelCount': thumbnailTargetPixelCount,
          'quality': thumbnailWebpQuality,
        },
      );
    } catch (_) {
      cancellationToken?.throwIfCancelled();
      rethrow;
    } finally {
      cancellationToken?.removeListener(cancel);
    }
    cancellationToken?.throwIfCancelled();
    final width = result?['width'];
    final height = result?['height'];
    final persistedPath = result?['outputPath'];
    if (persistedPath is! String || width is! num || height is! num) {
      throw const FormatException(
          'Android returned an invalid video thumbnail');
    }
    return ThumbnailArtifact(
      bytes: Uint8List(0),
      width: width.toInt(),
      height: height.toInt(),
      durationMs: (result?['durationMs'] as num?)?.toInt(),
      readMs: (result?['readMs'] as num?)?.toInt() ?? 0,
      decodeMs: (result?['decodeMs'] as num?)?.toInt() ?? 0,
      resizeMs: (result?['resizeMs'] as num?)?.toInt() ?? 0,
      encodeMs: (result?['encodeMs'] as num?)?.toInt() ?? 0,
      writeMs: (result?['writeMs'] as num?)?.toInt() ?? 0,
      persistedPath: persistedPath,
    );
  }
}
