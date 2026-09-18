import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/domain/models.dart';
import 'browser_state.dart';
import 'design_tokens.dart';
import 'gallery_layout_settings.dart';

@immutable
class AppPreferencesData {
  const AppPreferencesData({
    this.themeChoice = ViewerThemeChoice.system,
    this.sortMode = EntitySortMode.nameAsc,
    this.displayMode = BrowserDisplayMode.grid,
    this.gridLayout = BrowserGridLayout.equalHeight,
    this.layout = const GalleryLayoutSettings(),
  });

  final ViewerThemeChoice themeChoice;
  final EntitySortMode sortMode;
  final BrowserDisplayMode displayMode;
  final BrowserGridLayout gridLayout;
  final GalleryLayoutSettings layout;

  AppPreferencesData copyWith({
    ViewerThemeChoice? themeChoice,
    EntitySortMode? sortMode,
    BrowserDisplayMode? displayMode,
    BrowserGridLayout? gridLayout,
    GalleryLayoutSettings? layout,
  }) =>
      AppPreferencesData(
        themeChoice: themeChoice ?? this.themeChoice,
        sortMode: sortMode ?? this.sortMode,
        displayMode: displayMode ?? this.displayMode,
        gridLayout: gridLayout ?? this.gridLayout,
        layout: layout ?? this.layout,
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
  static const _pageMarginKey = 'preferences.gallery.page_margin';
  static const _cardGapKey = 'preferences.gallery.card_gap';
  static const _cardRadiusKey = 'preferences.gallery.card_radius';
  static const _equalWidthKey = 'preferences.gallery.equal_width';
  static const _equalHeightKey = 'preferences.gallery.equal_height';
  static const _squareSizeKey = 'preferences.gallery.square_size';
  static const _folderHeightKey = 'preferences.gallery.folder_height';

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
        layout: GalleryLayoutSettings(
          pageMargin:
              _number(_pageMarginKey, GalleryLayoutSettings.defaultPageMargin),
          cardGap: _number(_cardGapKey, GalleryLayoutSettings.defaultCardGap),
          cardRadius:
              _number(_cardRadiusKey, GalleryLayoutSettings.defaultCardRadius),
          equalWidthTarget: _number(
              _equalWidthKey, GalleryLayoutSettings.defaultEqualWidthTarget),
          equalHeightTarget: _number(
              _equalHeightKey, GalleryLayoutSettings.defaultEqualHeightTarget),
          squareSize:
              _number(_squareSizeKey, GalleryLayoutSettings.defaultSquareSize),
          folderHeight: _number(
              _folderHeightKey, GalleryLayoutSettings.defaultFolderHeight),
        ).normalized(),
      );

  double _number(String key, double fallback) {
    final value = _preferences.getDouble(key);
    return value == null || !value.isFinite ? fallback : value;
  }

  @override
  Future<void> save(AppPreferencesData value) async {
    final layout = value.layout.normalized();
    await Future.wait([
      _preferences.setString(_themeKey, value.themeChoice.name),
      _preferences.setString(_sortKey, value.sortMode.name),
      _preferences.setString(_displayKey, value.displayMode.name),
      _preferences.setString(_layoutKey, value.gridLayout.name),
      _preferences.setDouble(_pageMarginKey, layout.pageMargin),
      _preferences.setDouble(_cardGapKey, layout.cardGap),
      _preferences.setDouble(_cardRadiusKey, layout.cardRadius),
      _preferences.setDouble(_equalWidthKey, layout.equalWidthTarget),
      _preferences.setDouble(_equalHeightKey, layout.equalHeightTarget),
      _preferences.setDouble(_squareSizeKey, layout.squareSize),
      _preferences.setDouble(_folderHeightKey, layout.folderHeight),
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
  }) =>
      _update(_value.copyWith(
        sortMode: sortMode,
        displayMode: displayMode,
        gridLayout: gridLayout,
      ));

  void setLayout(GalleryLayoutSettings value) =>
      _update(_value.copyWith(layout: value.normalized()));

  void resetLayout() => setLayout(const GalleryLayoutSettings());

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
