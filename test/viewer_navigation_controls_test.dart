import 'dart:io';

import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/media/app_audio_controller.dart';
import 'package:best_viewer/src/core/media/audio_waveform_service.dart';
import 'package:best_viewer/src/modules/viewer/viewer_sessions.dart';
import 'package:best_viewer/src/ui/builtin_media_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('text navigation buttons stay mounted and disable at boundaries',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('viewer_navigation_');
    final sessions = ViewerSessions();
    final audio = AppAudioController(
      onProgressSaved: (_, __, ___) {},
      onSessionCreated: (
              {required entries,
              required currentIndex,
              sourceNodeId,
              sourceNodeName,
              required mode}) =>
          throw UnimplementedError(),
      onSessionUpdated: (
          {required id,
          currentIndex,
          positionMs,
          mode,
          shuffleRemaining,
          history,
          active}) {},
    );
    final queue = List.generate(2, (index) {
      final file = File('${temp.path}/$index.bin')..writeAsStringSync('text');
      return EntityListItem(
        id: '$index',
        title: '$index.bin',
        entityType: EntityType.text,
        path: file.path,
        format: 'bin',
        size: file.lengthSync(),
        modifiedAtMs: 0,
      );
    });

    await tester.pumpWidget(MaterialApp(
      home: EntityViewerPage(
        sessions: sessions,
        entity: queue.first,
        queue: queue,
        audioController: audio,
        audioWaveformService:
            AudioWaveformService(AudioWaveformStore(temp.path)),
      ),
    ));
    await tester.pump();

    InkWell navigationButton(String tooltip) => tester.widget<InkWell>(
          find.descendant(
            of: find.byTooltip(tooltip),
            matching: find.byType(InkWell),
          ),
        );

    expect(find.byTooltip('上一项'), findsOneWidget);
    expect(find.byTooltip('下一项'), findsOneWidget);
    expect(navigationButton('上一项').onTap, isNull);
    expect(navigationButton('下一项').onTap, isNotNull);
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一项'));
    await tester.pump();

    expect(find.byTooltip('上一项'), findsOneWidget);
    expect(find.byTooltip('下一项'), findsOneWidget);
    expect(navigationButton('上一项').onTap, isNotNull);
    expect(navigationButton('下一项').onTap, isNull);
    expect(find.text('2/2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(sessions.close);
    await audio.close();
    audio.dispose();
    temp.deleteSync(recursive: true);
  });
}
