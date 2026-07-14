import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';
import 'thumbnail_cancellation.dart';
import 'webp_dimensions.dart';

/// Uses native FFmpeg decoding, scaling and lossy WebP encoding on Windows.
class NativeImageThumbnailBackend {
  static String? _cachedExecutable;
  static bool _unavailable = false;
  static final Set<String> _failedExecutables = <String>{};

  bool get supported => Platform.isWindows && !_unavailable;

  Future<ThumbnailArtifact?> encode(
    File file, {
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    if (!supported) return null;
    final watch = Stopwatch()..start();
    for (final executable in _candidates()) {
      cancellationToken?.throwIfCancelled();
      Process? process;
      void killProcess() => process?.kill();
      cancellationToken?.addListener(killProcess);
      try {
        process = await Process.start(
          executable,
          [
            '-hide_banner',
            '-loglevel',
            'error',
            '-threads',
            '1',
            '-i',
            file.path,
            '-frames:v',
            '1',
            '-vf',
            "scale='trunc(iw*min(1,sqrt($thumbnailTargetPixelCount/(iw*ih))))':'trunc(ih*min(1,sqrt($thumbnailTargetPixelCount/(iw*ih))))'",
            '-f',
            'image2pipe',
            '-c:v',
            'libwebp',
            '-q:v',
            '$thumbnailWebpQuality',
            '-compression_level',
            '4',
            'pipe:1',
          ],
        );
        final stdoutFuture = process.stdout.fold<List<int>>(
          <int>[],
          (bytes, chunk) => bytes..addAll(chunk),
        );
        final stderrFuture = process.stderr.drain<void>();
        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            process?.kill();
            return -1;
          },
        );
        cancellationToken?.throwIfCancelled();
        final bytes = Uint8List.fromList(await stdoutFuture);
        await stderrFuture;
        if (exitCode != 0) {
          _failedExecutables.add(executable);
          continue;
        }
        if (bytes.isEmpty) continue;
        final dimensions = readWebpDimensions(bytes);
        if (dimensions == null) continue;
        _cachedExecutable = executable;
        return ThumbnailArtifact(
          bytes: bytes,
          width: dimensions.width,
          height: dimensions.height,
          encodeMs: watch.elapsedMilliseconds,
        );
      } on ProcessException {
        cancellationToken?.throwIfCancelled();
        _failedExecutables.add(executable);
        // Continue through configured and bundled executable candidates.
      } finally {
        cancellationToken?.removeListener(killProcess);
      }
    }
    if (_cachedExecutable == null) _unavailable = true;
    return null;
  }

  Iterable<String> _candidates() sync* {
    final seen = <String>{};
    for (final candidate in <String?>[
      _cachedExecutable,
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'ffmpeg',
        'ffmpeg.exe',
      ),
      p.join(
        Directory.current.path,
        'tools',
        'ffmpeg',
        'windows',
        'ffmpeg-8.1.2-essentials_build',
        'bin',
        'ffmpeg.exe',
      ),
      Platform.environment['BEST_VIEWER_FFMPEG'],
      Platform.environment['FFMPEG_PATH'],
      'ffmpeg',
      r'C:\Program Files (x86)\FormatFactory\ffmpeg.exe',
      r'C:\Program Files\Topaz Labs LLC\Topaz Video\ffmpeg.exe',
      r'C:\Program Files\Topaz Labs LLC\Topaz Video AI\ffmpeg.exe',
    ]) {
      if (candidate == null || candidate.trim().isEmpty) continue;
      if (!_failedExecutables.contains(candidate) && seen.add(candidate)) {
        yield candidate;
      }
    }
  }
}
