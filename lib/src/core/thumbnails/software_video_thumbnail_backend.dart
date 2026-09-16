import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../diagnostics/app_diagnostic_log.dart';
import '../formats/thumbnail_spec.dart';
import '../media/media_source_resolver.dart';
import 'lossy_webp_encoder.dart';
import 'thumbnail_artifact.dart';
import 'thumbnail_cancellation.dart';

/// An independent libmpv/FFmpeg software decoder for Android retriever failures.
/// It never copies the source to disk and never shares the foreground player.
class SoftwareVideoThumbnailBackend {
  static const _channel = MethodChannel('best_viewer/directory_picker');
  static Future<void> _tail = Future<void>.value();

  Future<ThumbnailArtifact> encode(String source,
      {required String outputPath,
      ThumbnailCancellationToken? cancellationToken}) {
    final work =
        _tail.then((_) => _encode(source, outputPath, cancellationToken));
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<ThumbnailArtifact> _encode(String source, String outputPath,
      ThumbnailCancellationToken? token) async {
    token?.throwIfCancelled();
    String? descriptorToken;
    Player? player;
    StreamSubscription<String>? errors;
    final messages = <String>[];
    var active = true;
    void checkActive() {
      token?.throwIfCancelled();
      if (!active) throw const ThumbnailTaskCanceledException();
    }

    final stopped = Completer<void>();
    void cancel() {
      if (!stopped.isCompleted) stopped.complete();
    }

    token?.addListener(cancel);
    try {
      var playbackSource = source;
      if (source.startsWith('content://')) {
        final descriptor = await _channel.invokeMapMethod<String, dynamic>(
            'openSourceDescriptor', {'source': source});
        if (descriptor == null) throw StateError('No source descriptor');
        descriptorToken = descriptor['token'] as String;
        playbackSource = MediaSourceResolver.playbackSourceForFile(
            File(descriptor['path'] as String));
      }
      token?.throwIfCancelled();
      final decoder = Player(
          configuration:
              const PlayerConfiguration(bufferSize: 4 * 1024 * 1024));
      player = decoder;
      errors = decoder.stream.error.listen((message) {
        if (messages.length == 4) messages.removeAt(0);
        messages.add(message);
      });
      final controller = VideoController(decoder,
          configuration: const VideoControllerConfiguration(
              hwdec: 'no', enableHardwareAcceleration: false));
      Future<Uint8List> capture() async {
        await decoder.setVolume(0);
        checkActive();
        final platform = decoder.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('aid', 'no');
        }
        checkActive();
        await decoder.open(Media(playbackSource), play: false);
        checkActive();
        await controller.waitUntilFirstFrameRendered;
        for (var attempt = 0; attempt < 12; attempt++) {
          checkActive();
          final bytes = await decoder.screenshot(format: 'image/png');
          if (bytes != null && bytes.isNotEmpty) return bytes;
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        throw StateError('Software decoder produced no frame: $messages');
      }

      final bytes = await Future.any<Uint8List>([
        capture(),
        stopped.future.then<Uint8List>((_) {
          token?.throwIfCancelled();
          throw const ThumbnailTaskCanceledException();
        }),
      ]).timeout(const Duration(seconds: 25), onTimeout: () {
        throw TimeoutException('Software video frame timeout: $messages');
      });
      token?.throwIfCancelled();
      final canvas = await prepareVideoThumbnailPixelsInWorker(bytes);
      token?.throwIfCancelled();
      final encoded = await encodeRgbaCanvasToWebp(
          pixels: canvas.$1,
          width: canvas.$2,
          height: canvas.$3,
          outputPath: outputPath);
      token?.throwIfCancelled();
      AppDiagnosticLog.instance
          .info('video_software_thumbnail_succeeded', fields: {
        'width': canvas.$2,
        'height': canvas.$3,
        'videoParams': decoder.state.videoParams.toString(),
      });
      return ThumbnailArtifact(
          bytes: Uint8List(0),
          width: encoded.width,
          height: encoded.height,
          persistedPath: encoded.persistedPath,
          durationMs: decoder.state.duration.inMilliseconds);
    } finally {
      active = false;
      token?.removeListener(cancel);
      await errors?.cancel();
      try {
        await player?.dispose();
      } finally {
        if (descriptorToken != null) {
          await _channel.invokeMethod<void>(
              'closeSourceDescriptor', {'token': descriptorToken});
        }
      }
    }
  }
}

// A top-level callback prevents capturing the player's unsendable async state.
Future<(Uint8List, int, int)> prepareVideoThumbnailPixelsInWorker(
        Uint8List bytes) =>
    compute(prepareVideoThumbnailPixels, bytes);

(Uint8List, int, int) prepareVideoThumbnailPixels(Uint8List bytes) {
  if (bytes.length < 8) {
    throw const FormatException('Empty or truncated software video frame');
  }
  final frame = img.decodePng(bytes);
  if (frame == null) {
    throw const FormatException('Invalid software video frame');
  }
  final size =
      thumbnailDimensionsForTargetPixelCount(frame.width, frame.height);
  final resized = img.copyResize(frame,
      width: size.width,
      height: size.height,
      interpolation: img.Interpolation.average);
  return (
    resized.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba),
    resized.width,
    resized.height
  );
}
