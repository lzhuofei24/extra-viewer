import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/app_diagnostic_log.dart';
import '../domain/models.dart';
import 'media_source_resolver.dart';

typedef AudioProgressSaver = void Function(
    String entityId, int positionMs, int durationMs);
typedef AudioSessionCreator = AudioPlaybackSession Function({
  required List<EntityListItem> entries,
  required int currentIndex,
  String? sourceNodeId,
  String? sourceNodeName,
  required AudioPlaybackMode mode,
});
typedef AudioSessionUpdater = void Function({
  required String id,
  int? currentIndex,
  int? positionMs,
  AudioPlaybackMode? mode,
  List<int>? shuffleRemaining,
  List<int>? history,
  bool? active,
});

class AudioPlaybackProgress {
  const AudioPlaybackProgress(
      {this.position = Duration.zero, this.duration = Duration.zero});
  final Duration position;
  final Duration duration;
}

class AppAudioController extends ChangeNotifier {
  AppAudioController({
    required AudioProgressSaver onProgressSaved,
    required AudioSessionCreator onSessionCreated,
    required AudioSessionUpdater onSessionUpdated,
    MediaSourceResolver sourceResolver = const MediaSourceResolver(),
  })  : _onProgressSaved = onProgressSaved,
        _onSessionCreated = onSessionCreated,
        _onSessionUpdated = onSessionUpdated,
        _sourceResolver = sourceResolver {
    _saveTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => saveProgress());
    AppDiagnosticLog.instance.info('audio_controller_created');
  }

  Player? _player;
  final AudioProgressSaver _onProgressSaved;
  final AudioSessionCreator _onSessionCreated;
  final AudioSessionUpdater _onSessionUpdated;
  final MediaSourceResolver _sourceResolver;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  Timer? _saveTimer;
  AudioPlaybackSession? _session;
  Object? _error;
  bool _opening = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _openedEntityId;
  final Set<int> _shuffleRemaining = <int>{};
  final List<int> _history = <int>[];
  final ValueNotifier<AudioPlaybackProgress> progress =
      ValueNotifier(const AudioPlaybackProgress());

  Player get player => _player!;
  AudioPlaybackSession? get session => _session;
  EntityListItem? get current => _session?.current;
  Object? get error => _error;
  bool get hasCurrent => current != null;
  bool get opening => _opening;
  Duration get position => _position;
  Duration get duration => _duration;
  AudioPlaybackMode get mode => _session?.mode ?? AudioPlaybackMode.sequential;
  List<EntityListItem> get queue =>
      List.unmodifiable(_session?.entries ?? const []);

  Future<void> open(
    EntityListItem entity, {
    Iterable<EntityListItem> contextQueue = const [],
    String? sourceNodeId,
    String? sourceNodeName,
    bool autoplay = true,
  }) async {
    if (entity.entityType != EntityType.audio) return;
    AppDiagnosticLog.instance.info('audio_open_requested', fields: {
      'entityId': entity.id,
      'sourceNodeId': sourceNodeId,
      'autoplay': autoplay,
      'queueSize': contextQueue.length,
    });
    final candidates = contextQueue
        .where((item) => item.entityType == EntityType.audio)
        .toList(growable: false);
    final currentSession = _session;
    final inCurrentSession = currentSession != null &&
        currentSession.entries.any((item) => item.id == entity.id) &&
        (currentSession.current?.id == entity.id ||
            sourceNodeId == null ||
            sourceNodeId == currentSession.sourceNodeId);
    if (!inCurrentSession) {
      final entries =
          candidates.isEmpty ? <EntityListItem>[entity] : candidates;
      _session = _onSessionCreated(
        entries: entries,
        currentIndex: entries
            .indexWhere((item) => item.id == entity.id)
            .clamp(0, entries.length - 1)
            .toInt(),
        sourceNodeId: sourceNodeId,
        sourceNodeName: sourceNodeName,
        mode: AudioPlaybackMode.sequential,
      );
      _resetShuffleBag();
      AppDiagnosticLog.instance.info('audio_session_created', fields: {
        'sessionId': _session!.id,
        'entityId': entity.id,
        'queueSize': entries.length,
        'sourceNodeId': sourceNodeId,
      });
    } else {
      final index =
          currentSession.entries.indexWhere((item) => item.id == entity.id);
      _session = _copySession(currentSession, currentIndex: index);
      _persistSession();
    }
    await _openCurrent(autoplay: autoplay);
  }

  Future<void> restoreSession(AudioPlaybackSession session,
      {bool autoplay = false}) async {
    if (session.entries.isEmpty) return;
    _session = session;
    _shuffleRemaining
      ..clear()
      ..addAll(session.shuffleRemaining);
    _history
      ..clear()
      ..addAll(session.history);
    if (_shuffleRemaining.isEmpty) _resetShuffleBag();
    _onSessionUpdated(id: session.id, active: true);
    await _openCurrent(autoplay: autoplay, seekToSessionPosition: true);
  }

  Future<void> playSessionEntry(AudioPlaybackSession session, int index) async {
    if (index < 0 || index >= session.entries.length) return;
    _session = _copySession(session, currentIndex: index, positionMs: 0);
    _history.add(session.currentIndex);
    _resetShuffleBag();
    _persistSession();
    await _openCurrent(autoplay: true);
  }

  Future<void> _openCurrent(
      {required bool autoplay, bool seekToSessionPosition = false}) async {
    final activeSession = _session;
    final entity = activeSession?.current;
    if (activeSession == null || entity == null) return;
    final player = _ensurePlayer();
    if (_currentMatchesPlayer(entity) && !seekToSessionPosition) {
      if (autoplay && !player.state.playing) await player.play();
      return;
    }
    _error = null;
    _opening = true;
    AppDiagnosticLog.instance.info('audio_player_open_started', fields: {
      'entityId': entity.id,
      'sessionId': activeSession.id,
      'autoplay': autoplay,
      'restorePosition': seekToSessionPosition,
    });
    _setProgress(
        position: Duration.zero,
        duration: Duration(milliseconds: entity.durationMs ?? 0));
    notifyListeners();
    try {
      await player.open(Media(await _sourceResolver.playerSourceAsync(entity)),
          play: autoplay);
      _openedEntityId = entity.id;
      final seekMs = seekToSessionPosition
          ? activeSession.positionMs
          : (entity.lastPositionMs ?? 0);
      if (seekMs > 0) await player.seek(Duration(milliseconds: seekMs));
    } catch (error) {
      _error = error;
      AppDiagnosticLog.instance.error(
        'audio_player_open_failed',
        error,
        StackTrace.current,
        fields: {'entityId': entity.id, 'sessionId': activeSession.id},
      );
    } finally {
      _opening = false;
      if (_error == null) {
        AppDiagnosticLog.instance.info('audio_player_open_finished', fields: {
          'entityId': entity.id,
          'sessionId': activeSession.id,
          'seekPositionMs': seekToSessionPosition
              ? activeSession.positionMs
              : (entity.lastPositionMs ?? 0),
        });
      }
      notifyListeners();
    }
  }

  bool _currentMatchesPlayer(EntityListItem entity) =>
      _openedEntityId == entity.id && _player != null;

  Player _ensurePlayer() {
    if (_player != null) return _player!;
    final created = Player();
    _player = created;
    AppDiagnosticLog.instance.info('audio_player_created');
    _completedSubscription = created.stream.completed.listen((completed) {
      if (completed) {
        AppDiagnosticLog.instance.info('audio_player_completed', fields: {
          'entityId': current?.id,
        });
        next(fromCompletion: true);
      }
    });
    _playingSubscription =
        created.stream.playing.listen((_) => notifyListeners());
    _positionSubscription = created.stream.position
        .listen((position) => _setProgress(position: position));
    _durationSubscription = created.stream.duration
        .listen((duration) => _setProgress(duration: duration));
    _errorSubscription = created.stream.error.listen((message) {
      _error = StateError(message);
      AppDiagnosticLog.instance.warning('audio_player_native_error', fields: {
        'entityId': current?.id,
        'message': message,
      });
      notifyListeners();
    });
    return created;
  }

  Future<void> pause() async {
    if (_player?.state.playing == true) await _player!.pause();
  }

  Future<void> previous() async {
    final session = _session;
    if (session == null) return;
    if (_history.isNotEmpty) {
      final index = _history.removeLast();
      _session = _copySession(session, currentIndex: index, positionMs: 0);
      _persistSession();
      await _openCurrent(autoplay: true);
      return;
    }
    await _move(-1);
  }

  Future<void> next({bool fromCompletion = false}) =>
      _move(1, fromCompletion: fromCompletion);

  Future<void> _move(int delta, {bool fromCompletion = false}) async {
    final session = _session;
    if (session == null || session.entries.isEmpty) return;
    if (fromCompletion && session.mode == AudioPlaybackMode.singleRepeat) {
      await _player?.seek(Duration.zero);
      await _player?.play();
      return;
    }
    var index = session.currentIndex + delta;
    if (session.mode == AudioPlaybackMode.nodeShuffle && delta > 0) {
      _shuffleRemaining.remove(session.currentIndex);
      if (_shuffleRemaining.isEmpty) {
        _resetShuffleBag(excluding: session.currentIndex);
      }
      final choices = _shuffleRemaining.toList(growable: false);
      if (choices.isNotEmpty) {
        index = choices[DateTime.now().microsecond % choices.length];
        _shuffleRemaining.remove(index);
      }
    } else if (index < 0 || index >= session.entries.length) {
      if (session.mode == AudioPlaybackMode.nodeRepeat) {
        index = delta > 0 ? 0 : session.entries.length - 1;
      } else {
        return;
      }
    }
    if (index != session.currentIndex) _history.add(session.currentIndex);
    _session = _copySession(session, currentIndex: index, positionMs: 0);
    _persistSession();
    await _openCurrent(autoplay: true);
  }

  void cycleMode() {
    final session = _session;
    if (session == null) return;
    final next = AudioPlaybackMode
        .values[(session.mode.index + 1) % AudioPlaybackMode.values.length];
    _session = _copySession(session, mode: next);
    if (next == AudioPlaybackMode.nodeShuffle) _resetShuffleBag();
    _persistSession();
    notifyListeners();
  }

  void setMode(AudioPlaybackMode value) {
    final session = _session;
    if (session == null || session.mode == value) return;
    _session = _copySession(session, mode: value);
    if (value == AudioPlaybackMode.nodeShuffle) _resetShuffleBag();
    _persistSession();
    notifyListeners();
  }

  void saveProgress() {
    final entity = current;
    final player = _player;
    final session = _session;
    if (entity == null || player == null || session == null) return;
    final positionMs = player.state.position.inMilliseconds;
    _onProgressSaved(
        entity.id, positionMs, player.state.duration.inMilliseconds);
    _session = _copySession(session, positionMs: positionMs);
    _persistSession();
  }

  void _persistSession() {
    final session = _session;
    if (session == null) return;
    _onSessionUpdated(
        id: session.id,
        currentIndex: session.currentIndex,
        positionMs: session.positionMs,
        mode: session.mode,
        shuffleRemaining: _shuffleRemaining.toList(),
        history: _history,
        active: true);
  }

  void _resetShuffleBag({int? excluding}) {
    final session = _session;
    if (session == null) return;
    _shuffleRemaining
      ..clear()
      ..addAll(List<int>.generate(session.entries.length, (index) => index));
    _shuffleRemaining.remove(excluding ?? session.currentIndex);
  }

  AudioPlaybackSession _copySession(AudioPlaybackSession source,
          {int? currentIndex, int? positionMs, AudioPlaybackMode? mode}) =>
      AudioPlaybackSession(
        id: source.id,
        name: source.name,
        sourceNodeId: source.sourceNodeId,
        sourceNodeName: source.sourceNodeName,
        mode: mode ?? source.mode,
        entries: source.entries,
        currentIndex: currentIndex ?? source.currentIndex,
        positionMs: positionMs ?? source.positionMs,
        shuffleRemaining: _shuffleRemaining.toList(),
        history: _history,
        active: true,
        createdAtMs: source.createdAtMs,
        updatedAtMs: source.updatedAtMs,
      );

  Future<void> stopAndClear() async {
    saveProgress();
    await _player?.stop();
    _session = null;
    _error = null;
    _setProgress(position: Duration.zero, duration: Duration.zero);
    notifyListeners();
  }

  void _setProgress({Duration? position, Duration? duration}) {
    final p = position ?? _position;
    final d = duration ?? _duration;
    if (p == _position && d == _duration) return;
    _position = p;
    _duration = d;
    progress.value = AudioPlaybackProgress(position: p, duration: d);
  }

  @override
  void dispose() {
    AppDiagnosticLog.instance.info('audio_controller_dispose_started', fields: {
      'entityId': current?.id,
      'sessionId': _session?.id,
    });
    saveProgress();
    _saveTimer?.cancel();
    _completedSubscription?.cancel();
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription?.cancel();
    progress.dispose();
    final player = _player;
    if (player != null) {
      unawaited(_disposePlayer(player));
    }
    super.dispose();
  }

  Future<void> _disposePlayer(Player player) async {
    try {
      await player.dispose();
      AppDiagnosticLog.instance.info('audio_player_dispose_finished');
    } catch (error, stackTrace) {
      AppDiagnosticLog.instance
          .error('audio_player_dispose_failed', error, stackTrace);
    }
  }
}
