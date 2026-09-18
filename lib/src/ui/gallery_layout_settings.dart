import 'package:flutter/foundation.dart';

enum GalleryLayoutPreset {
  compact('紧凑'),
  standard('默认'),
  spacious('宽阔');

  const GalleryLayoutPreset(this.label);

  final String label;

  GalleryLayoutSettings get settings => switch (this) {
        GalleryLayoutPreset.compact => const GalleryLayoutSettings(
            pageMargin: 4,
            cardGap: 4,
            cardRadius: 8,
            portraitEqualWidthColumns: 3,
            landscapeEqualWidthColumns: 6,
            portraitSquareColumns: 3,
            landscapeSquareColumns: 5,
            equalHeightTarget: 300,
            folderHeight: 240,
            portraitFolderColumns: 3,
          ),
        GalleryLayoutPreset.standard => const GalleryLayoutSettings(),
        GalleryLayoutPreset.spacious => const GalleryLayoutSettings(
            pageMargin: 16,
            cardGap: 16,
            cardRadius: 24,
            portraitEqualWidthColumns: 1,
            landscapeEqualWidthColumns: 3,
            portraitSquareColumns: 2,
            landscapeSquareColumns: 2,
            equalHeightTarget: 500,
            folderHeight: 400,
            portraitFolderColumns: 1,
          ),
      };
}

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
    this.portraitFolderColumns = defaultPortraitFolderColumns,
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
  static const int defaultPortraitFolderColumns = 2;

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
  final int portraitFolderColumns;

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
    int? portraitFolderColumns,
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
        portraitFolderColumns:
            portraitFolderColumns ?? this.portraitFolderColumns,
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
        portraitFolderColumns: portraitFolderColumns.clamp(1, 8),
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
      other.folderHeight == folderHeight &&
      other.portraitFolderColumns == portraitFolderColumns;

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
      folderHeight,
      portraitFolderColumns);
}
