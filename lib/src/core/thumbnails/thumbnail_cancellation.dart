/// Cooperative cancellation shared by thumbnail services and their workers.
/// It is deliberately independent from Flutter so it can also be used by
/// platform and isolate-facing code.
class ThumbnailCancellationToken {
  bool _cancelled = false;
  bool _paused = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused && !_cancelled;
  bool get isStopped => _cancelled || _paused;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _paused = false;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Stops active work for a paused scan. A resumed scan creates a fresh
  /// token and retries the durable candidate from its last checkpoint.
  void pause() {
    if (_cancelled || _paused) return;
    _paused = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    _listeners.add(listener);
    if (isStopped) listener();
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void throwIfCancelled() {
    if (_cancelled) throw const ThumbnailTaskCanceledException();
    if (_paused) throw const ThumbnailTaskPausedException();
  }
}

class ThumbnailTaskPausedException implements Exception {
  const ThumbnailTaskPausedException();

  @override
  String toString() => 'Thumbnail task paused';
}

class ThumbnailTaskCanceledException implements Exception {
  const ThumbnailTaskCanceledException();

  @override
  String toString() => 'Thumbnail task canceled';
}
