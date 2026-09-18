import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app.dart';
import 'src/core/diagnostics/app_diagnostic_log.dart';
import 'src/ui/app_preferences.dart';

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
      late final AppPreferencesController preferences;
      try {
        final preferencesStore =
            await SharedPreferencesAppPreferencesStore.create();
        preferences = await AppPreferencesController.load(preferencesStore);
      } catch (error, stackTrace) {
        AppDiagnosticLog.instance.error(
          'preferences_load_failed',
          error,
          stackTrace,
        );
        preferences = AppPreferencesController.memory();
      }
      runApp(BestViewerApp(preferences: preferences));
    },
    (error, stackTrace) {
      AppDiagnosticLog.instance.error('uncaught_zone_error', error, stackTrace);
    },
  );
  if (bootstrap != null) await bootstrap;
}
