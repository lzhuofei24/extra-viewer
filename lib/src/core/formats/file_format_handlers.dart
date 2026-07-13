import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'thumbnail_spec.dart';
import 'document_preview_renderer.dart';
import '../thumbnails/webp_encoder.dart';
import '../thumbnails/webp_dimensions.dart';

enum ViewerKind {
  textReader,
  pdfReader,
  epubReader,
  docxReader,
  imageViewer,
  audioPlayer,
  videoPlayer,
  externalLauncher;
}

abstract class FileFormatHandler {
  const FileFormatHandler({
    required this.entityType,
    required this.viewerKind,
    required this.extensions,
  });

  final EntityType entityType;
  final ViewerKind viewerKind;
  final Set<String> extensions;

  String formatFor(String path) {
    return p.extension(path).replaceFirst('.', '').toLowerCase();
  }

  /// Only image and video handlers create a persistent media thumbnail.
  bool get supportsGeneratedThumbnail => false;

  Future<Uint8List?> buildThumbnailPng(File file) {
    throw UnsupportedError(
      '$runtimeType renders its preview directly in the Flutter UI.',
    );
  }

  /// Legacy fallback for handlers that have not yet been migrated. Persistent
  /// thumbnail storage is WebP, so optimized handlers override this directly.
  Future<Uint8List?> buildThumbnailWebp(File file) async {
    final pngBytes = await buildThumbnailPng(file);
    if (pngBytes == null) return null;
    final decoded = img.decodeImage(pngBytes);
    if (decoded == null) {
      throw FileSystemException(
          'Thumbnail WebP encoding decode failed', file.path);
    }
    return encodeThumbnailWebp(decoded);
  }
}

class FileFormatRegistry {
  static const _handlers = <FileFormatHandler>[
    TextFileHandler(),
    PdfFileHandler(),
    EpubFileHandler(),
    DocxFileHandler(),
    ImageFileHandler(),
    AudioFileHandler(),
    VideoFileHandler(),
  ];

  static FileFormatHandler? resolvePath(String path) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return resolveFormat(ext);
  }

  static FileFormatHandler? resolveFormat(String format) {
    final ext = format.replaceFirst('.', '').toLowerCase().trim();
    for (final handler in _handlers) {
      if (handler.extensions.contains(ext)) return handler;
    }
    return null;
  }

  static ViewerKind viewerKindForFormat(String format) {
    return resolveFormat(format)?.viewerKind ?? ViewerKind.externalLauncher;
  }

  static bool isPlayableFormat(String format) {
    final viewerKind = viewerKindForFormat(format);
    return viewerKind == ViewerKind.audioPlayer ||
        viewerKind == ViewerKind.videoPlayer;
  }
}

/// Reads media duration during indexing so browse cards never need to open a
/// player merely to show their duration.
Future<int?> probeMediaDurationMs(File file) async {
  final candidates = <String>{
    if (_cachedFfprobeExecutable != null) _cachedFfprobeExecutable!,
    ..._ffprobeExecutableCandidates(),
  };
  for (final executable in candidates) {
    try {
      final result = await Process.run(executable, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        file.path,
      ]);
      if (result.exitCode != 0) continue;
      _cachedFfprobeExecutable = executable;
      final seconds = double.tryParse(result.stdout.toString().trim());
      if (seconds == null || !seconds.isFinite || seconds <= 0) continue;
      return (seconds * Duration.millisecondsPerSecond).round();
    } on ProcessException {
      // Try the next bundled or configured ffprobe executable.
    }
  }
  return null;
}

String? _cachedFfprobeExecutable;

class TextFileHandler extends FileFormatHandler {
  const TextFileHandler()
      : super(
          entityType: EntityType.text,
          viewerKind: ViewerKind.textReader,
          extensions: const {'txt', 'md'},
        );
}

class ImageFileHandler extends FileFormatHandler {
  const ImageFileHandler()
      : super(
          entityType: EntityType.image,
          viewerKind: ViewerKind.imageViewer,
          extensions: const {'jpg', 'jpeg', 'png', 'webp', 'gif'},
        );

  @override
  bool get supportsGeneratedThumbnail => true;

  @override
  Future<Uint8List> buildThumbnailPng(File file) async {
    try {
      final image = img.decodeImage(await file.readAsBytes());
      if (image == null) {
        throw FileSystemException('Image thumbnail decode failed', file.path);
      }
      return Uint8List.fromList(_encodeAdaptivePngThumbnail(image));
    } on FileSystemException {
      rethrow;
    } catch (error) {
      throw FileSystemException('Image thumbnail decode failed', file.path);
    }
  }

