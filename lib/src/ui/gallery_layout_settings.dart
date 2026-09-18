import 'package:flutter/foundation.dart';

@immutable
class GalleryLayoutSettings {
  const GalleryLayoutSettings({
    this.pageMargin = defaultPageMargin,
    this.cardGap = defaultCardGap,
    this.cardRadius = defaultCardRadius,
    this.portraitEqualWidthColumns = defaultPortraitEqualWidthColumns,
    this.landscapeEqualWidthColumns = defaultLandscapeEqualWidthColumns,
    this.portraitSquareColumns = defaultPortraitSquareColumns,
    this.landscapeSquareColumns = defaultLandscapeSquareColumns,
    this.equalHeightTarget = defaultEqualHeightTarget,
    this.folderHeight = defaultFolderHeight,
  });

  static const double defaultPageMargin = 8;
  static const double defaultCardGap = 8;
  static const double defaultCardRadius = 16;
  static const int defaultPortraitEqualWidthColumns = 2;
  static const int defaultLandscapeEqualWidthColumns = 4;
  static const int defaultPortraitSquareColumns = 2;
  static const int defaultLandscapeSquareColumns = 3;
  static const double defaultEqualHeightTarget = 400;
  static const double defaultFolderHeight = 320;

  static const double immersiveMargin = 2;
  static const double immersiveGap = 1;
  static const double immersiveRadius = 2;

  final double pageMargin;
  final double cardGap;
  final double cardRadius;
  final int portraitEqualWidthColumns;
  final int landscapeEqualWidthColumns;
  final int portraitSquareColumns;
  final int landscapeSquareColumns;
  final double equalHeightTarget;
  final double folderHeight;

  int equalWidthColumns({required bool isPortrait}) =>
      isPortrait ? portraitEqualWidthColumns : landscapeEqualWidthColumns;

  int squareColumns({required bool isPortrait}) =>
      isPortrait ? portraitSquareColumns : landscapeSquareColumns;

  GalleryLayoutSettings copyWith({
    double? pageMargin,
    double? cardGap,
    double? cardRadius,
    int? portraitEqualWidthColumns,
    int? landscapeEqualWidthColumns,
    int? portraitSquareColumns,
    int? landscapeSquareColumns,
    double? equalHeightTarget,
    double? folderHeight,
  }) =>
      GalleryLayoutSettings(
        pageMargin: pageMargin ?? this.pageMargin,
        cardGap: cardGap ?? this.cardGap,
        cardRadius: cardRadius ?? this.cardRadius,
        portraitEqualWidthColumns:
            portraitEqualWidthColumns ?? this.portraitEqualWidthColumns,
        landscapeEqualWidthColumns:
            landscapeEqualWidthColumns ?? this.landscapeEqualWidthColumns,
        portraitSquareColumns:
            portraitSquareColumns ?? this.portraitSquareColumns,
        landscapeSquareColumns:
            landscapeSquareColumns ?? this.landscapeSquareColumns,
        equalHeightTarget: equalHeightTarget ?? this.equalHeightTarget,
        folderHeight: folderHeight ?? this.folderHeight,
      );

  GalleryLayoutSettings normalized() => GalleryLayoutSettings(
        pageMargin: pageMargin.clamp(0, 24),
        cardGap: cardGap.clamp(0, 24),
        cardRadius: cardRadius.clamp(0, 32),
        portraitEqualWidthColumns: portraitEqualWidthColumns.clamp(1, 8),
        landscapeEqualWidthColumns: landscapeEqualWidthColumns.clamp(1, 8),
        portraitSquareColumns: portraitSquareColumns.clamp(1, 8),
        landscapeSquareColumns: landscapeSquareColumns.clamp(1, 8),
        equalHeightTarget: equalHeightTarget.clamp(160, 600),
        folderHeight: folderHeight.clamp(140, 480),
      );

  @override
  bool operator ==(Object other) =>
      other is GalleryLayoutSettings &&
      other.pageMargin == pageMargin &&
      other.cardGap == cardGap &&
      other.cardRadius == cardRadius &&
      other.portraitEqualWidthColumns == portraitEqualWidthColumns &&
      other.landscapeEqualWidthColumns == landscapeEqualWidthColumns &&
      other.portraitSquareColumns == portraitSquareColumns &&
      other.landscapeSquareColumns == landscapeSquareColumns &&
      other.equalHeightTarget == equalHeightTarget &&
      other.folderHeight == folderHeight;

  @override
  int get hashCode => Object.hash(
      pageMargin,
      cardGap,
      cardRadius,
      portraitEqualWidthColumns,
      landscapeEqualWidthColumns,
      portraitSquareColumns,
      landscapeSquareColumns,
      equalHeightTarget,
      folderHeight);
}
