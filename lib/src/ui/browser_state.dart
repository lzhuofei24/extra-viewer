import '../core/domain/models.dart';

enum BrowserDisplayMode { grid, list }

enum BrowserRootTab {
  directory,
  tree,
  graph;

  String get label => switch (this) {
        BrowserRootTab.directory => '目录',
        BrowserRootTab.tree => '树',
        BrowserRootTab.graph => '图',
      };
}

enum BrowserGridLayout {
  equalWidth,
  equalHeight,
  adaptive,
  square,
}

enum BrowserContentScope { direct, recursive }

enum BrowserFilter { all, nodes, content, recent }

class BrowserState {
  const BrowserState({
    this.sortMode = EntitySortMode.nameAsc,
    this.displayMode = BrowserDisplayMode.grid,
    this.gridLayout = BrowserGridLayout.equalHeight,
    this.rootTab = BrowserRootTab.directory,
    this.contentScope = BrowserContentScope.direct,
    this.filter = BrowserFilter.all,
  });

  final EntitySortMode sortMode;
  final BrowserDisplayMode displayMode;
  final BrowserGridLayout gridLayout;
  final BrowserRootTab rootTab;
  final BrowserContentScope contentScope;
  final BrowserFilter filter;

  BrowserState copyWith({
    EntitySortMode? sortMode,
    BrowserDisplayMode? displayMode,
    BrowserGridLayout? gridLayout,
    BrowserRootTab? rootTab,
    BrowserContentScope? contentScope,
    BrowserFilter? filter,
  }) {
    return BrowserState(
      sortMode: sortMode ?? this.sortMode,
      displayMode: displayMode ?? this.displayMode,
      gridLayout: gridLayout ?? this.gridLayout,
      rootTab: rootTab ?? this.rootTab,
      contentScope: contentScope ?? this.contentScope,
      filter: filter ?? this.filter,
    );
  }
}
