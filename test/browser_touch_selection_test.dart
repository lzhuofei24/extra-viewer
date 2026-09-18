import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:best_viewer/src/core/domain/models.dart';
import 'package:best_viewer/src/ui/browser_entity_sliver.dart';

void main() {
  testWidgets('touch jitter toggles once while real dragging selects',
      (tester) async {
    const entity = EntityListItem(
        id: 'a',
        title: 'a',
        entityType: EntityType.image,
        path: '/a.jpg',
        format: 'jpg',
        size: 1,
        modifiedAtMs: 1);
    var selected = false;
    var taps = 0, drags = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BrowserScrollShell(
      warmupEnabled: false,
      preloadScopeKey: 'test',
      entities: const [entity],
      hasMore: false,
      onLoadMore: () {},
      selectionMode: true,
      onSelectEntitiesByDrag: (_) {
        drags++;
        selected = true;
      },
      child: (_, registry) => Center(
          child: GestureDetector(
        key: registry.keyFor(entity),
        onTap: () {
          taps++;
          selected = !selected;
        },
        child: const SizedBox(
            width: 200, height: 200, child: ColoredBox(color: Colors.blue)),
      )),
    ))));
    final point = tester.getCenter(find.byType(GestureDetector).last);
    for (final expected in [true, false]) {
      final gesture = await tester.startGesture(point);
      await gesture.moveBy(const Offset(2, 1));
      await gesture.up();
      await tester.pump();
      expect(selected, expected);
      expect(drags, 0);
    }
    expect(taps, 2);
    final drag = await tester.startGesture(point);
    await drag.moveBy(const Offset(50, 0));
    await drag.up();
    await tester.pump();
    expect(selected, isTrue);
    expect(drags, 1);
    expect(taps, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
