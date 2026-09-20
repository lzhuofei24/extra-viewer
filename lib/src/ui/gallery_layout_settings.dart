import 'package:flutter/foundation.dart';
import 'folder_view_settings.dart';
export 'folder_view_settings.dart';

@immutable
class GalleryLayoutSettings {
  const GalleryLayoutSettings({
    this.portraitEqualWidthColumns = 3,
    this.landscapeEqualWidthColumns = 4,
    this.portraitSquareColumns = 3,
    this.landscapeSquareColumns = 4,
    this.portraitEqualHeightLevel = 6,
    this.landscapeEqualHeightLevel = 5,
    this.landscapeListColumns = 3,
    this.portraitListColumns = 1,
    this.portraitTextListColumns = 1,
    this.landscapeTextListColumns = 3,
    this.portraitFolders = const FolderViewSettings(),
    this.landscapeFolders = FolderViewSettings.landscape,
  });

  final double pageMargin = 8;
  final double cardGap = 8;
  final double cardRadius = 16;
  static const double immersiveMargin = 2;
  static const double immersiveGap = 1;
  static const double immersiveRadius = 2;
  final int portraitEqualWidthColumns;
  final int landscapeEqualWidthColumns;
  final int portraitSquareColumns;
  final int landscapeSquareColumns;
  final int portraitEqualHeightLevel;
  final int landscapeEqualHeightLevel;
  final int landscapeListColumns;
  final int portraitListColumns,
      portraitTextListColumns,
      landscapeTextListColumns;
  final FolderViewSettings portraitFolders, landscapeFolders;
  FolderViewSettings folders({required bool isPortrait}) =>
      isPortrait ? portraitFolders : landscapeFolders;
  GalleryLayoutSettings withFolders(bool portrait, FolderViewSettings value) =>
      copyWith(
          portraitFolders: portrait ? value : null,
          landscapeFolders: portrait ? null : value);
  int fileListColumns({required bool isPortrait, required bool textOnly}) =>
      textOnly
          ? (isPortrait ? portraitTextListColumns : landscapeTextListColumns)
          : (isPortrait ? portraitListColumns : landscapeListColumns);
  GalleryLayoutSettings withFileListColumns(
          bool portrait, bool textOnly, int value) =>
      textOnly
          ? copyWith(
              portraitTextListColumns: portrait ? value : null,
              landscapeTextListColumns: portrait ? null : value)
          : copyWith(
              portraitListColumns: portrait ? value : null,
              landscapeListColumns: portrait ? null : value);

  int equalWidthColumns({required bool isPortrait}) =>
      isPortrait ? portraitEqualWidthColumns : landscapeEqualWidthColumns;
  int squareColumns({required bool isPortrait}) =>
      isPortrait ? portraitSquareColumns : landscapeSquareColumns;
  int equalHeightLevel({required bool isPortrait}) =>
      isPortrait ? portraitEqualHeightLevel : landscapeEqualHeightLevel;
  double equalHeight(
      {required bool isPortrait,
      required double viewportWidth,
      bool immersive = false}) {
    final columns = 9 - equalHeightLevel(isPortrait: isPortrait);
    final gap = immersive ? immersiveGap : cardGap;
    final margin = immersive ? immersiveMargin : pageMargin;
    return ((viewportWidth - 2 * margin - (columns - 1) * gap) / columns)
        .clamp(1.0, double.infinity);
  }

  GalleryLayoutSettings copyWith({
    int? portraitEqualWidthColumns,
    int? landscapeEqualWidthColumns,
    int? portraitSquareColumns,
    int? landscapeSquareColumns,
    int? portraitEqualHeightLevel,
    int? landscapeEqualHeightLevel,
    int? landscapeListColumns,
    int? portraitListColumns,
    portraitTextListColumns,
    landscapeTextListColumns,
    FolderViewSettings? portraitFolders,
    landscapeFolders,
  }) =>
      GalleryLayoutSettings(
        portraitEqualWidthColumns:
            portraitEqualWidthColumns ?? this.portraitEqualWidthColumns,
        landscapeEqualWidthColumns:
            landscapeEqualWidthColumns ?? this.landscapeEqualWidthColumns,
        portraitSquareColumns:
            portraitSquareColumns ?? this.portraitSquareColumns,
        landscapeSquareColumns:
            landscapeSquareColumns ?? this.landscapeSquareColumns,
        portraitEqualHeightLevel:
            portraitEqualHeightLevel ?? this.portraitEqualHeightLevel,
        landscapeEqualHeightLevel:
            landscapeEqualHeightLevel ?? this.landscapeEqualHeightLevel,
        landscapeListColumns: landscapeListColumns ?? this.landscapeListColumns,
        portraitListColumns: portraitListColumns ?? this.portraitListColumns,
        portraitTextListColumns:
            portraitTextListColumns ?? this.portraitTextListColumns,
        landscapeTextListColumns:
            landscapeTextListColumns ?? this.landscapeTextListColumns,
        portraitFolders: portraitFolders ?? this.portraitFolders,
        landscapeFolders: landscapeFolders ?? this.landscapeFolders,
      ).normalized();

  Map<String, int> toMap() => {
        'portraitEqualWidthColumns': portraitEqualWidthColumns,
        'landscapeEqualWidthColumns': landscapeEqualWidthColumns,
        'portraitSquareColumns': portraitSquareColumns,
        'landscapeSquareColumns': landscapeSquareColumns,
        'portraitEqualHeightLevel': portraitEqualHeightLevel,
        'landscapeEqualHeightLevel': landscapeEqualHeightLevel,
        'landscapeListColumns': landscapeListColumns,
        'portraitListColumns': portraitListColumns,
        'portraitTextListColumns': portraitTextListColumns,
        'landscapeTextListColumns': landscapeTextListColumns,
        ...portraitFolders.toMap('portraitFolder'),
        ...landscapeFolders.toMap('landscapeFolder'),
      };

  factory GalleryLayoutSettings.fromMap(Map<String, Object?> values) {
    int read(String key, int fallback, int max) {
      final value = values[key];
      return value is int ? value.clamp(1, max) : fallback;
    }

    return GalleryLayoutSettings(
      portraitEqualWidthColumns: read('portraitEqualWidthColumns', 3, 8),
      landscapeEqualWidthColumns: read('landscapeEqualWidthColumns', 4, 8),
      portraitSquareColumns: read('portraitSquareColumns', 3, 8),
      landscapeSquareColumns: read('landscapeSquareColumns', 4, 8),
      portraitEqualHeightLevel: read('portraitEqualHeightLevel', 6, 8),
      landscapeEqualHeightLevel: read('landscapeEqualHeightLevel', 5, 8),
      landscapeListColumns: read('landscapeListColumns', 3, 4),
      portraitListColumns: read('portraitListColumns', 1, 3),
      portraitTextListColumns: read('portraitTextListColumns', 1, 3),
      landscapeTextListColumns: read(
          'landscapeTextListColumns', read('landscapeListColumns', 3, 4), 4),
      portraitFolders: FolderViewSettings.fromMap(values, portrait: true),
      landscapeFolders: FolderViewSettings.fromMap(values, portrait: false),
    );
  }
  GalleryLayoutSettings normalized() => GalleryLayoutSettings.fromMap(toMap());

  @override
  bool operator ==(Object other) =>
      other is GalleryLayoutSettings && mapEquals(other.toMap(), toMap());
  @override
  int get hashCode => Object.hashAll(toMap().values);
}
