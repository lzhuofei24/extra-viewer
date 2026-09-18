import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/app_preferences.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:best_viewer/src/ui/design_tokens.dart';
import 'package:best_viewer/src/ui/gallery_layout_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preferences use product defaults and persist browser choices',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesAppPreferencesStore(
        await SharedPreferences.getInstance());
    final initial = await store.load();
    expect(initial.themeChoice, ViewerThemeChoice.system);
    expect(initial.sortMode, EntitySortMode.nameAsc);
    expect(initial.displayMode, BrowserDisplayMode.grid);
    expect(initial.gridLayout, BrowserGridLayout.equalHeight);
    expect(initial.layout, const GalleryLayoutSettings());

    await store.save(initial.copyWith(
      themeChoice: ViewerThemeChoice.galleryDark,
      sortMode: EntitySortMode.sizeDesc,
      displayMode: BrowserDisplayMode.list,
      gridLayout: BrowserGridLayout.square,
      layout: initial.layout.copyWith(
        cardRadius: 24,
        portraitEqualWidthColumns: 3,
        landscapeSquareColumns: 5,
      ),
    ));
    final restored = await store.load();
    expect(restored.themeChoice, ViewerThemeChoice.galleryDark);
    expect(restored.sortMode, EntitySortMode.sizeDesc);
    expect(restored.displayMode, BrowserDisplayMode.list);
    expect(restored.gridLayout, BrowserGridLayout.square);
    expect(restored.layout.cardRadius, 24);
    expect(restored.layout.portraitEqualWidthColumns, 3);
    expect(restored.layout.landscapeSquareColumns, 5);
  });

  test('invalid stored values fall back or clamp to supported ranges',
      () async {
    SharedPreferences.setMockInitialValues({
      'preferences.theme': 'removed-theme',
      'preferences.browser.display': 'removed-display',
      'preferences.gallery.page_margin': -40.0,
      'preferences.gallery.equal_height': 9999.0,
      'preferences.gallery.portrait_equal_width_columns': 0,
      'preferences.gallery.landscape_square_columns': 99,
    });
    final store = SharedPreferencesAppPreferencesStore(
        await SharedPreferences.getInstance());
    final value = await store.load();
    expect(value.themeChoice, ViewerThemeChoice.system);
    expect(value.displayMode, BrowserDisplayMode.grid);
    expect(value.layout.pageMargin, 0);
    expect(value.layout.equalHeightTarget, 600);
    expect(value.layout.portraitEqualWidthColumns, 1);
    expect(value.layout.landscapeSquareColumns, 8);
  });

  test('controller serializes changes and resets only layout', () async {
    final store = MemoryAppPreferencesStore();
    final controller = await AppPreferencesController.load(store);
    controller.setTheme(ViewerThemeChoice.galleryLight);
    controller.setBrowser(displayMode: BrowserDisplayMode.list);
    controller.setLayout(
        controller.value.layout.copyWith(cardGap: 20, folderHeight: 450));
    controller.resetLayout();
    await controller.flush();
    expect(store.value.themeChoice, ViewerThemeChoice.galleryLight);
    expect(store.value.displayMode, BrowserDisplayMode.list);
    expect(store.value.layout, const GalleryLayoutSettings());
  });
}
