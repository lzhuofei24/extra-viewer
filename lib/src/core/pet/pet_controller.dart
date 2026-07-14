import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum PetTrigger {
  appStarted('应用启动'),
  indexStarted('索引开始'),
  indexCompleted('索引完成'),
  indexFailed('索引失败'),
  musicStarted('音乐开始'),
  musicPaused('音乐暂停'),
  petTapped('点击宠物');

  const PetTrigger(this.label);
  final String label;
}

class PetActionDefinition {
  const PetActionDefinition({
    required this.id,
    required this.label,
    required this.asset,
    required this.frameDuration,
    required this.loop,
  });

  final String id;
  final String label;
  final String asset;
  final Duration frameDuration;
  final bool loop;
}

class PetVoiceDefinition {
  const PetVoiceDefinition({
    required this.id,
    required this.label,
    required this.asset,
  });

  final String id;
  final String label;
  final String asset;
}

class PetDefinition {
  const PetDefinition({
    required this.id,
    required this.name,
    required this.actions,
    this.frameWidth = 192,
    this.frameHeight = 208,
  });

  final String id;
  final String name;
  final int frameWidth;
  final int frameHeight;
  final List<PetActionDefinition> actions;

  PetActionDefinition actionById(String id) => actions.firstWhere(
        (action) => action.id == id,
        orElse: () => actions.first,
      );
}

class PetRule {
  const PetRule({
    required this.trigger,
    required this.actionId,
    required this.bubbleText,
    required this.priority,
    required this.cooldown,
    this.enabled = true,
    this.interruptible = true,
    this.voiceAsset,
  });

  final PetTrigger trigger;
  final String actionId;
  final String bubbleText;
  final int priority;
  final Duration cooldown;
  final bool enabled;
  final bool interruptible;
  final String? voiceAsset;

  PetRule copyWith({
    String? actionId,
    String? bubbleText,
    int? priority,
    Duration? cooldown,
    bool? enabled,
    bool? interruptible,
    String? voiceAsset,
    bool clearVoice = false,
  }) =>
      PetRule(
        trigger: trigger,
        actionId: actionId ?? this.actionId,
        bubbleText: bubbleText ?? this.bubbleText,
        priority: priority ?? this.priority,
        cooldown: cooldown ?? this.cooldown,
        enabled: enabled ?? this.enabled,
        interruptible: interruptible ?? this.interruptible,
        voiceAsset: clearVoice ? null : voiceAsset ?? this.voiceAsset,
      );
}

class PetPresentation {
  const PetPresentation({
    required this.action,
    this.bubbleText,
    this.voiceAsset,
    this.priority = 0,
  });

  final PetActionDefinition action;
  final String? bubbleText;
  final String? voiceAsset;
  final int priority;
}

class PetVoiceRequest {
  const PetVoiceRequest({required this.token, required this.asset});

  final int token;
  final String asset;
}

/// Owns pet configuration and arbitrates sparse app events. It deliberately
/// has no dependency on scanner progress or the main audio playback session.
class PetController extends ChangeNotifier {
  PetController() {
    _presentation = PetPresentation(action: selectedPet.actions.first);
  }

  static const silverWolf = PetDefinition(
    id: 'silverwolf-v2',
    name: '银狼',
    actions: [
      PetActionDefinition(
        id: 'idle',
        label: '待机',
        asset: 'assets/pets/silverwolf_v2/idle.webp',
        frameDuration: Duration(milliseconds: 180),
        loop: true,
      ),
      PetActionDefinition(
        id: 'working',
        label: '工作',
        asset: 'assets/pets/silverwolf_v2/working.webp',
        frameDuration: Duration(milliseconds: 150),
        loop: true,
      ),
      PetActionDefinition(
        id: 'complete',
        label: '完成',
        asset: 'assets/pets/silverwolf_v2/complete.webp',
        frameDuration: Duration(milliseconds: 140),
        loop: false,
      ),
      PetActionDefinition(
        id: 'error',
        label: '失败',
        asset: 'assets/pets/silverwolf_v2/error.webp',
        frameDuration: Duration(milliseconds: 140),
        loop: false,
      ),
      PetActionDefinition(
        id: 'waiting',
        label: '等待',
        asset: 'assets/pets/silverwolf_v2/waiting.webp',
        frameDuration: Duration(milliseconds: 150),
        loop: true,
      ),
      PetActionDefinition(
        id: 'jump',
        label: '跳跃',
        asset: 'assets/pets/silverwolf_v2/jump.webp',
        frameDuration: Duration(milliseconds: 140),
        loop: false,
      ),
    ],
  );

