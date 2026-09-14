import 'dart:async';

/// Durable dirty rows are authoritative; polling repairs missed notifications.
/// A failed signature is tried once per process, never in a tight retry loop.
class DirtyPreviewScheduler {
  DirtyPreviewScheduler(
      {required this.isBusy,
      required this.load,
      required this.rebuild,
      required this.onError});
  final bool Function() isBusy;
  final Future<Map<String, String>> Function() load;
  final Future<void> Function(String rootId) rebuild;
  final void Function(Object, StackTrace) onError;
  final _attempted = <String, String>{};
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false;

  void start() {
    if (_closed || _timer != null) return;
    _timer =
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(tick()));
    unawaited(tick());
  }

  Future<void> tick() {
    if (_closed || isBusy()) return Future.value();
    return _running ??= _tick().whenComplete(() => _running = null);
  }

  Future<void> _tick() async {
    try {
      final roots = await load();
      for (final root in roots.entries) {
        if (_closed || isBusy()) break;
        if (_attempted[root.key] == root.value) continue;
        _attempted[root.key] = root.value;
        await rebuild(root.key);
      }
    } catch (error, stack) {
      onError(error, stack);
    }
  }

  void stop() {
    _closed = true;
    _timer?.cancel();
  }

  Future<void> close() async {
    stop();
    await _running;
  }
}
