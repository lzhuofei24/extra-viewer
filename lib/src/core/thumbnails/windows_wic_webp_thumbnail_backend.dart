import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';
import 'thumbnail_cancellation.dart';

/// Windows-only WIC decoder plus libwebp encoder. It down-samples while
/// decoding and performs all pixel work outside the Flutter UI isolate.
class WindowsWicWebpThumbnailBackend {
  Future<ThumbnailArtifact?> encode(
    File file, {
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    if (!Platform.isWindows) return null;
    cancellationToken?.throwIfCancelled();
    final result = await _runWicThumbnail(
      file.path,
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCancelled();
    if (result == null) return null;
    return ThumbnailArtifact(
      bytes: result.bytes,
      width: result.width,
      height: result.height,
      encodeMs: result.elapsedMs,
    );
  }
}

/// Encodes an RGBA canvas with the same bundled libwebp used by the Windows
/// thumbnail backend. The native call runs in a short-lived isolate so node
/// preview encoding never blocks Flutter's UI isolate.
Future<Uint8List?> encodeRgbaWebpOnWindows(
  Uint8List pixels, {
  required int width,
  required int height,
  required double quality,
}) async {
  if (!Platform.isWindows) return null;
  return Isolate.run(
    () => _encodeRgbaWebpNative(pixels, width, height, quality),
  );
}

Future<_WicThumbnailResult?> _runWicThumbnail(
  String path, {
  ThumbnailCancellationToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCancelled();
  final response = ReceivePort();
  final isolate = await Isolate.spawn(
    _wicThumbnailWorkerMain,
    <Object>[path, response.sendPort],
  );
  final result = Completer<_WicThumbnailResult?>();
  void cancel() {
    if (result.isCompleted) return;
    isolate.kill(priority: Isolate.immediate);
    result.completeError(const ThumbnailTaskCanceledException());
  }

  final subscription = response.listen((rawMessage) {
    if (result.isCompleted) return;
    final message = rawMessage as List<Object?>;
    if (message.first != true) {
      result.complete(null);
      return;
    }
    final bytes = (message[1] as TransferableTypedData).materialize();
    result.complete(_WicThumbnailResult(
      bytes.asUint8List(),
      message[2]! as int,
      message[3]! as int,
      message[4]! as int,
    ));
  });
  cancellationToken?.addListener(cancel);
  try {
    cancellationToken?.throwIfCancelled();
    return await result.future;
  } finally {
    cancellationToken?.removeListener(cancel);
    await subscription.cancel();
    response.close();
    isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _wicThumbnailWorkerMain(List<Object> message) {
  final path = message[0] as String;
  final reply = message[1] as SendPort;
  try {
    final result = _encodeWicThumbnail(path);
    if (result == null) {
      reply.send(const <Object?>[false]);
      return;
    }
    reply.send(<Object?>[
      true,
      TransferableTypedData.fromList(<Uint8List>[result.bytes]),
      result.width,
      result.height,
      result.elapsedMs,
    ]);
  } catch (_) {
    reply.send(const <Object?>[false]);
  }
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
      thumbnailTargetPixelCount,
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

Uint8List? _encodeRgbaWebpNative(
  Uint8List pixels,
  int width,
  int height,
  double quality,
) {
  final bindings = _WicBindings.tryLoad();
  if (bindings == null) return null;
  final input = calloc<Uint8>(pixels.length);
  final output = calloc<Pointer<Uint8>>();
  final outputSize = calloc<UintPtr>();
  try {
    input.asTypedList(pixels.length).setAll(0, pixels);
    final result = bindings.encodeRgba(
      input,
      width,
      height,
      quality,
      output,
      outputSize,
    );
    if (result < 0 || output.value == nullptr || outputSize.value == 0) {
      return null;
    }
    final bytes = Uint8List.fromList(
      output.value.asTypedList(outputSize.value),
    );
    bindings.free(output.value);
    output.value = nullptr;
    return bytes;
  } finally {
    if (output.value != nullptr) bindings.free(output.value);
    calloc.free(input);
    calloc.free(output);
    calloc.free(outputSize);
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
  _WicBindings(this.create, this.free, this.encodeRgba);

  static _WicBindings? _instance;
  static bool _unavailable = false;

  final _CreateThumbnailDart create;
  final _FreeThumbnailDart free;
  final _EncodeRgbaDart encodeRgba;

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
        library.lookupFunction<_EncodeRgbaNative, _EncodeRgbaDart>(
          'BestViewerEncodeRGBA',
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
typedef _EncodeRgbaNative = Int32 Function(
  Pointer<Uint8> pixels,
  Int32 width,
  Int32 height,
  Float quality,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> outputSize,
);
typedef _EncodeRgbaDart = int Function(
  Pointer<Uint8> pixels,
  int width,
  int height,
  double quality,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> outputSize,
);
