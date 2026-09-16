import 'dart:io';

import 'thumbnail_cancellation.dart';

/// The caller owns this one-shot copy, never the original source.
Future<T> withTemporaryThumbnailSource<T>({
  required Object firstError,
  required Future<String> Function() materialize,
  required Future<T> Function(String path) decode,
  ThumbnailCancellationToken? cancellationToken,
}) async {
  String? path;
  try {
    cancellationToken?.throwIfCancelled();
    path = await materialize();
    cancellationToken?.throwIfCancelled();
    return await decode(path);
  } on ThumbnailTaskPausedException {
    rethrow;
  } on ThumbnailTaskCanceledException {
    rethrow;
  } catch (error) {
    throw StateError('Original decode: $firstError; fallback: $error');
  } finally {
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