  final List<PetDefinition> pets = const [silverWolf];
  static const _voiceRoot = 'assets/pets/silverwolf_v2/voices/';
  final List<PetVoiceDefinition> voices = const [
    PetVoiceDefinition(
        id: 'app_started_original',
        label: '原声 · 今天也上线了。',
        asset: '${_voiceRoot}app_started_original.opus'),
    PetVoiceDefinition(
        id: 'index_started_original',
        label: '原声 · 嘘，等会儿，我在忙。',
        asset: '${_voiceRoot}index_started_original.opus'),
    PetVoiceDefinition(
        id: 'index_completed_tts',
        label: 'TTS · 索引完成，新的资料已经入库。',
        asset: '${_voiceRoot}index_completed_tts.opus'),
    PetVoiceDefinition(
        id: 'index_completed_original',
        label: '原声 · 骇入成功，状态回满。',
        asset: '${_voiceRoot}index_completed_original.opus'),
    PetVoiceDefinition(
        id: 'index_completed_alt',
        label: '原声 · 委托完成。',
        asset: '${_voiceRoot}index_completed_alt.opus'),
    PetVoiceDefinition(
        id: 'index_failed_tts',
        label: 'TTS · 构建失败了，把日志给我看看。',
        asset: '${_voiceRoot}index_failed_tts.opus'),
    PetVoiceDefinition(
        id: 'index_failed_original',
        label: '原声 · 有漏洞。',
        asset: '${_voiceRoot}index_failed_original.opus'),
    PetVoiceDefinition(
        id: 'index_failed_alt',
        label: '原声 · 切，真无聊。',
        asset: '${_voiceRoot}index_failed_alt.opus'),
    PetVoiceDefinition(
        id: 'pet_tap_tts',
        label: 'TTS · 什么事？',
        asset: '${_voiceRoot}pet_tap_tts.opus'),
    PetVoiceDefinition(
        id: 'pet_tap_original',
        label: '原声 · 来，试试。',
        asset: '${_voiceRoot}pet_tap_original.opus'),
    PetVoiceDefinition(
        id: 'pet_tap_alt',
        label: '原声 · 有挑战，我喜欢。',
        asset: '${_voiceRoot}pet_tap_alt.opus'),
    PetVoiceDefinition(
        id: 'music_started_original',
        label: '原声 · 银河战力党真好玩，今天继续。',
        asset: '${_voiceRoot}music_started_original.opus'),
    PetVoiceDefinition(
        id: 'music_paused',
        label: 'TTS · 暂停？那我先挂会儿。',
        asset: '${_voiceRoot}music_paused.opus'),
    PetVoiceDefinition(
        id: 'index_paused',
        label: 'TTS · 先暂停一下，进度已经存好了。',
        asset: '${_voiceRoot}index_paused.opus'),
    PetVoiceDefinition(
        id: 'index_resume',
        label: 'TTS · 继续，别掉线。',
        asset: '${_voiceRoot}index_resume.opus'),
    PetVoiceDefinition(
        id: 'index_updated',
        label: 'TTS · 更新完成，没漏文件。',
        asset: '${_voiceRoot}index_updated.opus'),
    PetVoiceDefinition(
        id: 'idle_check',
        label: 'TTS · 还在吗？',
        asset: '${_voiceRoot}idle_check.opus'),
    PetVoiceDefinition(
        id: 'waiting_original',
        label: '原声 · 哼。',
        asset: '${_voiceRoot}waiting_original.opus'),
  ];
  final Map<PetTrigger, DateTime> _lastTriggeredAt = {};
  final Set<String> _enabledActionIds = {
    'idle',
    'working',
    'complete',
    'error',
    'waiting',
    'jump',
  };
  late PetPresentation _presentation;
  Timer? _restoreTimer;
  Timer? _persistTimer;
  String _selectedPetId = silverWolf.id;
  bool _visible = true;
  bool _reducedMotion = false;
  bool _muted = true;
  bool _ignorePointer = false;
  double _scale = 1;
  double? _positionXRatio;
  double? _positionYRatio;
  List<PetRule> _rules = _defaultRules();
  int _voiceRequestToken = 0;
  PetVoiceRequest? _voiceRequest;

