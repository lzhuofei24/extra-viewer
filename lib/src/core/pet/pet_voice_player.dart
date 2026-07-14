import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_diagnostic_log.dart';

/// Plays short bundled pet clips through a dedicated player. Assets are copied
/// once to cache because native media backends need an ordinary local path.
class PetVoicePlayer {
  Player? _player;
  final Map<String, File> _materialized = {};

  Future<void> play(String asset) async {
    try {
      final file = await _fileForAsset(asset);
      final player = _player ??= Player();
      await player.open(Media(file.path), play: true);
      AppDiagnosticLog.instance
          .info('pet_voice_played', fields: {'asset': asset});
    } catch (error, stackTrace) {
      AppDiagnosticLog.instance.warning('pet_voice_play_failed', fields: {
        'asset': asset,
        'error': '$error',
        'stack': '$stackTrace',
      });
    }
  }

  Future<void> stop() async {
    await _player?.stop();
  }

  Future<File> _fileForAsset(String asset) async {
    final cached = _materialized[asset];
    if (cached != null && await cached.exists()) return cached;
    final directory = await getTemporaryDirectory();
    final targetDirectory =
        Directory('${directory.path}${Platform.pathSeparator}pet_voices');
    await targetDirectory.create(recursive: true);
    final filename = asset.split('/').last;
    final file =
        File('${targetDirectory.path}${Platform.pathSeparator}$filename');
    if (!await file.exists()) {
      final bytes = await rootBundle.load(asset);
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    _materialized[asset] = file;
    return file;
  }

  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
  }
}
