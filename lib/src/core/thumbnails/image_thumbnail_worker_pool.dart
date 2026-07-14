import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../formats/thumbnail_spec.dart';
import 'thumbnail_cancellation.dart';
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
  Future<void>? _closeFuture;
  bool _closed = false;

  Future<ThumbnailArtifact> encode(
    File file, {
    ThumbnailCancellationToken? cancellationToken,
  }) {
    if (_closed) {
      return Future<ThumbnailArtifact>.error(
        StateError('Image worker pool is closed'),
      );
    }
    cancellationToken?.throwIfCancelled();
    final completer = Completer<ThumbnailArtifact>();
    _pending.add(_ImageThumbnailJob(file.path, completer, cancellationToken));
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
      eagerError: true,
      cleanUp: (worker) {
        unawaited(worker.close(force: true));
      },
    ).then<void>((workers) async {
      if (_closed) {
        await Future.wait(workers.map((worker) => worker.close(force: true)));
        return;
      }
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
        worker
            .run(job.path, cancellationToken: job.cancellationToken)
            .then(job.completer.complete)
            .catchError((
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

  Future<void> close({bool cancelRunning = false}) {
    return _closeFuture ??= _closeImpl(cancelRunning: cancelRunning);
  }

  Future<void> cancel() => close(cancelRunning: true);

  Future<void> _closeImpl({required bool cancelRunning}) async {
    _closed = true;
    final error = cancelRunning
        ? const ThumbnailTaskCanceledException()
        : StateError('Image worker pool closed before task started');
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      if (!job.completer.isCompleted) job.completer.completeError(error);
    }
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // Failed startup is already cleaned by Future.wait's cleanUp hook.
      }
    }
    final workers = List<_ImageThumbnailWorker>.of(_workers);
    _workers.clear();
    await Future.wait(
      workers.map((worker) => worker.close(force: cancelRunning)),
    );
  }
}

class _ImageThumbnailJob {
  _ImageThumbnailJob(this.path, this.completer, this.cancellationToken);

  final String path;
  final Completer<ThumbnailArtifact> completer;
  final ThumbnailCancellationToken? cancellationToken;
}

class _ImageThumbnailWorker {
  _ImageThumbnailWorker(this._sendPort, this._isolate);

  final SendPort _sendPort;
  final Isolate _isolate;
  bool busy = false;
  bool _closed = false;
  Completer<ThumbnailArtifact>? _activeCompleter;

  static Future<_ImageThumbnailWorker> start() async {
    final readyPort = ReceivePort();
    final isolate =
        await Isolate.spawn(_imageThumbnailWorkerMain, readyPort.sendPort);
    final sendPort = (await readyPort.first) as SendPort;
    readyPort.close();
    return _ImageThumbnailWorker(sendPort, isolate);
  }

  Future<ThumbnailArtifact> run(
    String path, {
    ThumbnailCancellationToken? cancellationToken,
  }) async {
    if (_closed) throw const ThumbnailTaskCanceledException();
    cancellationToken?.throwIfCancelled();
    final response = ReceivePort();
    final completer = Completer<ThumbnailArtifact>();
    _activeCompleter = completer;
    void cancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          cancellationToken?.isCancelled == true
              ? const ThumbnailTaskCanceledException()
              : const ThumbnailTaskPausedException(),
        );
      }
      _isolate.kill(priority: Isolate.immediate);
    }
    cancellationToken?.addListener(cancel);
    response.listen((rawMessage) {
      if (completer.isCompleted) return;
      final message = rawMessage as List<Object?>;
      if (message.first != true) {
        completer
            .completeError(FileSystemException(message[1] as String, path));
        return;
      }
      final bytes = (message[1] as TransferableTypedData).materialize();
      completer.complete(ThumbnailArtifact(
        bytes: bytes.asUint8List(),
        width: message[2]! as int,
        height: message[3]! as int,
        sourcePixelCount: message[4]! as int,
        readMs: message[5]! as int,
        decodeMs: message[6]! as int,
        resizeMs: message[7]! as int,
        encodeMs: message[8]! as int,
      ));
    });
    _sendPort.send(<Object>[path, response.sendPort]);
    try {
      return await completer.future;
    } finally {
      cancellationToken?.removeListener(cancel);
      response.close();
      if (identical(_activeCompleter, completer)) _activeCompleter = null;
    }
  }

  Future<void> close({required bool force}) async {
    if (_closed) return;
    _closed = true;
    if (force) {
      _activeCompleter?.completeError(const ThumbnailTaskCanceledException());
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    _sendPort.send(null);
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
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
      final dimensions = thumbnailDimensionsForTargetPixelCount(
        source.width,
        source.height,
      );
      final width = dimensions.width;
      final height = dimensions.height;
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
