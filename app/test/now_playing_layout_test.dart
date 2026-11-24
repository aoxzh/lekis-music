// Now Playing layout guards (Fold5 inner screen, ~829×690 dp landscape):
// * lyrics / queue toggles exist once, in the row under the transport
//   (Apple Music style), not in the top bar;
// * the library actions stay on the title line (no five inline stars);
// * the title has a tappable “artist · album” line (links to both pages);
// * the queue toggle carries no count badge;
// * the only swipe-down hint is the leading chevron (no centred grabber);
// * the controls column is capped and vertically centred against the cover;
// * an open lyrics pane without lyrics shows its centred empty state;
// * covers without artwork tint the page from the placeholder colours.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 7,
    durationMs: 60000,
    queueLength: 1,
    queueIndex: 0,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 0;
}

TrackDto _track(String uid) => TrackDto(
  id: 7,
  uid: uid,
  title: 'Lekis Stage Preview',
  artists: const ['月兔'],
  albumId: 3,
  albumTitle: '夜航',
  durationMs: BigInt.from(60000),
  genres: const [],
  loved: false,
  playCount: 0,
  isLocal: false,
);

ProviderContainer _container({
  NowPlayingPane pane = NowPlayingPane.cover,
  LyricsDto? lyrics,
  String uid = 'track-7',
}) {
  final container = ProviderContainer(
    overrides: [
      coreEventSourceProvider.overrideWithValue(const Stream.empty()),
      playbackProvider.overrideWith(_FakePlayback.new),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => _track(uid)),
      currentArtworkProvider.overrideWith((ref) async => null),
      downloadStateProvider.overrideWith((ref, id) => null),
      downloadProgressProvider.overrideWith((ref, id) => null),
      lyricsProvider.overrideWith(
        (ref, id) async => lyrics == null ? null : ParsedLyrics.parse(lyrics),
      ),
    ],
  );
  container.read(nowPlayingPaneProvider.notifier).set(pane);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(829, 690);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const NowPlayingPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Bilibili track opens its official video from Now Playing', (
    tester,
  ) async {
    const channel = MethodChannel('dev.lekis/bilibili_video');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final container = _container(uid: 'plugin:dev.mygo.bilibili:BV1GJ411x7h7');
    addTearDown(container.dispose);
    await _pump(tester, container);
    await tester.tap(find.byKey(const ValueKey('now-playing.more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.ondemand_video_rounded));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'open');
    expect(calls.single.arguments, {'bvid': 'BV1GJ411x7h7', 'page': 1});
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('cover | controls: single toggles, compact actions, subtitle', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pump(tester, container);

    // Lyrics / queue exist once, in the bottom row under the transport.
    expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
    final transport = tester.getRect(find.byType(TransportControls));
    for (final key in const [
      NowPlayingActions.lyricsKey,
      NowPlayingActions.wallKey,
      NowPlayingActions.queueKey,
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.top, greaterThanOrEqualTo(transport.bottom));
      expect(
        find.descendant(
          of: find.byType(NowPlayingControls),
          matching: find.byKey(key),
        ),
        findsOneWidget,
      );
    }

    // At most one rating star, not five; on this narrow column rating lives
    // in the “more” menu next to download / add to playlist.
    expect(find.byIcon(Icons.star_border_rounded), findsNothing);
    expect(find.byKey(const ValueKey('now-playing.more')), findsOneWidget);

    // Actions sit on the title line.
    final title = tester.getRect(
      find.byKey(const ValueKey('now-playing.title')),
    );
    final actions = tester.getRect(
      find.byKey(const ValueKey('now-playing.library-actions')),
    );
    expect(actions.center.dy, closeTo(title.center.dy, title.height / 2));
    expect(actions.left, greaterThanOrEqualTo(title.right));

    // Artist · album line: two links, separated by “ · ”.
    final subtitle = find.byKey(const ValueKey('now-playing.subtitle'));
    expect(
      find.descendant(of: subtitle, matching: find.text('月兔')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: subtitle, matching: find.text('夜航')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: subtitle, matching: find.byType(InkWell)),
      findsNWidgets(2),
    );

    // No count badge on the queue toggle (it read as a sticker on the cover).
    expect(
      find.descendant(
        of: find.byKey(NowPlayingActions.queueKey),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );

    // One swipe-down hint only: the leading chevron. No centred grabber pill
    // (it duplicated the chevron and collided with Samsung's top-centre
    // multi-window handle).
    expect(
      find.byKey(const ValueKey('now-playing.top-bar.grabber')),
      findsNothing,
    );
    final close = tester.getRect(
      find.byKey(const ValueKey('now-playing.top-bar.close')),
    );
    expect(close.left, lessThan(829 / 4));

    // Controls: capped width, vertically centred against the cover.
    final controls = tester.getRect(find.byType(NowPlayingControls));
    expect(controls.width, lessThanOrEqualTo(nowPlayingControlsMaxWidth));
    final cover = tester.getRect(find.byType(NowPlayingArtwork));
    expect(controls.center.dy, closeTo(cover.center.dy, 1));

    await tester.tap(find.byKey(const ValueKey('now-playing.more')));
    await tester.pumpAndSettle();
    expect(find.text('评分'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('添加到歌单'), findsOneWidget);
    // The lyrics editor lives here, not as a floating button over the lyrics.
    expect(find.text('编辑歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide portrait column keeps one inline rating star', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const NowPlayingPage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
    expect(
      tester.getSize(find.byType(NowPlayingControls)).width,
      lessThanOrEqualTo(nowPlayingControlsMaxWidth),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics pane without lyrics shows a centred empty state', (
    tester,
  ) async {
    final container = _container(pane: NowPlayingPane.lyrics);
    addTearDown(container.dispose);
    await _pump(tester, container);

    // Toggles still appear once with lyrics open.
    expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);

    final empty = find.text('暂无歌词');
    expect(empty, findsOneWidget);
    // Right-hand pane: horizontally in its middle (the split is at 45%).
    final center = tester.getCenter(empty);
    final paneLeft = 829 * 0.45;
    expect(center.dx, closeTo(paneLeft + (829 - paneLeft) / 2, 1));
    expect(tester.takeException(), isNull);
  });

  // Known issue from 0.1.0-alpha.1: with this track paused the lyrics pane
  // came up blank. Paused (the fixture state) must still show the lines.
  testWidgets('lyrics pane shows synced lines while paused', (tester) async {
    final container = _container(
      pane: NowPlayingPane.lyrics,
      lyrics: const LyricsDto(
        format: LyricsFormatDto.lrc,
        content: '[00:00.00]第一行歌词\n[00:05.00]第二行歌词\n[00:10.00]第三行歌词',
        source: 'test',
        offsetMs: 0,
        confidence: 1,
      ),
    );
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('暂无歌词'), findsNothing);
    expect(find.text('第一行歌词'), findsWidgets);
    expect(find.text('第二行歌词'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('missing artwork tints from the placeholder colours', () async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(currentTrackProvider.future);
    await container.read(currentArtworkProvider.future);

    final palette = container.read(nowPlayingPaletteProvider(Brightness.dark));
    expect(palette, isNotNull);
    final (start, _) = placeholderGradientColors(
      container.read(currentTrackProvider).requireValue!.id.hashCode,
      Brightness.dark,
    );
    expect(palette!.primary, start.toARGB32() & 0xFFFFFF);

    final tint = NowPlayingTint.resolve(palette, lekisDarkTheme().colorScheme);
    // Same hue family as the placeholder, not the brand accent.
    expect(
      HSLColor.fromColor(tint.primary).hue,
      closeTo(HSLColor.fromColor(start).hue, 1),
    );
  });
}
