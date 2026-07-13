import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';

/// Windows-only WIC decoder plus libwebp encoder. It down-samples while
/// decoding and performs all pixel work outside the Flutter UI isolate.
class WindowsWicWebpThumbnailBackend {
  Future<ThumbnailArtifact?> encode(File file) async {
    if (!Platform.isWindows) return null;
    final result = await _runWicThumbnail(file.path);
    if (result == null) return null;
    return ThumbnailArtifact(
      bytes: result.bytes,
      width: result.width,
      height: result.height,
      encodeMs: result.elapsedMs,
    );
  }
}

Future<_WicThumbnailResult?> _runWicThumbnail(String path) {
  return Isolate.run(() => _encodeWicThumbnail(path));
}

_WicThumbnailResult? _encodeWicThumbnail(String path) {
  final bindings = _WicBindings.tryLoad();
  if (bindings == null) return null;
  final watch = Stopwatch()..start();
  final nativePath = path.toNativeUtf16();
  final output = calloc<Pointer<Uint8>>();
  final outputSize = calloc<UintPtr>();
  final width = calloc<Int32>();
  final height = calloc<Int32>();
  try {
    final result = bindings.create(
      nativePath,
      thumbnailWidth,
      thumbnailWebpQuality.toDouble(),
      output,
      outputSize,
      width,
      height,
    );
    if (result < 0 || output.value == nullptr || outputSize.value == 0) {
      return null;
    }
    final bytes = Uint8List.fromList(
      output.value.asTypedList(outputSize.value),
    );
    bindings.free(output.value);
    output.value = nullptr;
    return _WicThumbnailResult(
        bytes, width.value, height.value, watch.elapsedMilliseconds);
  } finally {
    if (output.value != nullptr) bindings.free(output.value);
    calloc.free(nativePath);
    calloc.free(output);
    calloc.free(outputSize);
    calloc.free(width);
    calloc.free(height);
  }
}

class _WicThumbnailResult {
  const _WicThumbnailResult(
      this.bytes, this.width, this.height, this.elapsedMs);

  final Uint8List bytes;
  final int width;
  final int height;
  final int elapsedMs;
}

final class _WicBindings {
  _WicBindings(this.create, this.free);

  static _WicBindings? _instance;
  static bool _unavailable = false;

  final _CreateThumbnailDart create;
  final _FreeThumbnailDart free;

  static _WicBindings? tryLoad() {
    if (_unavailable) return null;
    final cached = _instance;
    if (cached != null) return cached;
    try {
      final library = DynamicLibrary.open(_libraryPath());
      return _instance = _WicBindings(
        library.lookupFunction<_CreateThumbnailNative, _CreateThumbnailDart>(
          'BestViewerCreateThumbnail',
        ),
        library.lookupFunction<_FreeThumbnailNative, _FreeThumbnailDart>(
          'BestViewerFreeThumbnail',
        ),
      );
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  static String _libraryPath() {
    const name = 'best_viewer_thumbnail_native.dll';
    final candidates = <String>[
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name',
      '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}windows${Platform.pathSeparator}x64${Platform.pathSeparator}runner${Platform.pathSeparator}Debug${Platform.pathSeparator}$name',
    ];
    return candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => candidates.first,
    );
  }
}

typedef _CreateThumbnailNative = Int32 Function(
  Pointer<Utf16> inputPath,
  Int32 maxWidth,
  Float quality,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> outputSize,
  Pointer<Int32> width,
  Pointer<Int32> height,
);
typedef _CreateThumbnailDart = int Function(
  Pointer<Utf16> inputPath,
  int maxWidth,
  double quality,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> outputSize,
  Pointer<Int32> width,
  Pointer<Int32> height,
);
typedef _FreeThumbnailNative = Void Function(Pointer<Uint8> output);
typedef _FreeThumbnailDart = void Function(Pointer<Uint8> output);
