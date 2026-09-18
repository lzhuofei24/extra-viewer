import 'package:best_viewer/src/ui/browser_list.dart';
import 'package:best_viewer/src/ui/browser_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'text lists do not build artwork and rotate from one to three columns',
      (tester) async {
    var previews = 0;
    var style = BrowserListStyle.text;
    Future<void> show(Size size) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CustomScrollView(slivers: [
        BrowserListSliver(
            count: 3,
            style: style,
            padding: 8,
            itemBuilder: (_, i) => BrowserListTile(
                style: style,
                title: 'Item $i',
                subtitle: 'Details',
                onTap: () {},
                previewBuilder: (_) {
                  previews++;
                  return const ColoredBox(color: Colors.red);
                })),
      ]))));
      await tester.pump();
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(const Size(360, 800));
    expect(previews, 0);
    expect(tester.getTopLeft(find.text('Item 1')).dy,
        greaterThan(tester.getTopLeft(find.text('Item 0')).dy));
    expect(find.text('Item 0'), findsOneWidget);
    expect(find.text('Item 1'), findsOneWidget);
    await show(const Size(1000, 600));
    expect(tester.getTopLeft(find.text('Item 1')).dy,
        tester.getTopLeft(find.text('Item 0')).dy);
    expect(find.text('Item 0'), findsOneWidget);
    expect(find.text('Item 1'), findsOneWidget);
    style = BrowserListStyle.compact;
    await show(const Size(360, 800));
    expect(previews, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
