import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'design_tokens.dart';
import 'gallery_layout_settings.dart';

enum AutoSyncInterval {
  fiveSeconds,
  thirtyMinutes,
  daily;

  Duration get duration => switch (this) {
        AutoSyncInterval.fiveSeconds => const Duration(seconds: 5),
        AutoSyncInterval.thirtyMinutes => const Duration(minutes: 30),
        AutoSyncInterval.daily => const Duration(days: 1),
      };
}

@immutable
class AppPreferencesData {
  const AppPreferencesData({
    this.themeChoice = ViewerThemeChoice.system,
    this.sortMode = EntitySortMode.nameAsc,
    this.displayMode = BrowserDisplayMode.grid,
    this.gridLayout = BrowserGridLayout.equalHeight,
    this.folderCoverStyle = FolderCoverStyle.automatic,
    this.listStyle = BrowserListStyle.normal,
    this.layout = const GalleryLayoutSettings(),
    this.autoSyncEnabled = false,
    this.autoSyncInterval = AutoSyncInterval.thirtyMinutes,
    this.autoSyncResultJson,
  });

  final ViewerThemeChoice themeChoice;
  final EntitySortMode sortMode;
  final BrowserDisplayMode displayMode;
  final BrowserGridLayout gridLayout;
  final FolderCoverStyle folderCoverStyle;
  final BrowserListStyle listStyle;
  final GalleryLayoutSettings layout;
  final bool autoSyncEnabled;
  final AutoSyncInterval autoSyncInterval;
  final String? autoSyncResultJson;

  AppPreferencesData copyWith({
    ViewerThemeChoice? themeChoice,
    EntitySortMode? sortMode,
    BrowserDisplayMode? displayMode,
    BrowserGridLayout? gridLayout,
    BrowserListStyle? listStyle,
    FolderCoverStyle? folderCoverStyle,
    GalleryLayoutSettings? layout,
    bool? autoSyncEnabled,
    AutoSyncInterval? autoSyncInterval,
    String? autoSyncResultJson,
    bool clearAutoSyncResult = false,
  }) =>
      AppPreferencesData(
        themeChoice: themeChoice ?? this.themeChoice,
        sortMode: sortMode ?? this.sortMode,
        displayMode: displayMode ?? this.displayMode,
        gridLayout: gridLayout ?? this.gridLayout,
        folderCoverStyle: folderCoverStyle ?? this.folderCoverStyle,
        listStyle: listStyle ?? this.listStyle,
        layout: layout ?? this.layout,
        autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
        autoSyncInterval: autoSyncInterval ?? this.autoSyncInterval,
        autoSyncResultJson: clearAutoSyncResult
            ? null
            : autoSyncResultJson ?? this.autoSyncResultJson,
      );
}

abstract interface class AppPreferencesStore {
  Future<AppPreferencesData> load();
  Future<void> save(AppPreferencesData value);
}

class SharedPreferencesAppPreferencesStore implements AppPreferencesStore {
  SharedPreferencesAppPreferencesStore(this._preferences);

  static Future<SharedPreferencesAppPreferencesStore> create() async =>
      SharedPreferencesAppPreferencesStore(
          await SharedPreferences.getInstance());

  final SharedPreferences _preferences;

  static const _themeKey = 'preferences.theme';
  static const _sortKey = 'preferences.browser.sort';
  static const _displayKey = 'preferences.browser.display';
  static const _layoutKey = 'preferences.browser.layout';
  static const _folderCoverKey = 'preferences.browser.folderCover';
  static const _listStyleKey = 'preferences.browser.listStyle';
  static const _galleryLayoutKey = 'preferences.gallery.counts.v1';
  static const _autoSyncEnabledKey = 'preferences.autoSync.enabled';
  static const _autoSyncIntervalKey = 'preferences.autoSync.interval';
  static const _autoSyncResultKey = 'preferences.autoSync.result.v1';

  GalleryLayoutSettings _loadLayout() {
    try {
      final raw = jsonDecode(_preferences.getString(_galleryLayoutKey) ?? '{}');
      final values = raw is Map<String, dynamic>
          ? Map<String, Object?>.of(raw)
          : <String, Object?>{};
      if (!values.containsKey('portraitFolderDisplay')) {
        final cover = _preferences.getString(_folderCoverKey);
        final list = _preferences.getString(_displayKey) == 'list';
        for (final portrait in [true, false]) {
          final display = list
              ? FolderDisplay.list
              : cover == 'square'
                  ? FolderDisplay.square
                  : cover == 'stacked'
                      ? FolderDisplay.stacked
                      : portrait
                          ? FolderDisplay.square
                          : FolderDisplay.stacked;
          values['${portrait ? 'portrait' : 'landscape'}FolderDisplay'] =
              display.index;
        }
      }
      return GalleryLayoutSettings.fromMap(values);
    } catch (_) {
      return const GalleryLayoutSettings();
    }
  }

