import 'dart:async';

enum RuntimeClosePhase {
  stopWork,
  saveState,
  media,
  caches,
  database,
  diagnostics
}

class RuntimeCloseFailure {
  const RuntimeCloseFailure(this.name, this.error, this.stackTrace);
  final String name;
  final Object error;
  final StackTrace stackTrace;
}

/// Orders service shutdown independently of widget disposal. A failing service
/// must not prevent unrelated resources from releasing their native handles.
class AppRuntime {
  AppRuntime({this.onFailure});
  final void Function(RuntimeCloseFailure failure)? onFailure;
  final _steps = <({
    String name,
    RuntimeClosePhase phase,
    FutureOr<void> Function() close
  })>[];
  Future<List<RuntimeCloseFailure>>? _closing;
  bool get isClosing => _closing != null;

  void register(
      String name, RuntimeClosePhase phase, FutureOr<void> Function() close) {
    if (isClosing) throw StateError('Runtime is closing');
    if (_steps.any((step) => step.name == name)) {
      throw StateError('Duplicate runtime service: $name');
    }
    _steps.add((name: name, phase: phase, close: close));
  }

  Future<List<RuntimeCloseFailure>> close() {
    if (_closing != null) return _closing!;
    final completion = Completer<List<RuntimeCloseFailure>>();
    _closing = completion.future;
    unawaited(
        _close().then(completion.complete, onError: completion.completeError));
    return completion.future;
  }

  Future<List<RuntimeCloseFailure>> _close() async {
    final failures = <RuntimeCloseFailure>[];
    for (final phase in RuntimeClosePhase.values) {
      for (final step in _steps.where((step) => step.phase == phase)) {
        try {
          await step.close();
        } catch (error, stack) {
          final failure = RuntimeCloseFailure(step.name, error, stack);
          failures.add(failure);
          try {
            onFailure?.call(failure);
          } catch (reportError, reportStack) {
            failures.add(RuntimeCloseFailure(
                'failure-reporter', reportError, reportStack));
          }
        }
      }
    }
    _steps.clear();
    return List.unmodifiable(failures);
  }
}
