import 'dart:io';

import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/core/media/app_audio_controller.dart';
import 'package:best_viewer/src/core/media/audio_waveform_service.dart';
import 'package:best_viewer/src/modules/viewer/viewer_sessions.dart';
import 'package:best_viewer/src/ui/builtin_media_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets(
      'collapsed image controls stay right aligned across image changes',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('image_toolbar_');
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
      final file = File('${temp.path}/$index.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
      return EntityListItem(
          id: '$index',
          title: '$index.png',
          entityType: EntityType.image,
          path: file.path,
          format: 'png',
          size: file.lengthSync(),
          modifiedAtMs: 0);
    });
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: EntityViewerPage(
      sessions: sessions,
      entity: queue.first,
      queue: queue,
      audioController: audio,
      audioWaveformService: AudioWaveformService(AudioWaveformStore(temp.path)),
      onEntityOpened: (entity) => opened.add(entity.id),
    )));
    Future<void> settleImage() async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
        if (find.byTooltip('收起工具栏').evaluate().isNotEmpty ||
            find.byTooltip('展开工具栏').evaluate().isNotEmpty) {
          return;
        }
      }
    }

    await settleImage();
    await tester.tap(find.byTooltip('收起工具栏'));
    await tester.pump();
    final collapsed = find.byTooltip('展开工具栏');
    expect(collapsed, findsOneWidget);
    expect(tester.getCenter(collapsed).dx, greaterThan(700));
    await tester.dragFrom(const Offset(400, 250), const Offset(-150, 0));
    await settleImage();
    expect(opened.last, queue.last.id);
    expect(collapsed, findsOneWidget);
    expect(find.byTooltip('收起工具栏'), findsNothing);
    await tester.tap(collapsed);
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await sessions.close();
    });
    await audio.close();
    audio.dispose();
    temp.deleteSync(recursive: true);
  });
}