  bool get visible => _visible;
  bool get reducedMotion => _reducedMotion;
  bool get muted => _muted;
  bool get ignorePointer => _ignorePointer;
  double get scale => _scale;
  ({double x, double y})? get positionRatio =>
      _positionXRatio == null || _positionYRatio == null
          ? null
          : (x: _positionXRatio!, y: _positionYRatio!);
  PetDefinition get selectedPet => pets.firstWhere(
        (pet) => pet.id == _selectedPetId,
        orElse: () => pets.first,
      );
  List<PetRule> get rules => List.unmodifiable(_rules);
  Set<String> get enabledActionIds => Set.unmodifiable(_enabledActionIds);
  PetPresentation get presentation => _presentation;
  PetVoiceRequest? get voiceRequest => _voiceRequest;

  Future<void> restore() async {
    try {
      final file = await _preferencesFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      final selected = raw['selectedPetId'] as String?;
      if (selected != null && pets.any((pet) => pet.id == selected)) {
        _selectedPetId = selected;
      }
      _visible = raw['visible'] as bool? ?? _visible;
      _muted = raw['muted'] as bool? ?? _muted;
      _ignorePointer = raw['ignorePointer'] as bool? ?? _ignorePointer;
      _reducedMotion = raw['reducedMotion'] as bool? ?? _reducedMotion;
      _scale = ((raw['scale'] as num?)?.toDouble() ?? _scale)
          .clamp(0.7, 1.35)
          .toDouble();
      final position = raw['position'];
      if (position is Map<String, dynamic>) {
        _positionXRatio =
            (position['x'] as num?)?.toDouble().clamp(0.0, 1.0).toDouble();
        _positionYRatio =
            (position['y'] as num?)?.toDouble().clamp(0.0, 1.0).toDouble();
      }
      final enabled = raw['enabledActions'];
      if (enabled is List) {
        _enabledActionIds
          ..clear()
          ..addAll(enabled.whereType<String>());
        _enabledActionIds.add('idle');
      }
      final savedRules = raw['rules'];
      if (savedRules is List) {
        final byTrigger = <PetTrigger, PetRule>{
          for (final item in savedRules)
            if (item is Map)
              if (Map<String, dynamic>.from(item) case final saved)
                if (_ruleFromJson(saved) case final rule?)
                  rule.trigger: saved.containsKey('voiceAsset')
                      ? rule
                      : rule.copyWith(
                          voiceAsset: _defaultRules()
                              .firstWhere(
                                (defaultRule) =>
                                    defaultRule.trigger == rule.trigger,
                              )
                              .voiceAsset,
                        ),
        };
        _rules = [
          for (final rule in _rules) byTrigger[rule.trigger] ?? rule,
        ];
      }
      _restoreIdle();
    } catch (_) {
      // Invalid preferences never prevent the library from opening.
    }
  }

