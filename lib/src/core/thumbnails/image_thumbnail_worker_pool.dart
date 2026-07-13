import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../formats/thumbnail_spec.dart';
import 'thumbnail_artifact.dart';
import 'webp_encoder.dart';

/// Reuses a fixed set of isolates so bulk image imports do not pay isolate
/// startup cost once per file or block the Flutter UI isolate.
class ImageThumbnailWorkerPool {
  ImageThumbnailWorkerPool({this.workerCount = 10});

  final int workerCount;
  final Queue<_ImageThumbnailJob> _pending = Queue<_ImageThumbnailJob>();
  final List<_ImageThumbnailWorker> _workers = <_ImageThumbnailWorker>[];
  Future<void>? _starting;
  bool _closed = false;

  Future<ThumbnailArtifact> encode(File file) {
    if (_closed) {
      return Future<ThumbnailArtifact>.error(
        StateError('Image worker pool is closed'),
      );
    }
    final completer = Completer<ThumbnailArtifact>();
    _pending.add(_ImageThumbnailJob(file.path, completer));
    unawaited(
      _ensureWorkers().then((_) => _drain()).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _failPending(error, stackTrace);
      }),
    );
    return completer.future;
  }

  Future<void> _ensureWorkers() {
    if (_workers.isNotEmpty) return Future<void>.value();
    return _starting ??= Future.wait(
      List.generate(workerCount, (_) => _ImageThumbnailWorker.start()),
    ).then((workers) {
      _workers.addAll(workers);
    });
  }

  void _drain() {
    if (_closed) return;
    for (final worker in _workers) {
      if (worker.busy || _pending.isEmpty) continue;
      final job = _pending.removeFirst();
      worker.busy = true;
      unawaited(
        worker.run(job.path).then(job.completer.complete).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          job.completer.completeError(error, stackTrace);
        }).whenComplete(() {
          worker.busy = false;
          _drain();
        }),
      );
    }
  }

  void _failPending(Object error, StackTrace stackTrace) {
    _closed = true;
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.completeError(error, stackTrace);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completer.completeError(
            StateError('Image worker pool closed before task started'),
          );
    }
    for (final worker in _workers) {
      worker.close();
    }
    _workers.clear();
  }
}

class _ImageThumbnailJob {
  _ImageThumbnailJob(this.path, this.completer);

  final String path;
  final Completer<ThumbnailArtifact> completer;
}

class _ImageThumbnailWorker {
  _ImageThumbnailWorker(this._sendPort);

  final SendPort _sendPort;
  bool busy = false;

  static Future<_ImageThumbnailWorker> start() async {
    final readyPort = ReceivePort();
    await Isolate.spawn(_imageThumbnailWorkerMain, readyPort.sendPort);
    final sendPort = (await readyPort.first) as SendPort;
    readyPort.close();
    return _ImageThumbnailWorker(sendPort);
  }

  Future<ThumbnailArtifact> run(String path) async {
    final response = ReceivePort();
    _sendPort.send(<Object>[path, response.sendPort]);
    final message = (await response.first) as List<Object?>;
    response.close();
    if (message.first != true) {
      throw FileSystemException(message[1] as String, path);
    }
    final bytes = (message[1] as TransferableTypedData).materialize();
    return ThumbnailArtifact(
      bytes: bytes.asUint8List(),
      width: message[2]! as int,
      height: message[3]! as int,
      sourcePixelCount: message[4]! as int,
      readMs: message[5]! as int,
      decodeMs: message[6]! as int,
      resizeMs: message[7]! as int,
      encodeMs: message[8]! as int,
    );
  }

  void close() => _sendPort.send(null);
}

void _imageThumbnailWorkerMain(SendPort readyPort) {
  final receivePort = ReceivePort();
  readyPort.send(receivePort.sendPort);
  receivePort.listen((message) async {
    if (message == null) {
      receivePort.close();
      return;
    }
    final task = message as List<Object>;
    final path = task[0] as String;
    final responsePort = task[1] as SendPort;
    try {
      final stage = Stopwatch()..start();
      final sourceBytes = await File(path).readAsBytes();
      final readMs = stage.elapsedMilliseconds;
      stage.reset();
      final source = img.decodeImage(sourceBytes);
      if (source == null) {
        throw const FormatException('Image thumbnail decode failed');
      }
      final decodeMs = stage.elapsedMilliseconds;
      stage.reset();
      final width = source.width.clamp(1, thumbnailWidth).toInt();
      final height = (source.height * width / source.width)
          .round()
          .clamp(1, 1 << 30)
          .toInt();
      final resized = img.copyResize(source, width: width, height: height);
      final resizeMs = stage.elapsedMilliseconds;
      stage.reset();
      final encoded = encodeThumbnailWebp(resized);
      final encodeMs = stage.elapsedMilliseconds;
      responsePort.send(<Object>[
        true,
        TransferableTypedData.fromList(<Uint8List>[encoded]),
        width,
        height,
        source.width * source.height,
        readMs,
        decodeMs,
        resizeMs,
        encodeMs,
      ]);
    } catch (error) {
      responsePort.send(<Object>[false, '$error']);
    }
  });
}
