import 'package:flutter/foundation.dart';

enum FolderDisplay { stacked, square, list }

enum FolderCardLayout { equalHeight, equalWidth }

@immutable
class FolderViewSettings {
  const FolderViewSettings({
    this.display = FolderDisplay.square,
    this.stackedLayout = FolderCardLayout.equalWidth,
    this.squareLayout = FolderCardLayout.equalWidth,
    this.stackedColumns = 3,
    this.squareColumns = 3,
    this.stackedHeightLevel = 6,
    this.squareHeightLevel = 6,
    this.listColumns = 1,
  });
  static const landscape = FolderViewSettings(
      display: FolderDisplay.stacked,
      stackedColumns: 4,
      squareColumns: 4,
      stackedHeightLevel: 5,
      squareHeightLevel: 5,
      listColumns: 3);
  final FolderDisplay display;
  final FolderCardLayout stackedLayout, squareLayout;
  final int stackedColumns,
      squareColumns,
      stackedHeightLevel,
      squareHeightLevel,
      listColumns;
  bool get usesSquarePreview => display != FolderDisplay.stacked;
  FolderCardLayout get cardLayout =>
      display == FolderDisplay.stacked ? stackedLayout : squareLayout;
  int get columns =>
      display == FolderDisplay.stacked ? stackedColumns : squareColumns;
  int get heightLevel =>
      display == FolderDisplay.stacked ? stackedHeightLevel : squareHeightLevel;

  FolderViewSettings copyWith(
          {FolderDisplay? display,
          FolderCardLayout? cardLayout,
          int? columns,
          int? heightLevel,
          int? listColumns}) =>
      FolderViewSettings(
          display: display ?? this.display,
          stackedLayout: this.display == FolderDisplay.stacked
              ? cardLayout ?? stackedLayout
              : stackedLayout,
          squareLayout: this.display != FolderDisplay.stacked
              ? cardLayout ?? squareLayout
              : squareLayout,
          stackedColumns: this.display == FolderDisplay.stacked
              ? columns ?? stackedColumns
              : stackedColumns,
          squareColumns: this.display != FolderDisplay.stacked
              ? columns ?? squareColumns
              : squareColumns,
          stackedHeightLevel: this.display == FolderDisplay.stacked
              ? heightLevel ?? stackedHeightLevel
              : stackedHeightLevel,
          squareHeightLevel: this.display != FolderDisplay.stacked
              ? heightLevel ?? squareHeightLevel
              : squareHeightLevel,
          listColumns: listColumns ?? this.listColumns);

  Map<String, int> toMap(String prefix) => {
        '${prefix}Display': display.index,
        '${prefix}StackedLayout': stackedLayout.index,
        '${prefix}SquareLayout': squareLayout.index,
        '${prefix}StackedColumns': stackedColumns,
        '${prefix}SquareColumns': squareColumns,
        '${prefix}StackedHeightLevel': stackedHeightLevel,
        '${prefix}SquareHeightLevel': squareHeightLevel,
        '${prefix}ListColumns': listColumns,
      };
  factory FolderViewSettings.fromMap(Map<String, Object?> map,
      {required bool portrait}) {
    final prefix = portrait ? 'portraitFolder' : 'landscapeFolder';
    final defaults = portrait ? const FolderViewSettings() : landscape;
    int read(String key, int fallback, int max) {
      final value = map['$prefix$key'];
      return value is int && value >= 1 ? value.clamp(1, max) : fallback;
    }

    T enumValue<T>(String key, List<T> values, T fallback) {
      final value = map['$prefix$key'];
      return value is int && value >= 0 && value < values.length
          ? values[value]
          : fallback;
    }

    final oldColumns = read('Columns', defaults.columns, 8);
    return FolderViewSettings(
      display: enumValue('Display', FolderDisplay.values, defaults.display),
      stackedLayout: enumValue(
          'StackedLayout', FolderCardLayout.values, defaults.stackedLayout),
      squareLayout: enumValue(
          'SquareLayout', FolderCardLayout.values, defaults.squareLayout),
      stackedColumns: read('StackedColumns', oldColumns, 8),
      squareColumns: read('SquareColumns', oldColumns, 8),
      stackedHeightLevel: read('StackedHeightLevel', 9 - oldColumns, 8),
      squareHeightLevel: read('SquareHeightLevel', 9 - oldColumns, 8),
      listColumns: read(
          'ListColumns',
          portrait
              ? 1
              : (map['landscapeListColumns'] is int
                  ? (map['landscapeListColumns'] as int).clamp(1, 4)
                  : 3),
          portrait ? 3 : 4),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is FolderViewSettings && mapEquals(toMap(''), other.toMap(''));
  @override
  int get hashCode => Object.hashAll(toMap('').values);
}
