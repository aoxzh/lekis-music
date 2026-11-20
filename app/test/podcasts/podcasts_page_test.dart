import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/podcasts/podcast_detail_page.dart';
import 'package:lekis/src/features/podcasts/podcast_providers.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/features/podcasts/podcasts_page.dart';
import 'package:lekis/src/features/podcasts/widgets/podcast_widgets.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

PodcastDto _podcast(int id, String title, {bool subscribed = true}) =>
    PodcastDto(
      id: id,
      feedUrl: 'https://example.test/$id.xml',
      title: title,
      author: '作者 $id',
      categories: const ['Technology'],
      subscribed: subscribed,
      episodeCount: 2,
      unplayedCount: 1,
      latestPublishedAt: DateTime(2025, 6, 11).millisecondsSinceEpoch,
    );

PodcastEpisodeDto _episode(
  int id,
  String title, {
  int position = 0,
  bool played = false,
}) => PodcastEpisodeDto(
  id: id,
  trackId: -(1 << 40) - id,
  podcastId: 1,
  podcastTitle: '节目一',
  title: title,
  audioUrl: 'https://example.test/$id.mp3',
  durationMs: BigInt.from(3600000),
  publishedAt: DateTime(2025, 6, 10).millisecondsSinceEpoch,
  positionMs: BigInt.from(position),
  played: played,
);

class _FakeApi implements PodcastApi {
  _FakeApi({this.subs = const [], this.progress = const []});

  List<PodcastDto> subs;
  List<PodcastEpisodeDto> progress;
  final calls = <String>[];
  final List<PodcastEpisodeDto> episodeList = [
    _episode(1, '第一集', position: 600000),
    _episode(2, '第二集', played: true),
  ];

  @override
  Future<List<DirectoryPodcastDto>> top(String country, int? genreId) async {
    calls.add('top:$country:$genreId');
    return [
      DirectoryPodcastDto(
        itunesId: 1,
        title: '榜首节目',
        author: '某电台',
        genre: '科技',
        subscribed: false,
      ),
      const DirectoryPodcastDto(title: '第二名', subscribed: true),
    ];
  }

  @override
  Future<List<DirectoryPodcastDto>> search(String term, String country) async {
    calls.add('search:$term:$country');
    return [
      DirectoryPodcastDto(itunesId: 9, title: '搜到的$term', subscribed: false),
    ];
  }

  @override
  Future<PodcastDto> openDirectory(DirectoryPodcastDto podcast) async {
    calls.add('open:${podcast.itunesId}');
    return _podcast(1, podcast.title, subscribed: false);
  }

  @override
  Future<PodcastDto> openFeed(String address) async =>
      _podcast(1, address, subscribed: false);

  @override
  Future<PodcastDto> get(int id) async => subs.firstWhere(
    (p) => p.id == id,
    orElse: () => _podcast(id, '节目一', subscribed: false),
  );

  @override
  Future<PodcastDto> refresh(int id) => get(id);

  @override
  Future<PodcastRefreshReportDto> refreshAll() async =>
      const PodcastRefreshReportDto(refreshed: 1, failed: 0, newEpisodes: 0);

  @override
  Future<void> setSubscribed(int id, bool subscribed) async {
    calls.add('subscribe:$id:$subscribed');
    subs = subscribed ? [_podcast(id, '节目一')] : [];
  }

  @override
  Future<List<PodcastDto>> subscriptions() async => subs;

  @override
  Future<List<PodcastEpisodeDto>> episodes(
    int id,
    int offset,
    int limit,
  ) async => offset == 0 ? episodeList : const [];

  @override
  Future<List<PodcastEpisodeDto>> latest(int limit) async =>
      subs.isEmpty ? const [] : episodeList;

  @override
  Future<List<PodcastEpisodeDto>> inProgress(int limit) async => progress;

  @override
  Future<void> setPlayed(int episodeId, bool played) async =>
      calls.add('played:$episodeId:$played');

  @override
  Future<void> markAllPlayed(int podcastId) async {}

  @override
  Future<void> play(List<PodcastEpisodeDto> episodes, int start) async =>
      calls.add('play:${episodes[start].id}');

  @override
  Future<OpmlImportReportDto> importOpml(String text) async =>
      const OpmlImportReportDto(
        total: 0,
        added: 0,
        alreadySubscribed: 0,
        failed: 0,
      );

