import 'package:flutter/foundation.dart';

@immutable
class GalleryLayoutSettings {
  const GalleryLayoutSettings({
    this.pageMargin = defaultPageMargin,
    this.cardGap = defaultCardGap,
    this.cardRadius = defaultCardRadius,
    this.equalWidthTarget = defaultEqualWidthTarget,
    this.equalHeightTarget = defaultEqualHeightTarget,
    this.squareSize = defaultSquareSize,
    this.folderHeight = defaultFolderHeight,
  });

  static const double defaultPageMargin = 8;
  static const double defaultCardGap = 8;
  static const double defaultCardRadius = 16;
  static const double defaultEqualWidthTarget = 300;
  static const double defaultEqualHeightTarget = 400;
  static const double defaultSquareSize = 330;
  static const double defaultFolderHeight = 320;

  static const double immersiveMargin = 2;
  static const double immersiveGap = 1;
  static const double immersiveRadius = 2;

  final double pageMargin;
  final double cardGap;
  final double cardRadius;
  final double equalWidthTarget;
  final double equalHeightTarget;
  final double squareSize;
  final double folderHeight;

  GalleryLayoutSettings copyWith({
    double? pageMargin,
    double? cardGap,
    double? cardRadius,
    double? equalWidthTarget,
    double? equalHeightTarget,
    double? squareSize,
    double? folderHeight,
  }) =>
      GalleryLayoutSettings(
        pageMargin: pageMargin ?? this.pageMargin,
        cardGap: cardGap ?? this.cardGap,
        cardRadius: cardRadius ?? this.cardRadius,
        equalWidthTarget: equalWidthTarget ?? this.equalWidthTarget,
        equalHeightTarget: equalHeightTarget ?? this.equalHeightTarget,
        squareSize: squareSize ?? this.squareSize,
        folderHeight: folderHeight ?? this.folderHeight,
      );

  GalleryLayoutSettings normalized() => GalleryLayoutSettings(
        pageMargin: pageMargin.clamp(0, 24),
        cardGap: cardGap.clamp(0, 24),
        cardRadius: cardRadius.clamp(0, 32),
        equalWidthTarget: equalWidthTarget.clamp(160, 480),
        equalHeightTarget: equalHeightTarget.clamp(160, 600),
        squareSize: squareSize.clamp(160, 480),
        folderHeight: folderHeight.clamp(140, 480),
      );

  @override
  bool operator ==(Object other) =>
      other is GalleryLayoutSettings &&
      other.pageMargin == pageMargin &&
      other.cardGap == cardGap &&
      other.cardRadius == cardRadius &&
      other.equalWidthTarget == equalWidthTarget &&
      other.equalHeightTarget == equalHeightTarget &&
      other.squareSize == squareSize &&
      other.folderHeight == folderHeight;

  @override
  int get hashCode => Object.hash(pageMargin, cardGap, cardRadius,
      equalWidthTarget, equalHeightTarget, squareSize, folderHeight);
}