  @override
  Future<AppPreferencesData> load() async => AppPreferencesData(
        themeChoice: _enumValue(
          ViewerThemeChoice.values,
          _preferences.getString(_themeKey),
          ViewerThemeChoice.system,
        ),
        sortMode: _enumValue(
          EntitySortMode.values,
          _preferences.getString(_sortKey),
          EntitySortMode.nameAsc,
        ),
        displayMode: _enumValue(
          BrowserDisplayMode.values,
          _preferences.getString(_displayKey),
          BrowserDisplayMode.grid,
        ),
        gridLayout: _enumValue(
          BrowserGridLayout.values,
          _preferences.getString(_layoutKey),
          BrowserGridLayout.equalHeight,
        ),
        folderCoverStyle: _enumValue(
            FolderCoverStyle.values,
            _preferences.getString(_folderCoverKey),
            FolderCoverStyle.automatic),
        listStyle: _preferences.getString(_listStyleKey) == 'text'
            ? BrowserListStyle.text
            : BrowserListStyle.normal,
        layout: _loadLayout(),
        autoSyncEnabled: _preferences.getBool(_autoSyncEnabledKey) ?? false,
        autoSyncInterval: _enumValue(
          AutoSyncInterval.values,
          _preferences.getString(_autoSyncIntervalKey),
          AutoSyncInterval.thirtyMinutes,
        ),
        autoSyncResultJson: _preferences.getString(_autoSyncResultKey),
      );

  @override
  Future<void> save(AppPreferencesData value) async {
    await Future.wait([
      _preferences.setString(_themeKey, value.themeChoice.name),
      _preferences.setString(_sortKey, value.sortMode.name),
      _preferences.setString(_displayKey, value.displayMode.name),
      _preferences.setString(_layoutKey, value.gridLayout.name),
      _preferences.setString(_folderCoverKey, value.folderCoverStyle.name),
      _preferences.setString(_listStyleKey, value.listStyle.name),
      _preferences.setString(
          _galleryLayoutKey, jsonEncode(value.layout.normalized().toMap())),
      _preferences.setBool(_autoSyncEnabledKey, value.autoSyncEnabled),
      _preferences.setString(_autoSyncIntervalKey, value.autoSyncInterval.name),
      if (value.autoSyncResultJson == null)
        _preferences.remove(_autoSyncResultKey)
      else
        _preferences.setString(_autoSyncResultKey, value.autoSyncResultJson!),
    ]);
  }
}

class MemoryAppPreferencesStore implements AppPreferencesStore {
  MemoryAppPreferencesStore([this.value = const AppPreferencesData()]);

  AppPreferencesData value;

  @override
  Future<AppPreferencesData> load() async => value;

  @override
  Future<void> save(AppPreferencesData value) async => this.value = value;
}

class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController._(this._store, this._value);

  factory AppPreferencesController.memory([AppPreferencesData? value]) =>
      AppPreferencesController._(
        MemoryAppPreferencesStore(value ?? const AppPreferencesData()),
        value ?? const AppPreferencesData(),
      );

  static Future<AppPreferencesController> load(
          AppPreferencesStore store) async =>
      AppPreferencesController._(store, await store.load());

  final AppPreferencesStore _store;
  AppPreferencesData _value;
  Future<void> _pendingWrite = Future<void>.value();

  AppPreferencesData get value => _value;

  void setTheme(ViewerThemeChoice value) =>
      _update(_value.copyWith(themeChoice: value));

  void setBrowser({
    EntitySortMode? sortMode,
    BrowserDisplayMode? displayMode,
    BrowserGridLayout? gridLayout,
    BrowserListStyle? listStyle,
    FolderCoverStyle? folderCoverStyle,
  }) =>
      _update(_value.copyWith(
        sortMode: sortMode,
        displayMode: displayMode,
        gridLayout: gridLayout,
        listStyle: listStyle,
        folderCoverStyle: folderCoverStyle,
      ));

  void setLayout(GalleryLayoutSettings value) =>
      _update(_value.copyWith(layout: value.normalized()));

  void setAutoSyncEnabled(bool enabled) =>
      _update(_value.copyWith(autoSyncEnabled: enabled));

  void setAutoSyncInterval(AutoSyncInterval interval) =>
      _update(_value.copyWith(autoSyncInterval: interval));

  void setAutoSyncResultJson(String? result) => _update(
        result == null
            ? _value.copyWith(clearAutoSyncResult: true)
            : _value.copyWith(autoSyncResultJson: result),
      );

  Future<void> flush() => _pendingWrite;

  void _update(AppPreferencesData value) {
    _value = value;
    notifyListeners();
    final snapshot = value;
    _pendingWrite = _pendingWrite
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Preference write failed: $error\n$stackTrace');
        })
        .then((_) => _store.save(snapshot))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Preference write failed: $error\n$stackTrace');
        });
  }
}

T _enumValue<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
