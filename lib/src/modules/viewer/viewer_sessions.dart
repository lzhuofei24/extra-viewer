import 'dart:async';

/// Tracks live and already-closing viewer resources until cleanup completes.
class ViewerSessions {
  final _sessions = <ViewerSession>{};
  bool _stopped = false;
  Future<void>? _closing;

  bool get isStopped => _stopped;
  void stop() => _stopped = true;

  ViewerSession register(Future<void> Function() release) {
    if (_stopped) throw StateError('Viewer sessions are stopping');
    final session = ViewerSession._(release, _sessions.remove);
    _sessions.add(session);
    return session;
  }

  Future<void> close() {
    stop();
    return _closing ??= Future.wait(
      _sessions.toList().map((session) => session.close()),
      eagerError: false,
    ).then((_) {});
  }
}

class ViewerSession {
  ViewerSession._(this._release, this._remove);
  final Future<void> Function() _release;
  final void Function(ViewerSession) _remove;
  Future<void>? _closing;

  Future<void> close() => _closing ??=
      Future<void>.sync(_release).whenComplete(() => _remove(this));
}
