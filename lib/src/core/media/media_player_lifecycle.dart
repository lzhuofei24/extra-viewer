/// Serializes the logical lifetime of a media player.
///
/// A generation is captured by every asynchronous open operation. Once a
/// newer operation or close begins, callbacks from the older generation are
/// stale and must not mutate UI or playback state.
class MediaPlayerLifecycle {
  int _generation = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  int beginOperation() {
    if (_closing) throw StateError('Media player is closing');
    return ++_generation;
  }

  int invalidate() => ++_generation;

  bool get isClosing => _closing;

  bool isCurrent(int generation) => !_closing && generation == _generation;

  Future<void> close(Future<void> Function() release) {
    return _closeFuture ??= _closeImpl(release);
  }

  Future<void> _closeImpl(Future<void> Function() release) async {
    _closing = true;
    ++_generation;
    await release();
  }
}
