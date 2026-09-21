import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../modules/library/library_access.dart';
import '../../ui/app_preferences.dart';
import '../../ui/glass_notice.dart';
import '../controllers/library_build_task_controller.dart';
import '../diagnostics/app_diagnostic_log.dart';
import '../domain/models.dart';
import 'directory_diff_scanner.dart';

enum AutoSyncStatus {
  disabled,
  scanning,
  awaitingConfirmation,
  queued,
  running,
}

class AutoSyncCoordinator extends ChangeNotifier {
  AutoSyncCoordinator({
    required this.library,
    required this.tasks,
    required this.preferences,
    required this.isClosing,
    this.onRefresh,
  }) : scanner = DirectoryDiffScanner(library) {
    _restore();
    preferences.addListener(_preferencesChanged);
    tasks.addListener(_tasksChanged);
    _configureTimer();
  }

  final LibraryAccess library;
  final LibraryBuildTaskController tasks;
  final AppPreferencesController preferences;
  final bool Function() isClosing;
  final VoidCallback? onRefresh;
  final DirectoryDiffScanner scanner;

  Timer? _timer;
  DirectoryDiffScanResult? _lastScan;
  bool _awaitingConfirmation = false;
  bool _scanning = false;
  bool _phase2Queued = false;
  bool? _hasRoots;
  bool _disposed = false;
  Future<void>? _drain;

  DirectoryDiffScanResult? get lastScan => _lastScan;
  bool get awaitingConfirmation => _awaitingConfirmation;
  bool get isScanning => _scanning;
  bool get phase2Queued => _phase2Queued;
  bool? get hasSyncRoots => _hasRoots;
  AutoSyncStatus get status {
    if (_scanning) return AutoSyncStatus.scanning;
    if (_awaitingConfirmation) return AutoSyncStatus.awaitingConfirmation;
    if (_phase2Queued) {
      return tasks.isRunning ? AutoSyncStatus.running : AutoSyncStatus.queued;
    }
    return AutoSyncStatus.disabled;
  }

  void _restore() {
    final encoded = preferences.value.autoSyncResultJson;
    _lastScan = DirectoryDiffScanResult.fromJson(encoded);
    if (encoded == null) {
      return;
    }
    try {
      _awaitingConfirmation =
          (jsonDecode(encoded) as Map)['awaitingConfirmation'] == true;
    } catch (_) {
      _awaitingConfirmation = false;
    }
  }

  void _preferencesChanged() {
    _configureTimer();
    if (!_disposed) notifyListeners();
  }

  void _tasksChanged() {
    if (_phase2Queued && !tasks.isRunning && _drain == null) {
      _drain = tasks.drainRecoverableQueue().whenComplete(() async {
        _drain = null;
        _phase2Queued = tasks.recoverableJobs.isNotEmpty;
        onRefresh?.call();
        _notify();
      });
      if (!_disposed) notifyListeners();
    }
  }

  void _configureTimer() {
    _timer?.cancel();
    _timer = null;
    if (!preferences.value.autoSyncEnabled || _disposed) return;
    _timer = Timer.periodic(preferences.value.autoSyncInterval.duration, (_) {
      unawaited(maybeScan());
    });
  }

  Future<void> onResumed() async {
    if (preferences.value.autoSyncEnabled) await maybeScan();
  }

  Future<void> maybeScan() async {
    if (_scanning ||
        _awaitingConfirmation ||
        _phase2Queued ||
        tasks.isRunning ||
        isClosing() ||
        !preferences.value.autoSyncEnabled) {
      return;
    }
    final roots = (await library.listIndexRoots())
        .where((root) =>
            root.nodeType == NodeType.directoryIndexRoot &&
            root.sourcePath?.trim().isNotEmpty == true)
        .map((root) => DirectorySyncRoot(
              rootId: root.id,
              name: root.name,
              sourcePath: root.sourcePath!,
            ))
        .toList(growable: false);
    _hasRoots = roots.isNotEmpty;
    if (roots.isEmpty) return;
    _scanning = true;
    _persist(null, awaiting: false);
    _notify();
    try {
      final result = await scanner.scan(roots, onRootComplete: (partial) {
        final current = _lastScan;
        final partialRoots = [
          ...?current?.roots
              .where((item) => item.root.rootId != partial.root.rootId),
          partial,
        ];
        _lastScan = DirectoryDiffScanResult(
          scanStartedAt: current?.scanStartedAt ?? DateTime.now(),
          scanCompletedAt: DateTime.now(),
          roots: partialRoots,
        );
        _notify();
      });
      _lastScan = result;
      _awaitingConfirmation = result.hasChanges;
      _persist(result, awaiting: _awaitingConfirmation);
      if (result.hasChanges) {
        GlassNoticeController.instance.show(
          '发现新增 ${result.addedCount}、更新 ${result.updatedCount}、缺失 ${result.missingCount}，等待确认',
          dedupeKey: 'auto-sync-result',
        );
      }
      if (result.unavailableCount > 0) {
        GlassNoticeController.instance.show(
          '部分目录暂时无法访问，旧索引已保留',
          dedupeKey: 'auto-sync-unavailable',
        );
      }
    } catch (error, stack) {
      AppDiagnosticLog.instance.error('auto_sync_scan_failed', error, stack);
    } finally {
      _scanning = false;
      _notify();
    }
  }

  Future<void> confirmUpdates() async {
    if (!_awaitingConfirmation || _lastScan == null || _phase2Queued) return;
    final roots = _lastScan!.roots
        .where((root) => root.changed > 0 && !root.unavailable)
        .map((root) => root.root)
        .toList(growable: false);
    if (roots.isEmpty) {
      _awaitingConfirmation = false;
      _persist(_lastScan, awaiting: false);
      _notify();
      return;
    }
    try {
      final jobs = await tasks.enqueueDirectoryUpdates(roots);
      _awaitingConfirmation = false;
      _phase2Queued = jobs.isNotEmpty;
      _persist(_lastScan, awaiting: false);
      GlassNoticeController.instance.show(
        tasks.isRunning ? '已有任务正在执行，自动更新已排队' : '已加入更新队列',
        dedupeKey: 'auto-sync-queued',
      );
      _notify();
      if (_phase2Queued && !tasks.isRunning && _drain == null) {
        _drain = tasks.drainRecoverableQueue().whenComplete(() {
          _tasksChanged();
          onRefresh?.call();
        });
        await _drain;
      }
    } catch (error, stack) {
      AppDiagnosticLog.instance.error('auto_sync_enqueue_failed', error, stack);
    }
  }

  void _persist(DirectoryDiffScanResult? result, {required bool awaiting}) {
    if (result == null) return;
    final encoded = jsonEncode(result.toJson(awaitingConfirmation: awaiting));
    preferences.setAutoSyncResultJson(encoded);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    preferences.removeListener(_preferencesChanged);
    tasks.removeListener(_tasksChanged);
    super.dispose();
  }
}
