import 'dart:convert';
import 'dart:io';

import 'package:best_viewer/src/core/diagnostics/app_diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('persists lifecycle breadcrumbs and reports an unclean prior session',
      () async {
    final directory = await Directory.systemTemp.createTemp('best_viewer_log_');
    final log = AppDiagnosticLog.instance;
    addTearDown(() async {
      await log.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    await log.initializeAtPath(directory.path);
    log.info('audio_player_created', fields: {'entityId': 'audio-1'});
    await log.close();

    final marker = File(p.join(directory.path, 'logs', 'active_session.json'));
    await marker.writeAsString(jsonEncode({'sessionId': 'interrupted'}));
    await log.initializeAtPath(directory.path);
    await log.close();

    final logFiles = await Directory(p.join(directory.path, 'logs'))
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    final text = await logFiles.single.readAsString();
    expect(text, contains('audio_player_created'));
    expect(text, contains('previous_session_unclean'));
  });
}
