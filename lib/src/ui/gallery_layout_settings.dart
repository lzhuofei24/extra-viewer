import 'package:flutter/foundation.dart';

@immutable
class GalleryLayoutSettings {
  const GalleryLayoutSettings({
    this.portraitEqualWidthColumns = 3,
    this.landscapeEqualWidthColumns = 4,
    this.portraitSquareColumns = 3,
    this.landscapeSquareColumns = 4,
    this.portraitEqualHeightRows = 3,
    this.landscapeEqualHeightRows = 2,
    this.portraitFolderColumns = 3,
    this.landscapeFolderColumns = 4,
    this.landscapeListColumns = 3,
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
  final int portraitEqualHeightRows;
  final int landscapeEqualHeightRows;
  final int portraitFolderColumns;
  final int landscapeFolderColumns;
  final int landscapeListColumns;

  int equalWidthColumns({required bool isPortrait}) =>
      isPortrait ? portraitEqualWidthColumns : landscapeEqualWidthColumns;
  int squareColumns({required bool isPortrait}) =>
      isPortrait ? portraitSquareColumns : landscapeSquareColumns;
  int folderColumns({required bool isPortrait}) =>
      isPortrait ? portraitFolderColumns : landscapeFolderColumns;
  int equalHeightRows({required bool isPortrait}) =>
      isPortrait ? portraitEqualHeightRows : landscapeEqualHeightRows;
  double equalHeight(
      {required bool isPortrait,
      required double viewportHeight,
      bool immersive = false}) {
    final rows = equalHeightRows(isPortrait: isPortrait);
    final gap = immersive ? immersiveGap : cardGap;
    return ((viewportHeight - 2 * pageMargin - (rows - 1) * gap) / rows)
        .clamp(48.0, double.infinity);
  }

  GalleryLayoutSettings copyWith({
    int? portraitEqualWidthColumns,
    int? landscapeEqualWidthColumns,
    int? portraitSquareColumns,
    int? landscapeSquareColumns,
    int? portraitEqualHeightRows,
    int? landscapeEqualHeightRows,
    int? portraitFolderColumns,
    int? landscapeFolderColumns,
    int? landscapeListColumns,
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
        portraitEqualHeightRows:
            portraitEqualHeightRows ?? this.portraitEqualHeightRows,
        landscapeEqualHeightRows:
            landscapeEqualHeightRows ?? this.landscapeEqualHeightRows,
        portraitFolderColumns:
            portraitFolderColumns ?? this.portraitFolderColumns,
        landscapeFolderColumns:
            landscapeFolderColumns ?? this.landscapeFolderColumns,
        landscapeListColumns: landscapeListColumns ?? this.landscapeListColumns,
      ).normalized();

  Map<String, int> toMap() => {
        'portraitEqualWidthColumns': portraitEqualWidthColumns,
        'landscapeEqualWidthColumns': landscapeEqualWidthColumns,
        'portraitSquareColumns': portraitSquareColumns,
        'landscapeSquareColumns': landscapeSquareColumns,
        'portraitEqualHeightRows': portraitEqualHeightRows,
        'landscapeEqualHeightRows': landscapeEqualHeightRows,
        'portraitFolderColumns': portraitFolderColumns,
        'landscapeFolderColumns': landscapeFolderColumns,
        'landscapeListColumns': landscapeListColumns,
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
      portraitEqualHeightRows: read('portraitEqualHeightRows', 3, 6),
      landscapeEqualHeightRows: read('landscapeEqualHeightRows', 2, 6),
      portraitFolderColumns: read('portraitFolderColumns', 3, 8),
      landscapeFolderColumns: read('landscapeFolderColumns', 4, 8),
      landscapeListColumns: read('landscapeListColumns', 3, 3),
    );
  }
  GalleryLayoutSettings normalized() => GalleryLayoutSettings.fromMap(toMap());

  @override
  bool operator ==(Object other) =>
      other is GalleryLayoutSettings &&
      other.portraitEqualWidthColumns == portraitEqualWidthColumns &&
      other.landscapeEqualWidthColumns == landscapeEqualWidthColumns &&
      other.portraitSquareColumns == portraitSquareColumns &&
      other.landscapeSquareColumns == landscapeSquareColumns &&
      other.portraitEqualHeightRows == portraitEqualHeightRows &&
      other.landscapeEqualHeightRows == landscapeEqualHeightRows &&
      other.portraitFolderColumns == portraitFolderColumns &&
      other.landscapeFolderColumns == landscapeFolderColumns &&
      other.landscapeListColumns == landscapeListColumns;
  @override
  int get hashCode => Object.hashAll(toMap().values);
}
