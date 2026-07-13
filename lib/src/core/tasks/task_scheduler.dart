import 'dart:async';
import 'dart:collection';

enum TaskPriority { interactive, prefetch, maintenance }

/// Small cooperative scheduler for local background work. Queued jobs can be
/// canceled by tag; running jobs must still cooperatively discard stale output.
class TaskScheduler {
  TaskScheduler({this.maxConcurrent = 1});

  final int maxConcurrent;
  final Map<TaskPriority, Queue<_ScheduledTask<dynamic>>> _queues = {
    for (final priority in TaskPriority.values)
      priority: Queue<_ScheduledTask<dynamic>>(),
  };
  final Set<String> _keys = <String>{};
  int _running = 0;
  bool _closed = false;

  Future<T> schedule<T>({
    required String key,
    required String tag,
    required TaskPriority priority,
    required Future<T> Function() action,
  }) {
    if (_closed) return Future<T>.error(StateError('Task scheduler is closed'));
    if (_keys.contains(key)) {
      return Future<T>.error(StateError('Task is already scheduled: $key'));
    }
    final completer = Completer<T>();
    _queues[priority]!.add(
      _ScheduledTask<T>(
        key: key,
        tag: tag,
        action: action,
        completer: completer,
      ),
    );
    _keys.add(key);
    _drain();
    return completer.future;
  }

  void cancelTag(String tag) {
    for (final queue in _queues.values) {
      final retained = Queue<_ScheduledTask<dynamic>>();
      while (queue.isNotEmpty) {
        final task = queue.removeFirst();
        if (task.tag == tag) {
          _keys.remove(task.key);
          task.completer
              .completeError(StateError('Task canceled: ${task.key}'));
        } else {
          retained.add(task);
        }
      }
      queue.addAll(retained);
    }
  }

  void _drain() {
    while (!_closed && _running < maxConcurrent) {
      final task = _nextTask();
      if (task == null) return;
      _running++;
      task.run().whenComplete(() {
        _running--;
        _keys.remove(task.key);
        _drain();
      });
    }
  }

  _ScheduledTask<dynamic>? _nextTask() {
    for (final priority in TaskPriority.values) {
      final queue = _queues[priority]!;
      if (queue.isNotEmpty) return queue.removeFirst();
    }
    return null;
  }

  void close() {
    _closed = true;
    for (final priority in TaskPriority.values) {
      cancelTag(priority.name);
    }
    for (final queue in _queues.values) {
      while (queue.isNotEmpty) {
        final task = queue.removeFirst();
        _keys.remove(task.key);
        task.completer.completeError(StateError('Task scheduler is closed'));
      }
    }
  }
}

class _ScheduledTask<T> {
  _ScheduledTask({
    required this.key,
    required this.tag,
    required this.action,
    required this.completer,
  });

  final String key;
  final String tag;
  final Future<T> Function() action;
  final Completer<T> completer;

  Future<void> run() async {
    try {
      completer.complete(await action());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }
}
