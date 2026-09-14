import 'dart:async';

/// Serializes time-based tail commits with the final page/pause boundary.
/// The caller supplies a flush that snapshots and drains its pending results.
class PeriodicCheckpoint {
  PeriodicCheckpoint(this._commit,
      {Duration interval = const Duration(seconds: 2)}) {
    _timer = Timer.periodic(interval, (_) {
      unawaited(_flush().catchError((Object error, StackTrace stack) {
        _failure ??= (error, stack);
      }));
    });
  }

  final Future<void> Function() _commit;
  late final Timer _timer;
  Future<void>? _running;
  (Object, StackTrace)? _failure;
  Future<void>? _closing;

  Future<void> _flush() async {
    if (_failure != null || _running != null) return;
    final pending = Future<void>.sync(_commit);
    _running = pending;
    try {
      await pending;
    } finally {
      _running = null;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _timer.cancel();
    await _running;
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
    await _flush();
  }
}
