part of 'builtin_media_page.dart';

enum _ReaderLayoutMode { scroll, book }

class _PreviousEntityIntent extends Intent {
  const _PreviousEntityIntent();
}

class _NextEntityIntent extends Intent {
  const _NextEntityIntent();
}

class _TextReaderSettings {
  const _TextReaderSettings({
    this.fontSize = 16,
    this.lineHeight = 1.65,
    this.padding = 24,
    this.backgroundIndex = 0,
    this.fontFamilyIndex = 0,
    this.layoutMode = _ReaderLayoutMode.scroll,
    this.bookmarks = const [],
  });

  final double fontSize;
  final double lineHeight;
  final double padding;
  final int backgroundIndex;
  final int fontFamilyIndex;
  final _ReaderLayoutMode layoutMode;
  final List<int> bookmarks;

  static const _lineHeights = [1.45, 1.65, 1.9];
  static const _paddings = [16.0, 24.0, 36.0];
  static const _fontFamilies = ['KaiTi', 'SimSun', 'Microsoft YaHei'];
  static const _backgrounds = [
    // Keep the default reader surface visually continuous with the gallery.
    Color(0xff1f2621),
    Color(0xffffffff),
    Color(0xfff7f0df),
    Color(0xff181b1a),
  ];
  static const _foregrounds = [
    Color(0xffe7e2d4),
    Color(0xff1f2520),
    Color(0xff3f3323),
    Color(0xffe6ece5),
  ];

  factory _TextReaderSettings.fromJson(String? json) {
    if (json == null || json.trim().isEmpty) {
      return const _TextReaderSettings();
    }
    try {
      final value = jsonDecode(json);
      if (value is! Map<String, Object?>) {
        return const _TextReaderSettings();
      }
      return _TextReaderSettings(
        fontSize: _clampDouble(value['fontSize'], 16, 12, 28),
        lineHeight: _knownDouble(value['lineHeight'], _lineHeights, 1.65),
        padding: _knownDouble(value['padding'], _paddings, 24),
        backgroundIndex: _clampIndex(value['backgroundIndex'], _backgrounds),
        fontFamilyIndex: _clampIndex(value['fontFamilyIndex'], _fontFamilies),
        layoutMode: _ReaderLayoutMode.values.firstWhere(
          (mode) => mode.name == value['layoutMode'],
          orElse: () => _ReaderLayoutMode.scroll,
        ),
        bookmarks: (value['bookmarks'] as List? ?? const [])
            .whereType<num>()
            .map((item) => item.round())
            .toList(),
      );
    } catch (_) {
      return const _TextReaderSettings();
    }
  }

  String toJson() {
    return jsonEncode({
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'padding': padding,
      'backgroundIndex': backgroundIndex,
      'fontFamilyIndex': fontFamilyIndex,
      'layoutMode': layoutMode.name,
      'bookmarks': bookmarks,
    });
  }

  _TextReaderSettings withFontSizeDelta(double delta) {
    return _TextReaderSettings(
      fontSize: (fontSize + delta).clamp(12, 28).toDouble(),
      lineHeight: lineHeight,
      padding: padding,
      backgroundIndex: backgroundIndex,
      fontFamilyIndex: fontFamilyIndex,
      layoutMode: layoutMode,
      bookmarks: bookmarks,
    );
  }

  Color get background => _backgrounds[backgroundIndex];
  Color get foreground => _foregrounds[backgroundIndex];
  String get fontFamily => _fontFamilies[fontFamilyIndex];
  bool get isDark => backgroundIndex == 0 || backgroundIndex == 3;

  _TextReaderSettings _copyWith({
    double? lineHeight,
    double? padding,
    int? backgroundIndex,
    int? fontFamilyIndex,
    _ReaderLayoutMode? layoutMode,
    List<int>? bookmarks,
    double? fontSize,
  }) {
    return _TextReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      padding: padding ?? this.padding,
      backgroundIndex: backgroundIndex ?? this.backgroundIndex,
      fontFamilyIndex: fontFamilyIndex ?? this.fontFamilyIndex,
      layoutMode: layoutMode ?? this.layoutMode,
      bookmarks: bookmarks ?? this.bookmarks,
    );
  }
}

double _clampDouble(
  Object? value,
  double fallback,
  double min,
  double max,
) {
  final number = value is num ? value.toDouble() : fallback;
  return number.clamp(min, max).toDouble();
}

double _knownDouble(Object? value, List<double> allowed, double fallback) {
  final number = value is num ? value.toDouble() : fallback;
  return allowed.contains(number) ? number : fallback;
}

int _clampIndex(Object? value, List<Object> list) {
  final index = value is int ? value : 0;
  if (index < 0 || index >= list.length) return 0;
  return index;
}