  void selectPet(String id) {
    if (!pets.any((pet) => pet.id == id) || id == _selectedPetId) return;
    _selectedPetId = id;
    _restoreIdle();
    _schedulePersist();
  }

  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _schedulePersist();
    notifyListeners();
  }

  void setMuted(bool value) {
    _muted = value;
    _schedulePersist();
    notifyListeners();
  }

  void setIgnorePointer(bool value) {
    _ignorePointer = value;
    _schedulePersist();
    notifyListeners();
  }

  void setReducedMotion(bool value) {
    _reducedMotion = value;
    _schedulePersist();
    notifyListeners();
  }

  void setScale(double value) {
    _scale = value.clamp(0.7, 1.35).toDouble();
    _schedulePersist();
    notifyListeners();
  }

  void setPositionRatio({double? x, double? y}) {
    _positionXRatio = x?.clamp(0.0, 1.0).toDouble();
    _positionYRatio = y?.clamp(0.0, 1.0).toDouble();
    _schedulePersist();
  }

  void resetPosition() => setPositionRatio();

  void setActionEnabled(String actionId, bool enabled) {
    if (enabled) {
      _enabledActionIds.add(actionId);
    } else if (actionId != 'idle') {
      _enabledActionIds.remove(actionId);
    }
    if (!_enabledActionIds.contains(_presentation.action.id)) _restoreIdle();
    _schedulePersist();
    notifyListeners();
  }

  void updateRule(PetRule rule) {
    _rules = [
      for (final current in _rules)
        if (current.trigger == rule.trigger) rule else current,
    ];
    _schedulePersist();
    notifyListeners();
  }

  void trigger(PetTrigger trigger, {bool force = false}) {
    final rule = _rules.where((rule) => rule.trigger == trigger).firstOrNull;
    if (rule == null ||
        !rule.enabled ||
        !_enabledActionIds.contains(rule.actionId)) {
      return;
    }
    final now = DateTime.now();
    final last = _lastTriggeredAt[trigger];
    if (!force && last != null && now.difference(last) < rule.cooldown) return;
    final activeRule = _rules
        .where((item) => item.actionId == _presentation.action.id)
        .firstOrNull;
    if (!force &&
        activeRule != null &&
        !activeRule.interruptible &&
        _presentation.priority > rule.priority) {
      return;
    }
    _lastTriggeredAt[trigger] = now;
    final action = selectedPet.actionById(rule.actionId);
    _restoreTimer?.cancel();
    _presentation = PetPresentation(
      action: action,
      bubbleText: rule.bubbleText.isEmpty ? null : rule.bubbleText,
      voiceAsset: _muted ? null : rule.voiceAsset,
      priority: rule.priority,
    );
    if (_presentation.voiceAsset case final asset?) {
      _voiceRequest =
          PetVoiceRequest(token: ++_voiceRequestToken, asset: asset);
    }
    if (!action.loop) {
      final duration = action.frameDuration * _estimatedFrameCount(action.id);
      _restoreTimer =
          Timer(duration + const Duration(seconds: 2), _restoreIdle);
    }
    notifyListeners();
  }

  void previewAction(String actionId) {
    final action = selectedPet.actionById(actionId);
    _restoreTimer?.cancel();
    _presentation = PetPresentation(action: action, bubbleText: action.label);
    if (!action.loop) {
      _restoreTimer = Timer(
        action.frameDuration * _estimatedFrameCount(action.id),
        _restoreIdle,
      );
    }
    notifyListeners();
  }

  void previewVoice(String asset) {
    if (_muted) return;
    _voiceRequest = PetVoiceRequest(token: ++_voiceRequestToken, asset: asset);
    notifyListeners();
  }

  void clearBubble() {
    if (_presentation.bubbleText == null) return;
    _presentation = PetPresentation(
      action: _presentation.action,
      priority: _presentation.priority,
    );
    notifyListeners();
  }

  void _restoreIdle() {
    _restoreTimer?.cancel();
    _presentation = PetPresentation(action: selectedPet.actionById('idle'));
    notifyListeners();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final file = await _preferencesFile();
        await file.writeAsString(jsonEncode({
          'selectedPetId': _selectedPetId,
          'visible': _visible,
          'muted': _muted,
          'ignorePointer': _ignorePointer,
          'reducedMotion': _reducedMotion,
          'scale': _scale,
          if (_positionXRatio != null && _positionYRatio != null)
            'position': {'x': _positionXRatio, 'y': _positionYRatio},
          'enabledActions': _enabledActionIds.toList()..sort(),
          'rules': [for (final rule in _rules) _ruleToJson(rule)],
        }));
      } catch (_) {
        // Preferences are optional and must not affect browsing behavior.
      }
    });
  }

  Future<File> _preferencesFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File(
        '${directory.path}${Platform.pathSeparator}pet_preferences.json');
  }

  static Map<String, Object?> _ruleToJson(PetRule rule) => {
        'trigger': rule.trigger.name,
        'actionId': rule.actionId,
        'bubbleText': rule.bubbleText,
        'priority': rule.priority,
        'cooldownMs': rule.cooldown.inMilliseconds,
        'enabled': rule.enabled,
        'interruptible': rule.interruptible,
        'voiceAsset': rule.voiceAsset,
      };

  static PetRule? _ruleFromJson(Map<String, dynamic> value) {
    final triggerName = value['trigger'] as String?;
    final trigger = PetTrigger.values
        .where((candidate) => candidate.name == triggerName)
        .firstOrNull;
    final actionId = value['actionId'] as String?;
    if (trigger == null || actionId == null) return null;
    return PetRule(
      trigger: trigger,
      actionId: actionId,
      bubbleText: value['bubbleText'] as String? ?? '',
      priority: (value['priority'] as num?)?.toInt() ?? 0,
      cooldown: Duration(
        milliseconds: (value['cooldownMs'] as num?)?.toInt() ?? 0,
      ),
      enabled: value['enabled'] as bool? ?? true,
      interruptible: value['interruptible'] as bool? ?? true,
      voiceAsset: value['voiceAsset'] as String?,
    );
  }

  int _estimatedFrameCount(String actionId) => switch (actionId) {
        'complete' => 4,
        'jump' => 5,
        'error' => 8,
        _ => 6,
      };

  @override
  void dispose() {
    _restoreTimer?.cancel();
    _persistTimer?.cancel();
    super.dispose();
  }

  static List<PetRule> _defaultRules() => const [
        PetRule(
            trigger: PetTrigger.appStarted,
            actionId: 'jump',
            bubbleText: '今天也上线了。',
            voiceAsset: '${_voiceRoot}app_started_original.opus',
            priority: 60,
            cooldown: Duration(minutes: 1)),
        PetRule(
            trigger: PetTrigger.indexStarted,
            actionId: 'working',
            bubbleText: '开始整理资料。',
            voiceAsset: '${_voiceRoot}index_started_original.opus',
            priority: 30,
            cooldown: Duration(seconds: 5)),
        PetRule(
            trigger: PetTrigger.indexCompleted,
            actionId: 'complete',
            bubbleText: '索引完成，新的资料已经入库。',
            voiceAsset: '${_voiceRoot}index_completed_tts.opus',
            priority: 70,
            cooldown: Duration(seconds: 10),
            interruptible: false),
        PetRule(
            trigger: PetTrigger.indexFailed,
            actionId: 'error',
            bubbleText: '构建失败了，把日志给我看看。',
            voiceAsset: '${_voiceRoot}index_failed_tts.opus',
            priority: 100,
            cooldown: Duration(seconds: 10),
            interruptible: false),
        PetRule(
            trigger: PetTrigger.musicStarted,
            actionId: 'idle',
            bubbleText: '',
            voiceAsset: '${_voiceRoot}music_started_original.opus',
            priority: 10,
            cooldown: Duration(seconds: 20)),
        PetRule(
            trigger: PetTrigger.musicPaused,
            actionId: 'waiting',
            bubbleText: '暂停？那我先挂会儿。',
            voiceAsset: '${_voiceRoot}music_paused.opus',
            priority: 10,
            cooldown: Duration(seconds: 20)),
        PetRule(
            trigger: PetTrigger.petTapped,
            actionId: 'jump',
            bubbleText: '什么事？',
            voiceAsset: '${_voiceRoot}pet_tap_tts.opus',
            priority: 80,
            cooldown: Duration(seconds: 3),
            interruptible: false),
      ];
}
