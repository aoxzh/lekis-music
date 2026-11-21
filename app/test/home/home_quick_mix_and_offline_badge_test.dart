import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/home/home_page.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('HomeQuickMixStrip', () {
    testWidgets('only shows real-data capsules and fires actions', (
      tester,
    ) async {
      var shuffled = 0;
      var loved = 0;
      var most = 0;
      String? genrePlayed;

      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: HomeQuickMixStrip(
              gutter: 16,
              hasTracks: true,
              lovedCount: 0,
              hasMostPlayed: true,
              genres: const [
                GenreCountDto(name: 'Jazz', trackCount: 18),
                GenreCountDto(name: '   ', trackCount: 5),
                GenreCountDto(name: 'Ambient', trackCount: 0),
              ],
              onShuffleLibrary: () => shuffled++,
              onPlayLoved: () => loved++,
              onPlayMostPlayed: () => most++,
              onPlayGenre: (g) => genrePlayed = g,
            ),
          ),
        ),
      );

      expect(find.text('随机漫游'), findsOneWidget);
      expect(find.text('我的喜欢'), findsNothing);
      expect(find.text('常听精选'), findsOneWidget);
      expect(find.text('Jazz'), findsOneWidget);
      expect(find.text('Ambient'), findsNothing);

      await tester.tap(find.text('随机漫游'));
      await tester.tap(find.text('常听精选'));
      await tester.tap(find.text('Jazz'));
      expect(shuffled, 1);
      expect(loved, 0);
      expect(most, 1);
      expect(genrePlayed, 'Jazz');
    });

    testWidgets('shows 我的喜欢 when lovedCount > 0', (tester) async {
      var loved = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: HomeQuickMixStrip(
              gutter: 16,
              hasTracks: true,
              lovedCount: 3,
              hasMostPlayed: false,
              genres: const [],
              onShuffleLibrary: () {},
              onPlayLoved: () => loved++,
              onPlayMostPlayed: () {},
              onPlayGenre: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('我的喜欢'), findsOneWidget);
      expect(find.text('常听精选'), findsNothing);
      await tester.tap(find.text('我的喜欢'));
      expect(loved, 1);
    });
  });

  group('CompactDownloadProgress (OFF-01)', () {
    testWidgets('shows offline pin icon when track is ready', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadStateProvider(42).overrideWithValue(OfflineStateDto.ready),
          ],
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const Scaffold(body: CompactDownloadProgress(trackId: 42)),
          ),
        ),
      );

      expect(
        find.byKey(CompactDownloadProgress.downloadedIconKey),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
      'shows progress ring when downloading and nothing when absent',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              downloadStateProvider(7)
                  .overrideWithValue(OfflineStateDto.downloading),
              downloadProgressProvider(7).overrideWithValue(0.5),
              downloadStateProvider(8).overrideWithValue(null),
            ],
            child: MaterialApp(
              theme: lekisDarkTheme(),
              home: const Scaffold(
                body: Row(
                  children: [
                    CompactDownloadProgress(trackId: 7),
                    CompactDownloadProgress(trackId: 8),
                  ],
                ),
              ),
            ),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.byKey(CompactDownloadProgress.downloadedIconKey),
          findsNothing,
        );
      },
    );
  });
}
