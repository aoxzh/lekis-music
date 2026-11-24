import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/playlists/playlist_detail_page.dart';
import 'package:lekis/src/features/playlists/playlist_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('scoped playlist keeps order and duplicate matching entries', () async {
    const playlist = PlaylistDto(
      id: 8,
      uid: 'mixed',
      name: 'Mixed',
      kind: PlaylistKindDto.static_,
      trackCount: 4,
      createdAt: 0,
      updatedAt: 0,
    );
    final rows = [
      for (final id in [3, 2, 1, 3])
        TrackRowDto(
          id: id,
          title: '$id',
          artistLine: '',
          durationMs: BigInt.zero,
          loved: false,
          isLocal: true,
        ),
    ];
    final container = ProviderContainer.test(
      overrides: [
        playlistProvider(8).overrideWith((ref) async => playlist),
        playlistEntriesProvider(8).overrideWith(
          (ref) async => [
            for (final (index, row) in rows.indexed)
              PlaylistEntryDto(
                trackUid: '${row.id}',
                positionKey: '$index',
                addedAt: 0,
                track: row,
              ),
          ],
        ),
        playlistSourceFilterProvider.overrideWithValue(({
          required scope,
          required trackIds,
        }) async {
          expect(trackIds.map((id) => id.toInt()), [3, 2, 1, 3]);
          return Int64List.fromList(
            scope == const TrackSourceScopeDto.local() ? [1, 3] : [2],
          );
        }),
      ],
    );
    for (final (scope, ids) in [
      (const LibraryScope.local(), [3, 1, 3]),
      (const LibraryScope.nas(), [2]),
    ]) {
      final list = await container.read(
        scopedPlaylistTracksProvider((scope: scope, playlistId: 8)).future,
      );
      expect(list.map((row) => row.id), ids);
    }
  });

  testWidgets(
    'selecting filtered entries preserves selections outside the filter',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const playlist = PlaylistDto(
        id: 1,
        uid: 'playlist',
        name: 'Library mix',
        kind: PlaylistKindDto.static_,
        trackCount: 8,
        createdAt: 0,
        updatedAt: 0,
      );
      final entries = List.generate(
        8,
        (index) => PlaylistEntryDto(
          trackUid: index < 2 ? 'repeat' : 'track-$index',
          positionKey: 'pos-$index',
          addedAt: 0,
          track: TrackRowDto(
            id: index < 2 ? 0 : index,
            title: index < 2 ? 'Repeated' : 'Other $index',
            artistLine: 'Artist',
            durationMs: BigInt.zero,
            loved: false,
            isLocal: true,
          ),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistProvider(1).overrideWith((ref) async => playlist),
            playlistsProvider.overrideWith((ref) async => [playlist]),
            playlistEntriesProvider(1).overrideWith((ref) async => entries),
          ],
          child: LekisLocale(
            locale: const Locale('en'),
            child: MaterialApp(
              theme: lekisLightTheme(),
              home: const PlaylistDetailPage(playlistId: 1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Other 2'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      final filter = find.byType(TextField);
      await tester.enterText(filter, 'Repeated');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all 2 listed entries'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Deselect 2 listed entries'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.enterText(filter, 'no match');
      await tester.pumpAndSettle();
      final selectAll = find.ancestor(
        of: find.byIcon(Icons.select_all_rounded),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(selectAll).onPressed, isNull);
      await tester.enterText(filter, '');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all 8 listed entries'));
      await tester.pumpAndSettle();
      expect(find.text('8 selected'), findsOneWidget);
    },
  );
}
