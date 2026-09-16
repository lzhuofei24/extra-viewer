import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../diagnostics/app_diagnostic_log.dart';
import '../thumbnails/thumbnail_store.dart';

const audioWaveformSampleCount = 384;
const _waveformSampleRate = 2000;

/// Stores compact peak envelopes outside SQLite. Each cache artifact contains
/// one unsigned byte per waveform bar, keyed by the source file fingerprint.
class AudioWaveformStore {
  AudioWaveformStore(this.baseDirectoryPath);

  final String baseDirectoryPath;

  String pathFor(String key) {
    final prefix = key.length >= 2 ? key.substring(0, 2) : '00';
    return p.join(baseDirectoryPath, 'audio_waveforms', prefix, '$key.wave');
  }

  Future<Uint8List?> read(String key) async {
    final file = File(pathFor(key));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return bytes.length == audioWaveformSampleCount ? bytes : null;
  }

  Future<void> write(String key, Uint8List peaks) async {
    final file = File(pathFor(key));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(peaks, flush: false);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

class AudioWaveformService {
  AudioWaveformService(this.store);

  final AudioWaveformStore store;
  static String? _cachedFfmpegExecutable;

  String cacheKeyFor({
    required String fingerprint,
  }) {
    return thumbnailCacheKeyFor(
      fingerprint: fingerprint,
      version: 1,
    );
  }

  Future<Uint8List?> load({
    required String fingerprint,
  }) {
    return store.read(cacheKeyFor(
      fingerprint: fingerprint,
    ));
  }

  Future<Uint8List?> ensure({
    required String path,
    required String fingerprint,
    required int? durationMs,
  }) async {
    final key = cacheKeyFor(
      fingerprint: fingerprint,
    );
    final cached = await store.read(key);
    if (cached != null) {
      AppDiagnosticLog.instance.info('audio_waveform_cache_hit', fields: {
        'cacheKey': key,
      });
      return cached;
    }

    try {
      AppDiagnosticLog.instance.info('audio_waveform_extract_started', fields: {
        'cacheKey': key,
        'durationMs': durationMs,
      });
      final peaks = await _extractPeaks(
        file: File(path),
        durationMs: durationMs,
      );
      await store.write(key, peaks);
      AppDiagnosticLog.instance
          .info('audio_waveform_extract_finished', fields: {
        'cacheKey': key,
        'sampleCount': peaks.length,
      });
      return peaks;
    } catch (error, stackTrace) {
      // Waveform data improves navigation but must never block indexing or
      // prevent the built-in audio player from opening a valid source.
      AppDiagnosticLog.instance.error(
        'audio_waveform_extract_failed',
        error,
        stackTrace,
        fields: {'cacheKey': key},
      );
      return null;
    }
  }

  Future<Uint8List> _extractPeaks({
    required File file,
    required int? durationMs,
  }) async {
    ProcessException? launchError;
    Object? lastError;
    final candidates = <String>{
      if (_cachedFfmpegExecutable != null) _cachedFfmpegExecutable!,
      ..._ffmpegCandidates(),
    };
    for (final executable in candidates) {
      try {
        final peaks = await _extractWithExecutable(
          executable: executable,
          file: file,
          durationMs: durationMs,
        );
        _cachedFfmpegExecutable = executable;
        return peaks;
      } on ProcessException catch (error) {
        launchError = error;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) throw StateError('$lastError');
    if (launchError != null) throw launchError;
    throw const ProcessException('ffmpeg', [], 'FFmpeg unavailable');
  }

  Future<Uint8List> _extractWithExecutable({
    required String executable,
    required File file,
    required int? durationMs,
  }) async {
    final process = await Process.start(executable, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      file.path,
      '-vn',
      '-ac',
      '1',
      '-ar',
      '$_waveformSampleRate',
      '-f',
      's16le',
      'pipe:1',
    ]);
    final estimatedSamples = durationMs == null || durationMs <= 0
        ? audioWaveformSampleCount
        : ((durationMs / 1000) * _waveformSampleRate).ceil();
    final samplesPerBucket = (estimatedSamples / audioWaveformSampleCount)
        .ceil()
        .clamp(1, 1 << 30)
        .toInt();
    final peaks = List<int>.filled(audioWaveformSampleCount, 0);
    var sampleIndex = 0;
    int? pendingByte;
    final stderrFuture =
        process.stderr.transform(systemEncoding.decoder).join();

    await for (final chunk in process.stdout) {
      for (final byte in chunk) {
        if (pendingByte == null) {
          pendingByte = byte;
          continue;
        }
        final raw = pendingByte | (byte << 8);
        pendingByte = null;
        final sample = raw >= 0x8000 ? raw - 0x10000 : raw;
        final bucket = (sampleIndex ~/ samplesPerBucket)
            .clamp(0, audioWaveformSampleCount - 1)
            .toInt();
        final amplitude = sample.abs();
        if (amplitude > peaks[bucket]) peaks[bucket] = amplitude;
        sampleIndex++;
      }
    }
    final exitCode = await process.exitCode;
    final stderr = await stderrFuture;
    if (exitCode != 0 || sampleIndex == 0) {
      throw ProcessException(
        executable,
        const [],
        stderr.isEmpty ? 'No PCM samples produced' : stderr,
        exitCode,
      );
    }
    final maximum =
        peaks.reduce((value, element) => value > element ? value : element);
    if (maximum <= 0) return Uint8List(audioWaveformSampleCount);
    return Uint8List.fromList([
      for (final peak in peaks)
        ((peak / maximum) * 255).round().clamp(0, 255).toInt(),
    ]);
  }

  List<String> _ffmpegCandidates() {
    final configured = [
      Platform.environment['BEST_VIEWER_FFMPEG'],
      Platform.environment['FFMPEG_PATH'],
    ].whereType<String>().where((value) => value.trim().isNotEmpty);
    return {
      ...configured,
      'ffmpeg',
    }.toList();
  }
}
