import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/connect/connect_strings.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_strings.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/library/library_health_page.dart';
import 'package:lekis/src/features/library/library_health_providers.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/track_sources_sheet.dart';
import 'package:lekis/src/features/player/sleep_timer.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/features/sources/strings.dart';
import 'package:lekis/src/features/sync/sync_strings.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/destinations.dart';
import 'package:lekis/src/shell/tab_bar.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakeUnifiedGateway implements UnifiedLibraryGateway {
  int? mergedKeepId;
  List<int>? mergedAbsorbIds;
  final List<(int, String, bool)> deletedFiles = [];

  @override
  Future<int> mergeTracks(int keepId, List<int> absorbIds) async {
    mergedKeepId = keepId;
    mergedAbsorbIds = absorbIds;
    return absorbIds.length;
  }

  @override
  Future<int> splitTrackSource({
    required int trackId,
    required int sourceId,
    int? fileId,
    String? externalId,
  }) async => 999;

  @override
  Future<List<TrackSourceInfoDto>> trackSources(int trackId) async => const [];

  @override
  Future<bool> deleteDuplicateFile({
    required int sourceId,
    required String path,
    required bool deleteSourceFile,
  }) async {
    deletedFiles.add((sourceId, path, deleteSourceFile));
    return true;
  }
}

DuplicateTrackDto _dupTrack({
  required int trackId,
  required String path,
  required bool keep,
  required String format,
}) => DuplicateTrackDto(
  trackId: trackId,
  title: '晴天',
  artistLine: '周杰伦',
  albumTitle: '叶惠美',
  albumId: 1,
  durationMs: BigInt.from(269000),
  path: path,
  sizeBytes: BigInt.from(keep ? 32000000 : 8000000),
  format: format,
  codec: keep ? 'flac' : 'mp3',
  bitrateKbps: keep ? 960 : 320,
  bitDepth: keep ? 16 : null,
  sampleRate: 44100,
  qualityScore: keep ? 100 : 50,
  sourceId: 1,
  suggestedKeep: keep,
);

void main() {
  testWidgets('flat tab bar selection indicator uses concentric capsule radius', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: LekisTabBar(
              selected: LekisDestination.home,
              onSelected: (_) {},
              style: TabBarStyle.flat,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = tester.widget<Container>(
      find.byKey(LekisTabBar.selectionKey),
    );
    final box = container.decoration! as BoxDecoration;
    final rect = tester.getRect(find.byKey(LekisTabBar.selectionKey));
    final expectedRadius = BorderRadius.circular(
      (rect.width < rect.height ? rect.width : rect.height) / 2,
    );
    expect(box.borderRadius, expectedRadius);
    expect(box.boxShadow, isNull);
  });

  testWidgets(
    'duplicate group merges unmerged tracks and shows unified state for already-merged tracks',
    (tester) async {
      final gateway = _FakeUnifiedGateway();
      final unmergedGroup = DuplicateGroupDto(
        key: 'meta:qingtian',
        title: '晴天',
        artistLine: '周杰伦',
        albumTitle: '叶惠美',
        albumId: 1,
        keepTrackId: 10,
        tracks: [
          _dupTrack(
            trackId: 10,
            path: '/nas/qingtian.flac',
            keep: true,
            format: 'FLAC',
          ),
          _dupTrack(
            trackId: 11,
            path: '/local/qingtian.mp3',
            keep: false,
            format: 'MP3',
          ),
        ],
      );
      final alreadyMergedGroup = DuplicateGroupDto(
        key: 'meta:yequ',
        title: '夜曲',
        artistLine: '周杰伦',
        albumTitle: '十一月的萧邦',
        albumId: 2,
        keepTrackId: 20,
        tracks: [
          _dupTrack(
            trackId: 20,
            path: '/nas/yequ.flac',
            keep: true,
            format: 'FLAC',
          ),
          _dupTrack(
            trackId: 20,
            path: '/local/yequ.mp3',
            keep: false,
            format: 'MP3',
          ),
        ],
      );

      final paged = PagedList<DuplicateGroupDto>(
        pageSize: 20,
        maxCachedPages: 2,
        fetch: (_, _) async => [unmergedGroup, alreadyMergedGroup],
        count: () async => 2,
      );
      addTearDown(paged.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unifiedLibraryGatewayProvider.overrideWithValue(gateway),
            libraryHealthSummaryProvider.overrideWith(
              (_) async => LibraryHealthSummaryDto(
                totalTracks: BigInt.from(2),
                duplicateGroups: BigInt.from(2),
                missingCover: BigInt.zero,
                missingLyrics: BigInt.zero,
                missingTags: BigInt.zero,
                fakeLossless: BigInt.zero,
                unreadableFiles: BigInt.zero,
              ),
            ),
            duplicateGroupListProvider.overrideWithValue(paged),
          ],
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const LibraryHealthPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand unmerged group -> has working merge button
      await tester.tap(find.text('晴天'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duplicate.merge.10')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('duplicate.merge.10')));
      await tester.pumpAndSettle();
      expect(gateway.mergedKeepId, 10);
      expect(gateway.mergedAbsorbIds, [11]);

      // Expand already-unified group -> shows Sources & Quality AND Delete Lower-Quality button
      await tester.tap(find.text('夜曲'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duplicate.merge.20')), findsNothing);
      expect(find.byKey(const ValueKey('duplicate.sources.20')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('duplicate.delete-lower.20')),
        findsOneWidget,
      );

      // Tap Delete Lower-Quality -> confirmation dialog -> confirms disk deletion of the MP3 copy
      await tester.ensureVisible(
        find.byKey(const ValueKey('duplicate.delete-lower.20')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('duplicate.delete-lower.20')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duplicate.delete-disk-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('duplicate.delete-confirm')));
      await tester.pumpAndSettle();
      expect(gateway.deletedFiles, [(1, '/local/yequ.mp3', true)]);
    },
  );

  testWidgets('showEnrichScopeDialog lets user choose Artwork Only', (
    tester,
  ) async {
    EnrichScope? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showEnrichScopeDialog(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(EnrichScope.all.label), findsOneWidget);
    expect(find.text(EnrichScope.artwork.label), findsOneWidget);
    expect(find.text(EnrichScope.lyrics.label), findsOneWidget);

    await tester.tap(find.text(EnrichScope.artwork.label));
    await tester.pumpAndSettle();
    expect(picked, EnrichScope.artwork);
  });

  testWidgets('LekisLocale translates all major string tables into English', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: LekisLocale(
          locale: const Locale('en', 'US'),
          child: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: [
                  Text(SettingsStrings.appearance),
                  Text(SyncStrings.title),
                  Text(ConnectStrings.title),
                  Text(DesktopLyricsStrings.title),
                  Text(SourcesStrings.addSource),
                  Text(PodcastStrings.tabDiscover),
                  Text(UnifiedStrings.mergeAction),
                  Text(EnrichScope.artwork.label),
                  Text(SleepTimerKind.endOfTrack.label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Multi-Device Sync'), findsOneWidget);
    expect(find.text('Play on Other Devices'), findsOneWidget);
    expect(find.text('Desktop Floating Lyrics'), findsOneWidget);
    expect(find.text('Add Source'), findsOneWidget);
    expect(find.text('Discover'), findsOneWidget);
    expect(find.text('Merge as Same Track'), findsOneWidget);
    expect(find.text('Artwork Only'), findsOneWidget);
    expect(find.text('End of Track'), findsOneWidget);
  });
}
