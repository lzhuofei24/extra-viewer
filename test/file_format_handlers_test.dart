import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/formats/file_format_handlers.dart';
import 'package:best_viewer/src/core/formats/thumbnail_spec.dart';

void main() {
  test('media thumbnail dimensions preserve ratio near the target area', () {
    final landscape = thumbnailDimensionsForTargetPixelCount(4000, 2000);
    final portrait = thumbnailDimensionsForTargetPixelCount(2000, 4000);

    expect(landscape.width / landscape.height, closeTo(2, .01));
    expect(portrait.width / portrait.height, closeTo(.5, .01));
    expect(landscape.width * landscape.height,
        closeTo(thumbnailTargetPixelCount, 1200));
    expect(portrait.width * portrait.height,
        closeTo(thumbnailTargetPixelCount, 1200));
  });

  test('format registry resolves stored formats and source paths', () {
    expect(
      FileFormatRegistry.resolveFormat('MP4')?.viewerKind,
      ViewerKind.videoPlayer,
    );
    expect(
      FileFormatRegistry.resolveFormat('.txt')?.entityType,
      EntityType.text,
    );
    expect(
      FileFormatRegistry.resolvePath(r'D:\media\song.FLAC')?.viewerKind,
      ViewerKind.audioPlayer,
    );
    expect(
      FileFormatRegistry.resolvePath(r'D:\books\manual.PDF')?.viewerKind,
      ViewerKind.pdfReader,
    );
    expect(
      FileFormatRegistry.resolveFormat('docx')?.entityType,
      EntityType.externalLink,
    );
    expect(
      FileFormatRegistry.resolveFormat('epub')?.viewerKind,
      ViewerKind.epubReader,
    );
    expect(
      FileFormatRegistry.resolveFormat('docx')?.viewerKind,
      ViewerKind.docxReader,
    );
    for (final format in ['avi', 'wmv', 'flv', 'm4v']) {
      expect(
        FileFormatRegistry.resolveFormat(format)?.viewerKind,
        ViewerKind.videoPlayer,
      );
      expect(FileFormatRegistry.isPlayableFormat(format), isTrue);
    }
    expect(
      FileFormatRegistry.viewerKindForFormat('unknown'),
      ViewerKind.externalLauncher,
    );
    expect(FileFormatRegistry.isPlayableFormat('mp3'), isTrue);
    expect(FileFormatRegistry.isPlayableFormat('mkv'), isTrue);
    expect(FileFormatRegistry.isPlayableFormat('txt'), isFalse);
    expect(FileFormatRegistry.resolveFormat('unknown'), isNull);
  });

  test('image thumbnail contains the complete source on an opaque canvas',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_img_');
    addTearDown(() => temp.delete(recursive: true));
    final source = img.Image(width: 100, height: 300, numChannels: 4);
    for (var y = 0; y < source.height; y++) {
      final color = y < 100
          ? img.ColorRgba8(255, 0, 0, 255)
          : y < 200
              ? img.ColorRgba8(0, 255, 0, 255)
              : img.ColorRgba8(0, 0, 255, 255);
      img.fillRect(source,
          x1: 0, y1: y, x2: source.width - 1, y2: y, color: color);
    }
    final file = File('${temp.path}/portrait.png')
      ..writeAsBytesSync(img.encodePng(source));

    final thumbnailBytes = await const ImageFileHandler().buildThumbnailPng(
      file,
    );
    final thumbnail = img.decodePng(thumbnailBytes)!;

    expect(thumbnail.width, source.width);
    expect(thumbnail.height, source.height);
    expect(thumbnail.getPixel(0, 0).a, 255);
    expect(
        thumbnail.getPixel(thumbnail.width ~/ 2, thumbnail.height ~/ 2).g, 255);
    expect(
        thumbnail.getPixel(thumbnail.width ~/ 2, thumbnail.height ~/ 2).a, 255);
  });

  test('only media handlers generate persistent thumbnail files', () {
    expect(const ImageFileHandler().supportsGeneratedThumbnail, isTrue);
    expect(const VideoFileHandler().supportsGeneratedThumbnail, isTrue);
    expect(const TextFileHandler().supportsGeneratedThumbnail, isFalse);
    expect(const AudioFileHandler().supportsGeneratedThumbnail, isFalse);
  });

  test('image thumbnail failure is surfaced', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_bad_img_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/bad.png')..writeAsBytesSync([1, 2, 3]);

    expect(
      () => const ImageFileHandler().buildThumbnailPng(file),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('video thumbnail backend failure is surfaced', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_bad_vid_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/bad.mp4')..writeAsBytesSync([1, 2, 3]);
    final handler = VideoFileHandler(backend: _FailingVideoThumbnailBackend());

    expect(
      () => handler.buildThumbnailPng(file),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('ffmpeg video thumbnail uses contain filter with seek fallback',
      () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_ffmpeg_');
    addTearDown(() => temp.delete(recursive: true));
    final png = img.Image(
      width: thumbnailMaxEdge,
      height: thumbnailMaxEdge,
      numChannels: 4,
    );
    img.fill(png, color: img.ColorRgba8(0, 255, 0, 255));
    final fixture = File('${temp.path}/fixture.png')
      ..writeAsBytesSync(img.encodePng(png));
    final argsFile = File('${temp.path}/args.txt');
    final fakeFfmpeg = File('${temp.path}/fake_ffmpeg.ps1')
      ..writeAsStringSync('''
\$args -join ' ' | Set-Content -LiteralPath '${argsFile.path}'
Copy-Item -LiteralPath '${fixture.path}' -Destination \$args[-1] -Force
exit 0
''');
    final video = File('${temp.path}/video.mp4')..writeAsBytesSync([1, 2, 3]);

    final bytes = await FfmpegVideoThumbnailBackend(
      executable: 'powershell',
      executableArgumentsPrefix: [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        fakeFfmpeg.path,
      ],
    ).buildFirstFramePng(video);
    final args = await argsFile.readAsString();

    expect(img.decodePng(bytes), isNotNull);
    expect(args, contains('-ss 00:00:02'));
    expect(args, contains('sqrt($thumbnailTargetPixelCount/(iw*ih))'));
    expect(args, contains('format=rgba'));
  });

  test('ffmpeg emits WebP directly for indexed video thumbnails', () async {
    final temp = await Directory.systemTemp.createTemp('best_viewer_webp_');
    addTearDown(() => temp.delete(recursive: true));
    final webp = img.Image(width: thumbnailMaxEdge, height: 360);
    img.fill(webp, color: img.ColorRgba8(40, 180, 90, 255));
    final fixture = File('${temp.path}/fixture.webp')
      ..writeAsBytesSync(img.encodeWebP(webp));
    final argsFile = File('${temp.path}/args.txt');
    final fakeFfmpeg = File('${temp.path}/fake_ffmpeg.ps1')
      ..writeAsStringSync('''
\$args -join ' ' | Set-Content -LiteralPath '${argsFile.path}'
\$bytes = [System.IO.File]::ReadAllBytes('${fixture.path}')
\$output = [Console]::OpenStandardOutput()
\$output.Write(\$bytes, 0, \$bytes.Length)
exit 0
''');
    final video = File('${temp.path}/video.mp4')..writeAsBytesSync([1, 2, 3]);

    final result = await FfmpegVideoThumbnailBackend(
      executable: 'powershell',
      executableArgumentsPrefix: [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        fakeFfmpeg.path,
      ],
    ).buildFirstFrameWebpWithMetadata(video);
    final args = await argsFile.readAsString();

    expect(img.decodeWebP(result.bytes), isNotNull);
    expect(result.width, thumbnailMaxEdge);
    expect(result.height, 360);
    // PowerShell normalizes colon-style FFmpeg options to a space in $args.
    expect(args, contains(RegExp(r'-c(?::|\s+)v\s+libwebp')));
    expect(args, contains(RegExp(r'-q(?::|\s+)v\s+78')));
  });
}

class _FailingVideoThumbnailBackend extends VideoThumbnailBackend {
  @override
  Future<Uint8List> buildFirstFramePng(File file) {
    throw FileSystemException('forced video thumbnail failure', file.path);
  }
}
