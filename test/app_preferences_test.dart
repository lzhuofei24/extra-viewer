import 'dart:convert';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('browser choices and independent layout counts survive restart',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesAppPreferencesStore(prefs);
    final initial = await store.load();
    expect(initial.layout, const GalleryLayoutSettings());
    final layout = initial.layout.copyWith(
        portraitEqualWidthColumns: 7,
        landscapeEqualWidthColumns: 5,
        portraitSquareColumns: 2,
        landscapeSquareColumns: 6,
        portraitEqualHeightLevel: 4,
        landscapeEqualHeightLevel: 3,
        portraitFolders: const FolderViewSettings(squareColumns: 2),
        landscapeFolders: FolderViewSettings.landscape.copyWith(columns: 5),
        landscapeListColumns: 2);
    await store.save(initial.copyWith(
        layout: layout,
        themeChoice: ViewerThemeChoice.galleryDark,
        sortMode: EntitySortMode.sizeDesc,
        displayMode: BrowserDisplayMode.list,
        gridLayout: BrowserGridLayout.square,
        listStyle: BrowserListStyle.normal,
        folderCoverStyle: FolderCoverStyle.stacked));
    final restored = await SharedPreferencesAppPreferencesStore(prefs).load();
    expect(restored.layout, layout);
    expect(restored.themeChoice, ViewerThemeChoice.galleryDark);
    expect(restored.sortMode, EntitySortMode.sizeDesc);
    expect(restored.listStyle, BrowserListStyle.normal);
    expect(restored.folderCoverStyle, FolderCoverStyle.stacked);
    expect(restored.gridLayout, BrowserGridLayout.square);
  });

  test('old presets are ignored and invalid counts clamp or fall back',
      () async {
    SharedPreferences.setMockInitialValues({
      'preferences.gallery.preset': 'compact',
      'preferences.browser.layout': 'adaptive',
      'preferences.gallery.counts.v1': jsonEncode({
        'portraitEqualWidthColumns': 0,
        'landscapeSquareColumns': 99,
        'portraitEqualHeightLevel': 'bad',
        'landscapeListColumns': 9,
      }),
    });
    final value = await SharedPreferencesAppPreferencesStore(
            await SharedPreferences.getInstance())
        .load();
    expect(value.gridLayout, BrowserGridLayout.equalHeight);
    expect(value.layout.portraitEqualWidthColumns, 1);
    expect(value.layout.landscapeSquareColumns, 8);
    expect(value.layout.portraitEqualHeightLevel, 6);
    expect(value.layout.landscapeListColumns, 4);
    expect(value.layout.cardGap, 8);
  });

  test('corrupt layout preferences recover without losing theme', () async {
    SharedPreferences.setMockInitialValues({
      'preferences.theme': 'galleryDark',
      'preferences.gallery.counts.v1': 'invalid json',
    });
    final value = await SharedPreferencesAppPreferencesStore(
            await SharedPreferences.getInstance())
        .load();
    expect(value.layout, const GalleryLayoutSettings());
    expect(value.themeChoice, ViewerThemeChoice.galleryDark);
  });

  test('controller serializes count changes without replacing browser choices',
      () async {
    final store = MemoryAppPreferencesStore();
    final controller = await AppPreferencesController.load(store);
    controller.setBrowser(displayMode: BrowserDisplayMode.list);
    controller.setLayout(controller.value.layout
        .copyWith(portraitFolders: const FolderViewSettings(squareColumns: 2)));
    controller
        .setLayout(controller.value.layout.copyWith(landscapeListColumns: 1));
    await controller.flush();
    expect(store.value.displayMode, BrowserDisplayMode.list);
    expect(store.value.layout.portraitFolders.columns, 2);
    expect(store.value.layout.landscapeListColumns, 1);
    controller.dispose();
  });

  test('equal-height density uses viewport and orientation', () {
    const layout = GalleryLayoutSettings();
    expect(layout.equalHeight(isPortrait: true, viewportWidth: 900),
        (900 - 16 - 16) / 3);
    expect(layout.equalHeight(isPortrait: false, viewportWidth: 500),
        (500 - 16 - 24) / 4);
    expect(
        layout.equalHeight(
            isPortrait: true, viewportWidth: 900, immersive: true),
        (900 - 4 - 2) / 3);
  });
}
