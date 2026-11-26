import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

List<AlbumDto> _fakeAlbums(int count, {String? suffix}) => [
  for (var i = 0; i < count; i++)
    AlbumDto(
      id: i + 1,
      title: 'Album ${i + 1}${suffix ?? ''}',
      artistLine: 'Artist ${(i % 5) + 1}',
      year: 2020 + (i % 6),
      trackCount: 10,
    ),
];

void main() {
  testWidgets(
    'AlbumGrid keeps scroll position when PagedList refreshes in place',
    (tester) async {
      var version = 0;
      final list = PagedList<AlbumDto>(
        pageSize: 40,
        count: () async => 120,
        fetch: (offset, limit) async {
          final all = _fakeAlbums(120, suffix: version == 0 ? '' : ' [Updated]');
          if (offset >= all.length) return const [];
          return all.sublist(
            offset,
            (offset + limit).clamp(0, all.length),
          );
        },
      );
      addTearDown(list.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: LekisLocale(
            locale: const Locale('zh'),
            child: MaterialApp(
              theme: lekisLightTheme(),
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 700,
                  child: AlbumGrid(
                    list: list,
                    viewMode: AlbumViewMode.grid,
                    onOpen: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grid = find.byType(GridView);
      await tester.drag(grid, const Offset(0, -1200));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final offsetBefore = scrollable.position.pixels;
      expect(offsetBefore, greaterThan(400));

      // Simulate background catalog enrichment triggering in-place refresh.
      version = 1;
      list.refreshNow();
      await tester.pumpAndSettle();

      // Scroll position must stay right where the user scrolled (no jump up).
      expect(scrollable.position.pixels, closeTo(offsetBefore, 1.0));
      expect(find.textContaining('[Updated]'), findsWidgets);
    },
  );

  testWidgets('AlbumGrid switches cleanly between grid, compactGrid and list', (
    tester,
  ) async {
    final albums = _fakeAlbums(30);
    final list = PagedList<AlbumDto>(
      pageSize: 30,
      count: () async => albums.length,
      fetch: (offset, limit) async => offset == 0 ? albums : const [],
    );
    addTearDown(list.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: LekisLocale(
          locale: const Locale('zh'),
          child: MaterialApp(
            theme: lekisLightTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 390,
                height: 700,
                child: AlbumGrid(list: list, onOpen: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlbumCard), findsWidgets);
    expect(find.byType(AlbumListTile), findsNothing);

    await container
        .read(albumViewModeProvider.notifier)
        .set(AlbumViewMode.compactGrid);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AlbumCard>(find.byType(AlbumCard).first).compact,
      isTrue,
    );

    await container.read(albumViewModeProvider.notifier).set(AlbumViewMode.list);
    await tester.pumpAndSettle();
    expect(find.byType(AlbumListTile), findsWidgets);
    expect(find.byType(AlbumCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
