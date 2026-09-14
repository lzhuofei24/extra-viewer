import 'dart:async';
import 'dart:isolate';

import 'thumbnail_cancellation.dart';

/// For pure Dart composition only. Native decoders retain their own resource
/// owner and use cooperative cancellation rather than isolate termination.
Future<T> runCancellableThumbnailTask<T>(FutureOr<T> Function() action,
    {ThumbnailCancellationToken? cancellationToken}) async {
  cancellationToken?.throwIfCancelled();
  final replies = ReceivePort();
  Isolate? worker;
  void stop() => replies.sendPort.send({'cancelled': true});
  try {
    final reply = replies.sendPort;
    worker = await Isolate.spawn(_runThumbnailTask<T>, (action, reply),
        onError: reply, onExit: reply);
    cancellationToken?.addListener(stop);
    final message = await replies.first;
    cancellationToken?.throwIfCancelled();
    if (message is Map && message.containsKey('value')) {
      return message['value'] as T;
    }
    throw StateError('Thumbnail worker failed: $message');
  } finally {
    cancellationToken?.removeListener(stop);
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

Future<void> _runThumbnailTask<T>(
    (FutureOr<T> Function(), SendPort) request) async {
  try {
    request.$2.send({'value': await request.$1()});
  } catch (error, stack) {
    request.$2.send({'error': '$error', 'stack': '$stack'});
  }
}
