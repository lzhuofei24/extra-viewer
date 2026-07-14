import 'dart:math' as math;

/// Masonry cards share a stable horizontal pixel budget while preserving each
/// source's natural height. Small sources are never enlarged.
const thumbnailWidth = 640;

/// Media previews retain their source aspect ratio while targeting this many
/// pixels. This gives portrait and landscape media comparable detail and size.
const thumbnailTargetPixelCount = 600 * 600;

const thumbnailWebpQuality = 78;

/// Legacy name retained for test fixtures and callers that need the target
/// horizontal width.
const thumbnailMaxEdge = thumbnailWidth;

// Index-node artwork remains a fixed icon canvas and is stored in SQLite.
const indexThumbnailWidth = 240;
const indexThumbnailHeight = 320;

// Non-media previews use the same 3:4 canvas but are drawn by Flutter.
const runtimePreviewWidth = 240;
const runtimePreviewHeight = 320;

({int width, int height}) thumbnailDimensionsForTargetPixelCount(
  int sourceWidth,
  int sourceHeight,
) {
  final width = sourceWidth.clamp(1, 1 << 30).toInt();
  final height = sourceHeight.clamp(1, 1 << 30).toInt();
  final sourcePixels = width * height;
  if (sourcePixels <= thumbnailTargetPixelCount) {
    return (width: width, height: height);
  }
  final scale = math.sqrt(thumbnailTargetPixelCount / sourcePixels);
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}
