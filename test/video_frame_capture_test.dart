import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/thumbnails/video_frame_capture.dart';

void main() {
  test('advances and seeks when metadata is ready but screenshots are empty',
      () async {
    final events = <String>[];
    var calls = 0;
    final frame = await captureAdvancingVideoFrame(
      play: () async => events.add('play'),
      pause: () async => events.add('pause'),
      screenshot: () async => ++calls == 10 ? Uint8List.fromList([1]) : null,
      seek: (fraction) async => events.add('seek:$fraction'),
      checkActive: () {},
      wait: () async {},
    );
    expect(frame, [1]);
    expect(events, ['play', 'seek:0.1', 'play', 'pause']);
  });
  test('empty frames exhaust a bounded number of attempts', () async {
    var calls = 0;
    expect(
        await captureAdvancingVideoFrame(
          play: () async {},
          pause: () async {},
          screenshot: () async {
            calls++;
            return Uint8List(0);
          },
          seek: (_) async {},
          checkActive: () {},
          wait: () async {},
        ),
        isNull);
    expect(calls, 24);
  });
  test('cancellation prevents starting playback', () async {
    await expectLater(
        captureAdvancingVideoFrame(
          play: () async => fail('must not start'),
          pause: () async {},
          screenshot: () async => null,
          seek: (_) async {},
          checkActive: () => throw StateError('cancelled'),
        ),
        throwsStateError);
  });
}
