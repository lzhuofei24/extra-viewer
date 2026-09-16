import 'dart:typed_data';

/// A metadata-ready signal does not guarantee a screenshot-ready video frame.
Future<Uint8List?> captureAdvancingVideoFrame({
  required Future<void> Function() play,
  required Future<void> Function() pause,
  required Future<Uint8List?> Function() screenshot,
  required Future<void> Function(double fraction) seek,
  required void Function() checkActive,
  Future<void> Function()? wait,
}) async {
  checkActive();
  await play();
  for (var attempt = 0; attempt < 24; attempt++) {
    checkActive();
    if (attempt == 8 || attempt == 16) {
      await seek(attempt == 8 ? .1 : .5);
      checkActive();
      await play();
    }
    final frame = await screenshot();
    checkActive();
    if (frame != null && frame.isNotEmpty) {
      await pause();
      return frame;
    }
    await (wait?.call() ??
        Future<void>.delayed(const Duration(milliseconds: 150)));
  }
  return null;
}
