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
    final bytes = result?['bytes'];
    final width = result?['width'];
    final height = result?['height'];
    if (bytes is! Uint8List || width is! num || height is! num) {
      throw const FormatException(
          'Android returned an invalid video thumbnail');
    }
    return ThumbnailArtifact(
      bytes: bytes,
      width: width.toInt(),
      height: height.toInt(),
      durationMs: (result?['durationMs'] as num?)?.toInt(),
    );
  }
}