  @override
  Future<Uint8List> buildThumbnailWebp(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return Isolate.run(() => _encodeAdaptiveWebpThumbnail(bytes));
    } on FileSystemException {
      rethrow;
    } catch (_) {
      throw FileSystemException('Image thumbnail decode failed', file.path);
    }
  }
}

class PdfFileHandler extends FileFormatHandler {
  const PdfFileHandler()
      : super(
          entityType: EntityType.externalLink,
          viewerKind: ViewerKind.pdfReader,
          extensions: const {'pdf'},
        );

  @override
  bool get supportsGeneratedThumbnail => true;

  @override
  Future<Uint8List?> buildThumbnailPng(File file) =>
      buildDocumentPreviewPng(file);

  @override
  Future<Uint8List?> buildThumbnailWebp(File file) =>
      buildDocumentPreviewWebp(file);
}

class EpubFileHandler extends FileFormatHandler {
  const EpubFileHandler()
      : super(
          entityType: EntityType.externalLink,
          viewerKind: ViewerKind.epubReader,
          extensions: const {'epub'},
        );

  @override
  bool get supportsGeneratedThumbnail => true;

  @override
  Future<Uint8List?> buildThumbnailPng(File file) =>
      buildDocumentPreviewPng(file);

  @override
  Future<Uint8List?> buildThumbnailWebp(File file) =>
      buildDocumentPreviewWebp(file);
}

class DocxFileHandler extends FileFormatHandler {
  const DocxFileHandler()
      : super(
          entityType: EntityType.externalLink,
          viewerKind: ViewerKind.docxReader,
          extensions: const {'docx'},
        );

  @override
  bool get supportsGeneratedThumbnail => true;

  @override
  Future<Uint8List?> buildThumbnailPng(File file) =>
      buildDocumentPreviewPng(file);

  @override
  Future<Uint8List?> buildThumbnailWebp(File file) =>
      buildDocumentPreviewWebp(file);
}

List<int> _encodeAdaptivePngThumbnail(img.Image source) {
  final targetWidth = source.width.clamp(1, thumbnailWidth).toInt();
  final targetHeight = (source.height * targetWidth / source.width)
      .round()
      .clamp(1, 1 << 30)
      .toInt();
  final resized = img.copyResize(
    source,
    width: targetWidth,
    height: targetHeight,
  );
  return img.encodePng(resized, level: 6);
}

Uint8List _encodeAdaptiveWebpThumbnail(Uint8List sourceBytes) {
  final source = img.decodeImage(sourceBytes);
  if (source == null) {
    throw const FormatException('Image thumbnail decode failed');
  }
  final targetWidth = source.width.clamp(1, thumbnailWidth).toInt();
  final targetHeight = (source.height * targetWidth / source.width)
      .round()
      .clamp(1, 1 << 30)
      .toInt();
  final resized = img.copyResize(
    source,
    width: targetWidth,
    height: targetHeight,
  );
  return encodeThumbnailWebp(resized);
}

class AudioFileHandler extends FileFormatHandler {
  const AudioFileHandler()
      : super(
          entityType: EntityType.audio,
          viewerKind: ViewerKind.audioPlayer,
          extensions: const {'mp3', 'wav', 'flac', 'm4a'},
        );
}

class VideoFileHandler extends FileFormatHandler {
  const VideoFileHandler({
    this.backend = const FfmpegVideoThumbnailBackend(),
  }) : super(
          entityType: EntityType.video,
          viewerKind: ViewerKind.videoPlayer,
          extensions: const {
            'mp4',
            'mov',
            'mkv',
            'webm',
            'avi',
            'wmv',
            'flv',
            'm4v',
          },
        );

  final VideoThumbnailBackend backend;

  @override
  bool get supportsGeneratedThumbnail => true;

  @override
  Future<Uint8List> buildThumbnailPng(File file) {
    return backend.buildFirstFramePng(file);
  }

  @override
  Future<Uint8List> buildThumbnailWebp(File file) {
    return backend.buildFirstFrameWebp(file);
  }
}

abstract class VideoThumbnailBackend {
  const VideoThumbnailBackend();

  Future<Uint8List> buildFirstFramePng(File file);

  Future<Uint8List> buildFirstFrameWebp(File file) => buildFirstFramePng(file);

  Future<VideoThumbnailResult> buildFirstFrameWebpWithMetadata(
      File file) async {
    final bytes = await buildFirstFrameWebp(file);
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw FileSystemException('Video thumbnail decode failed', file.path);
    }
    return VideoThumbnailResult(
      bytes: bytes,
      width: image.width,
      height: image.height,
    );
  }
}

