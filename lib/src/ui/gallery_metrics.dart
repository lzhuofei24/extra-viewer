import 'dart:io';

class GalleryMetrics {
  const GalleryMetrics._();

  static bool get _android => Platform.isAndroid;

  static double get cardWidth => _android ? 300 : 210;
  static double get cardHeight => _android ? 400 : 280;
  static double get squareSize => _android ? 330 : 240;
}
