import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/core/diagnostics/app_diagnostic_log.dart';

Future<void> main() async {
  final bootstrap = runZonedGuarded<Future<void>>(
    () async {
      // Binding initialization and runApp must use the same zone. Otherwise
      // Flutter reports a zone mismatch on every debug startup.
      WidgetsFlutterBinding.ensureInitialized();
      await AppDiagnosticLog.instance.initialize();
      String? lastFlutterError;
      DateTime? lastFlutterErrorAt;
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        final signature = details.exceptionAsString();
        final now = DateTime.now();
        // A build-time assertion can be emitted once per visible list item.
        // Preserve the first actionable stack trace without turning a UI
        // warning into thousands of synchronous diagnostic writes.
        if (signature == lastFlutterError &&
            lastFlutterErrorAt != null &&
            now.difference(lastFlutterErrorAt!) < const Duration(seconds: 15)) {
          return;
        }
        lastFlutterError = signature;
        lastFlutterErrorAt = now;
        AppDiagnosticLog.instance.error(
          'flutter_error',
          details.exception,
          details.stack ?? StackTrace.current,
        );
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        AppDiagnosticLog.instance.error('platform_error', error, stackTrace);
        return true;
      };
      MediaKit.ensureInitialized();
      AppDiagnosticLog.instance.info('media_kit_initialized');
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await windowManager.ensureInitialized();
        const options = WindowOptions(
          size: Size(1280, 720),
          minimumSize: Size(960, 640),
          center: true,
          titleBarStyle: TitleBarStyle.hidden,
        );
        windowManager.waitUntilReadyToShow(options, () async {
          await windowManager.show();
          await windowManager.focus();
        });
      }
      runApp(const BestViewerApp());
    },
    (error, stackTrace) {
      AppDiagnosticLog.instance.error('uncaught_zone_error', error, stackTrace);
    },
  );
  if (bootstrap != null) await bootstrap;
}