class VideoThumbnailResult {
  const VideoThumbnailResult({
    required this.bytes,
    required this.width,
    required this.height,
    this.durationMs,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int? durationMs;
}

class FfmpegVideoThumbnailBackend extends VideoThumbnailBackend {
  const FfmpegVideoThumbnailBackend({
    this.executable = 'ffmpeg',
    this.executableArgumentsPrefix = const [],
  });

  final String executable;
  final List<String> executableArgumentsPrefix;
  static String? _cachedGeneralExecutable;
  static String? _cachedWebpExecutable;

  @override
  Future<Uint8List> buildFirstFramePng(File file) async {
    final tempDir = await Directory.systemTemp.createTemp('best_viewer_thumb_');
    final outputPath = p.join(tempDir.path, 'frame.png');
    try {
      var result = await _runFirstAvailableFfmpeg(
        _thumbnailArguments(file.path, outputPath, seekSeconds: 2),
      );
      if ((result.exitCode != 0 || !File(outputPath).existsSync()) &&
          !file.path.toLowerCase().endsWith('.url')) {
        result = await _runFirstAvailableFfmpeg(
          _thumbnailArguments(file.path, outputPath),
        );
      }
      if (result.exitCode != 0 || !File(outputPath).existsSync()) {
        throw FileSystemException(
          'Video thumbnail generation failed: ${result.stderr}',
          file.path,
        );
      }
      return await File(outputPath).readAsBytes();
    } on ProcessException catch (error) {
      throw FileSystemException(
        'ffmpeg not available for video thumbnail generation: ${error.message}',
        file.path,
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  @override
  Future<Uint8List> buildFirstFrameWebp(File file) async {
    final result = await buildFirstFrameWebpWithMetadata(file);
    return result.bytes;
  }

  @override
  Future<VideoThumbnailResult> buildFirstFrameWebpWithMetadata(
    File file,
  ) async {
    try {
      var result = await _runFfmpegUntilSuccess(
        _rawFrameArguments(file.path, seekSeconds: 2, includeMetadata: true),
        stdoutEncoding: null,
      );
      if (result.exitCode != 0 ||
          result.stdout is! List<int> ||
          (result.stdout as List<int>).isEmpty) {
        result = await _runFfmpegUntilSuccess(
          _rawFrameArguments(file.path, includeMetadata: true),
          stdoutEncoding: null,
        );
      }
      if (result.exitCode != 0 ||
          result.stdout is! List<int> ||
          (result.stdout as List<int>).isEmpty) {
        throw FileSystemException(
          'Video thumbnail generation failed: ${result.stderr}',
          file.path,
        );
      }
      final frameBytes = result.stdout as List<int>;
      if (frameBytes.isEmpty) {
        throw FileSystemException('Video frame output was empty', file.path);
      }
      final webpBytes = Uint8List.fromList(frameBytes);
      final dimensions = readWebpDimensions(webpBytes);
      if (dimensions == null) {
        throw FileSystemException('Video WebP header was invalid', file.path);
      }
      return VideoThumbnailResult(
        bytes: webpBytes,
        width: dimensions.width,
        height: dimensions.height,
        durationMs: _parseFfmpegDurationMs(result.stderr.toString()),
      );
    } on ProcessException catch (error) {
      throw FileSystemException(
        'ffmpeg not available for video thumbnail generation: ${error.message}',
        file.path,
      );
    }
  }

  List<String> _thumbnailArguments(
    String inputPath,
    String outputPath, {
    int? seekSeconds,
  }) {
    return [
      ...executableArgumentsPrefix,
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      if (seekSeconds != null) ...[
        '-ss',
        '00:00:${seekSeconds.toString().padLeft(2, '0')}'
      ],
      '-i',
      inputPath,
      '-frames:v',
      '1',
      '-vf',
      _ffmpegContainFilter,
      outputPath,
    ];
  }

  List<String> _rawFrameArguments(
    String inputPath, {
    int? seekSeconds,
    bool includeMetadata = false,
  }) {
    return [
      ...executableArgumentsPrefix,
      '-y',
      if (!includeMetadata) '-hide_banner',
      '-loglevel',
      includeMetadata ? 'info' : 'error',
      if (seekSeconds != null) ...[
        '-ss',
        '00:00:${seekSeconds.toString().padLeft(2, '0')}'
      ],
      '-i',
      inputPath,
      '-frames:v',
      '1',
      '-vf',
      _ffmpegContainFilter,
      '-f',
      'image2pipe',
      '-c:v',
      'libwebp',
      '-q:v',
      '$thumbnailWebpQuality',
      'pipe:1',
    ];
  }

  Future<ProcessResult> _runFirstAvailableFfmpeg(
    List<String> arguments, {
    Encoding? stdoutEncoding = systemEncoding,
  }) async {
    ProcessException? lastError;
    final candidates = <String>{
      if (executable == 'ffmpeg' && _cachedGeneralExecutable != null)
        _cachedGeneralExecutable!,
      ..._ffmpegExecutableCandidates(),
    };
    for (final candidate in candidates) {
      try {
        final result = await Process.run(
          candidate,
          arguments,
          stdoutEncoding: stdoutEncoding,
        );
        if (executable == 'ffmpeg') _cachedGeneralExecutable = candidate;
        return result;
      } on ProcessException catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) throw lastError;
    return Process.run(executable, arguments, stdoutEncoding: stdoutEncoding);
  }

  /// Some bundled FFmpeg builds decode video but omit `libwebp`. For direct
  /// WebP thumbnails, keep trying candidates until one completes encoding.
  Future<ProcessResult> _runFfmpegUntilSuccess(
    List<String> arguments, {
    Encoding? stdoutEncoding = systemEncoding,
  }) async {
    ProcessException? lastError;
    ProcessResult? lastResult;
    final candidates = <String>{
      if (executable == 'ffmpeg' && _cachedWebpExecutable != null)
        _cachedWebpExecutable!,
      ..._ffmpegExecutableCandidates(),
    };
    for (final candidate in candidates) {
      try {
        final result = await Process.run(
          candidate,
          arguments,
          stdoutEncoding: stdoutEncoding,
        );
        if (result.exitCode == 0) {
          if (executable == 'ffmpeg') _cachedWebpExecutable = candidate;
          return result;
        }
        lastResult = result;
      } on ProcessException catch (error) {
        lastError = error;
      }
    }
    if (lastResult != null) return lastResult;
    if (lastError != null) throw lastError;
    return Process.run(executable, arguments, stdoutEncoding: stdoutEncoding);
  }

  List<String> _ffmpegExecutableCandidates() {
    if (executable != 'ffmpeg') return [executable];
    final envCandidates = [
      Platform.environment['BEST_VIEWER_FFMPEG'],
      Platform.environment['FFMPEG_PATH'],
    ].whereType<String>().where((path) => path.trim().isNotEmpty);
    final candidates = <String>[
      ...envCandidates,
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
      executable,
      if (Platform.isWindows) ...const [
        r'C:\Program Files\Topaz Labs LLC\Topaz Video\ffmpeg.exe',
        r'C:\Program Files\Topaz Labs LLC\Topaz Video AI\ffmpeg.exe',
        r'C:\Program Files (x86)\FormatFactory\ffmpeg.exe',
      ],
    ];
    return candidates.toSet().toList();
  }
}

int? _parseFfmpegDurationMs(String output) {
  final match = RegExp(
    r'Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
  ).firstMatch(output);
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '');
  final minutes = int.tryParse(match.group(2) ?? '');
  final seconds = double.tryParse(match.group(3) ?? '');
  if (hours == null ||
      minutes == null ||
      seconds == null ||
      !seconds.isFinite) {
    return null;
  }
  return ((hours * 3600 + minutes * 60 + seconds) * 1000).round();
}

List<String> _ffprobeExecutableCandidates() {
  final configured = Platform.environment['BEST_VIEWER_FFPROBE'];
  final configuredFfmpeg = Platform.environment['BEST_VIEWER_FFMPEG'] ??
      Platform.environment['FFMPEG_PATH'];
  final candidates = <String>[
    p.join(
      File(Platform.resolvedExecutable).parent.path,
      'ffmpeg',
      'ffprobe.exe',
    ),
    p.join(
      Directory.current.path,
      'tools',
      'ffmpeg',
      'windows',
      'ffmpeg-8.1.2-essentials_build',
      'bin',
      'ffprobe.exe',
    ),
    if (configured != null && configured.trim().isNotEmpty) configured,
    if (configuredFfmpeg != null && configuredFfmpeg.trim().isNotEmpty)
      p.join(p.dirname(configuredFfmpeg), 'ffprobe.exe'),
    'ffprobe',
    if (Platform.isWindows) ...const [
      r'C:\Program Files\Topaz Labs LLC\Topaz Video\ffprobe.exe',
      r'C:\Program Files\Topaz Labs LLC\Topaz Video AI\ffprobe.exe',
      r'C:\Program Files (x86)\FormatFactory\ffprobe.exe',
    ],
  ];
  return candidates.toSet().toList();
}

const _ffmpegContainFilter = "scale='min(iw,$thumbnailWidth)':-2,format=rgba";
