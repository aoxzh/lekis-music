// Density rules for Home shelves, the album grid and song rows.

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/home/home_page.dart' show greetingFor;
import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Widget _shelf(int count) => MaterialApp(
  theme: lekisDarkTheme(),
  home: Scaffold(
    body: SingleChildScrollView(
      child: ArtworkShelf(
        title: 'Shelf',
        itemCount: count,
        itemBuilder: (_, i) => ColoredBox(
          key: ValueKey('card-$i'),
          color: const Color(0xFF000000),
        ),
      ),
    ),
  ),
);

void main() {
  test('shelf cards stay small and several fit per row', () {
    // Phone (~344 dp window) and Fold inner screen next to the rail.
    for (final available in [312.0, 717.0, 1288.0]) {
      final w = shelfCardWidth(available);
      expect(w, lessThanOrEqualTo(shelfCardMax));
      expect(w, greaterThanOrEqualTo(shelfCardMin * 0.85));
      expect(available / w, greaterThan(2));
    }
  });

  test('album grid gets more columns on wider windows', () {
    expect(albumGridColumns(312), 2);
    expect(albumGridColumns(717), 5);
    expect(albumGridColumns(1288), greaterThan(albumGridColumns(717)));
    for (final width in [312.0, 717.0, 1288.0]) {
      final cols = albumGridColumns(width);
      final cell = (width - LekisSpacing.lg * (cols - 1)) / cols;
      expect(cell, lessThanOrEqualTo(albumGridMaxExtent));
    }
  });

  test('song rows are 56 dp and still a full touch target', () {
    expect(TrackTile.extent, 56);
    expect(TrackTile.extent, greaterThanOrEqualTo(LekisSizes.touchTargetMin));
  });

  test('greeting follows the clock', () {
    expect(greetingFor(DateTime(2026, 1, 1, 8)), '早上好');
    expect(greetingFor(DateTime(2026, 1, 1, 13, 56)), '中午好');
    expect(greetingFor(DateTime(2026, 1, 1, 15)), '下午好');
    expect(greetingFor(DateTime(2026, 1, 1, 21)), '晚上好');
    expect(greetingFor(DateTime(2026, 1, 1, 2)), '夜深了');
  });

  testWidgets('shelf hides paging buttons when every card fits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(829, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_shelf(1));
    expect(find.byTooltip('下一页'), findsNothing);
    final card = tester.getSize(find.byKey(const ValueKey('card-0')));
    expect(card.width, lessThanOrEqualTo(shelfCardMax));

    await tester.pumpWidget(_shelf(30));
    expect(find.byTooltip('上一页'), findsOneWidget);
    expect(find.byTooltip('下一页'), findsOneWidget);
  });
}
