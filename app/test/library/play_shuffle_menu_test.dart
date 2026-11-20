// The album header's "more" menu: queue actions + enrich, and it only
// appears when there is something to act on.

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: lekisDarkTheme(),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  const menu = ValueKey('play-shuffle.queue-menu');

  testWidgets('no tracks: no more menu', (tester) async {
    await _pump(tester, PlayShuffleButtons(onPlay: () {}, onShuffle: () {}));
    expect(find.byKey(menu), findsNothing);
  });

  testWidgets('more menu offers queue actions and enrich', (tester) async {
    var enriched = 0;
    await _pump(
      tester,
      PlayShuffleButtons(
        onPlay: () {},
        onShuffle: () {},
        queueTrackIds: const [1, 2, 3],
        onEnrich: () => enriched++,
        trailing: const [Icon(Icons.download, key: ValueKey('trailing'))],
      ),
    );
    expect(find.byKey(const ValueKey('trailing')), findsOneWidget);

    await tester.tap(find.byKey(menu));
    await tester.pumpAndSettle();
    expect(find.text(QueueStrings.playNext), findsOneWidget);
    expect(find.text(QueueStrings.addToQueue), findsOneWidget);
    expect(find.text(EnrichActionStrings.action), findsOneWidget);

    await tester.tap(find.text(EnrichActionStrings.action));
    await tester.pumpAndSettle();
    expect(enriched, 1);
  });

  test('enrich result text', () {
    expect(QueueStrings.done(QueuePlacement.next, 1), '已设为下一首播放');
    expect(QueueStrings.done(QueuePlacement.end, 12), '已加入播放队列 12 首');
  });
}