  @override
  Future<String> exportOpml() async => '';

  @override
  Future<String?> loadRegion() async => 'JP';

  @override
  Future<void> saveRegion(String region) async => calls.add('region:$region');
}

Widget _app(_FakeApi api, {Widget? home, int? playing}) => ProviderScope(
  overrides: [
    podcastApiProvider.overrideWithValue(api),
    podcastNowPlayingTrackIdProvider.overrideWithValue(playing),
  ],
  child: MaterialApp(
    theme: lekisDarkTheme(),
    home: home ?? const PodcastsPage(),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  test('helpers format durations, dates and default region', () {
    expect(formatEpisodeDuration(45 * 60000), '45 分钟');
    expect(formatEpisodeDuration(65 * 60000), '1 小时 5 分');
    expect(formatEpisodeDuration(30000), '30 秒');
    final now = DateTime(2026, 11, 20, 12);
    expect(
      formatEpisodeDate(
        DateTime(2026, 11, 20, 1).millisecondsSinceEpoch,
        now: now,
      ),
      '今天',
    );
    expect(
      formatEpisodeDate(
        DateTime(2026, 11, 19).millisecondsSinceEpoch,
        now: now,
      ),
      '昨天',
    );
    expect(
      formatEpisodeDate(DateTime(2025, 1, 2).millisecondsSinceEpoch, now: now),
      '2025-01-02',
    );
    expect(defaultPodcastRegion('us'), 'US');
    expect(defaultPodcastRegion('ZZ'), 'CN');
  });

  testWidgets('empty subscriptions offer discover and OPML import', (
    tester,
  ) async {
    _phone(tester);
    final api = _FakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.text(PodcastStrings.subscriptionsEmpty), findsOneWidget);
    expect(find.text(PodcastStrings.importOpml), findsOneWidget);

    await tester.tap(find.text(PodcastStrings.goDiscover));
    await tester.pumpAndSettle();

    // Region is restored from settings, then the chart for it is shown.
    expect(api.calls, contains('top:JP:null'));
    expect(find.text('榜首节目'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '科技'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('top:JP:1318'));

    await tester.enterText(find.byType(TextField), '日谈');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.calls, contains('search:日谈:JP'));
    expect(find.text('搜到的日谈'), findsOneWidget);
    expect(find.text(PodcastStrings.searchResults), findsOneWidget);
  });

  testWidgets('subscriptions show continue listening and play episodes', (
    tester,
  ) async {
    _phone(tester);
    final api = _FakeApi(
      subs: [_podcast(1, '节目一')],
      progress: [_episode(1, '第一集', position: 600000)],
    );
    await tester.pumpWidget(_app(api, playing: -(1 << 40) - 1));
    await tester.pumpAndSettle();

    expect(find.text(PodcastStrings.continueListening), findsOneWidget);
    expect(find.text(PodcastStrings.mySubscriptions), findsOneWidget);
    expect(find.text('节目一'), findsOneWidget);
    expect(find.text('剩余 50 分钟'), findsWidgets);

    await tester.tap(find.text('第一集').first);
    await tester.pumpAndSettle();
    expect(api.calls, contains('play:1'));
  });

  testWidgets('detail page opens from the directory and subscribes', (
    tester,
  ) async {
    _phone(tester);
    final api = _FakeApi();
    await tester.pumpWidget(
      _app(
        api,
        home: const PodcastDetailPage(
          directory: DirectoryPodcastDto(
            itunesId: 7,
            title: '目录节目',
            subscribed: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.calls, contains('open:7'));
    expect(find.text('第一集'), findsOneWidget);
    expect(find.text('第二集'), findsOneWidget);
    expect(find.text(PodcastStrings.played), findsOneWidget);

    await tester.tap(find.text(PodcastStrings.subscribe));
    await tester.pumpAndSettle();
    expect(api.calls, contains('subscribe:1:true'));
    expect(find.text(PodcastStrings.subscribed), findsWidgets);

    await tester.tap(find.byTooltip(PodcastStrings.more).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(PodcastStrings.markUnplayed));
    await tester.pumpAndSettle();
    expect(api.calls, contains('played:2:false'));
  });
}
