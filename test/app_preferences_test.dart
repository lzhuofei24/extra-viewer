import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preferences use defaults and persist browser choices and preset',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesAppPreferencesStore(
        await SharedPreferences.getInstance());
    final initial = await store.load();
    expect(initial.themeChoice, ViewerThemeChoice.system);
    expect(initial.sortMode, EntitySortMode.nameAsc);
    expect(initial.displayMode, BrowserDisplayMode.grid);
    expect(initial.gridLayout, BrowserGridLayout.equalHeight);
    expect(initial.layoutPreset, GalleryLayoutPreset.standard);
    expect(initial.layout, const GalleryLayoutSettings());

    await store.save(initial.copyWith(
      themeChoice: ViewerThemeChoice.galleryDark,
      sortMode: EntitySortMode.sizeDesc,
      displayMode: BrowserDisplayMode.list,
      gridLayout: BrowserGridLayout.square,
      layoutPreset: GalleryLayoutPreset.compact,
    ));
    final restored = await store.load();
    expect(restored.themeChoice, ViewerThemeChoice.galleryDark);
    expect(restored.sortMode, EntitySortMode.sizeDesc);
    expect(restored.displayMode, BrowserDisplayMode.list);
    expect(restored.gridLayout, BrowserGridLayout.square);
    expect(restored.layoutPreset, GalleryLayoutPreset.compact);
    expect(restored.layout.portraitFolderColumns, 3);
  });

  test('invalid and old granular values use the standard preset', () async {
    SharedPreferences.setMockInitialValues({
      'preferences.theme': 'removed-theme',
      'preferences.browser.display': 'removed-display',
      'preferences.gallery.preset': 'removed-preset',
      'preferences.gallery.page_margin': 24.0,
    });
    final store = SharedPreferencesAppPreferencesStore(
        await SharedPreferences.getInstance());
    final value = await store.load();
    expect(value.themeChoice, ViewerThemeChoice.system);
    expect(value.displayMode, BrowserDisplayMode.grid);
    expect(value.layoutPreset, GalleryLayoutPreset.standard);
    expect(value.layout.pageMargin, 8);
  });

  test('controller serializes preset changes independently', () async {
    final store = MemoryAppPreferencesStore();
    final controller = await AppPreferencesController.load(store);
    controller.setTheme(ViewerThemeChoice.galleryLight);
    controller.setBrowser(displayMode: BrowserDisplayMode.list);
    controller.setLayoutPreset(GalleryLayoutPreset.spacious);
    await controller.flush();
    expect(store.value.themeChoice, ViewerThemeChoice.galleryLight);
    expect(store.value.displayMode, BrowserDisplayMode.list);
    expect(store.value.layoutPreset, GalleryLayoutPreset.spacious);
    expect(store.value.layout.portraitFolderColumns, 1);
  });

  test('layout preset values match the product density contract', () {
    expect(GalleryLayoutPreset.compact.settings.portraitFolderColumns, 3);
    expect(GalleryLayoutPreset.standard.settings.portraitFolderColumns, 2);
    expect(GalleryLayoutPreset.spacious.settings.portraitFolderColumns, 1);
    expect(GalleryLayoutPreset.compact.settings.folderHeight, 240);
    expect(GalleryLayoutPreset.standard.settings.folderHeight, 320);
    expect(GalleryLayoutPreset.spacious.settings.folderHeight, 400);
  });
}
