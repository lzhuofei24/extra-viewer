import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:best_viewer/src/ui/app_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final configFile = File('.dart_tool/package_config.json');
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final flutter = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((p) => p['name'] == 'flutter');
    final root = configFile.absolute.uri.resolve(flutter['rootUri'] as String);
    final fonts = root
        .replace(path: '${root.path.replaceFirst(RegExp(r'/$'), '')}/')
        .resolve('../../bin/cache/artifacts/material_fonts/');
    for (final font in {
      'GlassReview': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf'
    }.entries) {
      final loader = FontLoader(font.key)
        ..addFont(File.fromUri(fonts.resolve(font.value))
            .readAsBytes()
            .then(ByteData.sublistView));
      await loader.load();
    }
  });
  testWidgets(
      'glass owns text, icons, button states and progress colors in both themes',
      (tester) async {
    for (final brightness in Brightness.values) {
      for (final role in GlassSurfaceRole.values) {
        final appearance = GlassAppearance(brightness, role);
        late BuildContext glassContext;
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
                body: FloatingGlassSurface(
                    role: role,
                    child: Builder(builder: (context) {
                      glassContext = context;
                      return const SizedBox(width: 200, height: 100);
                    })))));
        await tester.pumpAndSettle();
        expect(GlassAppearance.of(glassContext).role, role);
        expect(DefaultTextStyle.of(glassContext).style.color,
            appearance.foreground);
        expect(IconTheme.of(glassContext).color, appearance.foreground);
        final theme = Theme.of(glassContext);
        expect(theme.iconButtonTheme.style!.foregroundColor!.resolve({}),
            appearance.foreground);
        expect(
            theme.iconButtonTheme.style!.foregroundColor!
                .resolve({WidgetState.disabled}),
            appearance.disabledForeground);
        expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}),
            appearance.foreground);
        expect(theme.sliderTheme.activeTrackColor, appearance.foreground);
        expect(theme.sliderTheme.secondaryActiveTrackColor,
            appearance.bufferedTrack);
        expect(theme.sliderTheme.inactiveTrackColor, appearance.track);
        expect(theme.progressIndicatorTheme.color, appearance.foreground);
        final glass =
            tester.widget<GlassContainer>(find.byType(GlassContainer).first);
        expect(glass.settings!.glassColor, appearance.settings.glassColor);
        expect(glass.settings!.blur, 8);
        expect(glass.settings!.thickness, 20);
        expect(
            contrast(
                appearance.foreground,
                Color.alphaBlend(
                    appearance.selectedBackground,
                    Color.alphaBlend(
                        appearance.settings.glassColor,
                        brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black))),
            greaterThanOrEqualTo(4.5));
      }
    }
  });

  testWidgets(
      'rendered fallback retains contrast over six backgrounds without opaque fill',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    for (final brightness in Brightness.values) {
      for (final role in GlassSurfaceRole.values) {
        final appearance = GlassAppearance(brightness, role);
        for (var background = 0; background < 6; background++) {
          Widget scene({required bool labels}) => MaterialApp(
              theme:
                  ThemeData(brightness: brightness, fontFamily: 'GlassReview'),
              home: Scaffold(
                  body: Center(
                      child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                    width: 320,
                    height: 150,
                    child: Stack(children: [
                      Positioned.fill(
                          child: CustomPaint(painter: _Backdrop(background))),
                      Positioned(
                          left: 20,
                          top: 20,
                          width: 280,
                          height: 110,
                          child: FloatingGlassSurface(
                              role: role,
                              child: labels
                                  ? Builder(
                                      builder: (context) => Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              const Text('Browse 123 Aa',
                                                  style:
                                                      TextStyle(fontSize: 18)),
                                              const Icon(Icons.play_arrow),
                                              Text('Details',
                                                  style: TextStyle(
                                                      color: GlassAppearance.of(
                                                              context)
                                                          .secondaryForeground))
                                            ],
                                          ))
                                  : const SizedBox.expand())),
                    ])),
              ))));
          await tester.pumpWidget(scene(labels: false));
          await tester.pumpAndSettle();
          final boundary = boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data =
                (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
            var minimum = double.infinity;
            for (var y = 46; y < 105; y += 6) {
              for (var x = 48; x < 272; x += 6) {
                final offset = (y * image.width + x) * 4;
                final color = Color.fromARGB(255, data.getUint8(offset),
                    data.getUint8(offset + 1), data.getUint8(offset + 2));
                minimum = math.min(
                    minimum, contrast(color, appearance.secondaryForeground));
                minimum =
                    math.min(minimum, contrast(color, appearance.foreground));
              }
            }
            expect(minimum, greaterThanOrEqualTo(4.5),
                reason: '$brightness / $role / background $background');
            image.dispose();
          });
          await tester.pumpWidget(scene(labels: true));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final png =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            final directory = Directory('build/glass-review')
              ..createSync(recursive: true);
            await File(
                    '${directory.path}/${brightness.name}-${role.name}-$background.png')
                .writeAsBytes(png.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
  });
}

class _Backdrop extends CustomPainter {
  const _Backdrop(this.kind);
  final int kind;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (kind < 3) {
      canvas.drawRect(
          rect,
          Paint()
            ..color =
                [Colors.white, Colors.black, const Color(0xFF808080)][kind]);
    } else if (kind == 3) {
      canvas.drawRect(
          rect,
          Paint()
            ..shader = const LinearGradient(colors: [
              Colors.red,
              Colors.blue,
              Colors.green,
              Colors.yellow
            ]).createShader(rect));
    } else {
      canvas.drawRect(rect, Paint()..color = Colors.white);
      for (var y = 0; y < size.height; y += 16) {
        for (var x = 0; x < size.width; x += 16) {
          if (kind == 4 && (x ~/ 16 + y ~/ 16).isEven) {
            canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 16, 16),
                Paint()..color = Colors.black);
          } else if (kind == 5) {
            final text = TextPainter(
                text: const TextSpan(
                    text: 'Ab',
                    style: TextStyle(color: Colors.black, fontSize: 12)),
                textDirection: TextDirection.ltr)
              ..layout();
            text.paint(canvas, Offset(x.toDouble(), y.toDouble()));
            text.dispose();
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Backdrop oldDelegate) => oldDelegate.kind != kind;
}
