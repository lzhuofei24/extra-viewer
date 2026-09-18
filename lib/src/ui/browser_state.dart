import '../core/domain/models.dart';

enum BrowserDisplayMode { grid, list }

enum BrowserRootTab {
  directory,
  tree;

  String get label => switch (this) {
        BrowserRootTab.directory => '目录',
        BrowserRootTab.tree => '分类',
      };
}

enum BrowserGridLayout {
  equalWidth,
  equalHeight,
  square,
}

enum FolderCoverStyle { automatic, square, stacked }

enum BrowserListStyle { text, compact, normal }

enum BrowserContentScope { direct, recursive }

enum BrowserFilter { all, nodes, content, recent }

class BrowserState {
  const BrowserState({
    this.sortMode = EntitySortMode.nameAsc,
    this.displayMode = BrowserDisplayMode.grid,
    this.gridLayout = BrowserGridLayout.equalHeight,
    this.folderCoverStyle = FolderCoverStyle.automatic,
    this.listStyle = BrowserListStyle.normal,
    this.rootTab = BrowserRootTab.directory,
    this.contentScope = BrowserContentScope.direct,
    this.filter = BrowserFilter.all,
  });

  final EntitySortMode sortMode;
  final BrowserDisplayMode displayMode;
  final BrowserGridLayout gridLayout;
  final FolderCoverStyle folderCoverStyle;
  final BrowserListStyle listStyle;
  final BrowserRootTab rootTab;
  final BrowserContentScope contentScope;
  final BrowserFilter filter;

  BrowserState copyWith({
    EntitySortMode? sortMode,
    BrowserDisplayMode? displayMode,
    BrowserGridLayout? gridLayout,
    BrowserListStyle? listStyle,
    FolderCoverStyle? folderCoverStyle,
    BrowserRootTab? rootTab,
    BrowserContentScope? contentScope,
    BrowserFilter? filter,
  }) {
    return BrowserState(
      sortMode: sortMode ?? this.sortMode,
      displayMode: displayMode ?? this.displayMode,
      gridLayout: gridLayout ?? this.gridLayout,
      folderCoverStyle: folderCoverStyle ?? this.folderCoverStyle,
      listStyle: listStyle ?? this.listStyle,
      rootTab: rootTab ?? this.rootTab,
      contentScope: contentScope ?? this.contentScope,
      filter: filter ?? this.filter,
    );
  }
}
