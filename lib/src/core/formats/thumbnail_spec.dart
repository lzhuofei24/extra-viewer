/// Masonry cards share a stable horizontal pixel budget while preserving each
/// source's natural height. Small sources are never enlarged.
const thumbnailWidth = 640;

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
