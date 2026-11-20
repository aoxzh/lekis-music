// Now Playing layout guards (Fold5 inner screen, ~829×690 dp landscape):
// * lyrics / queue toggles exist once, in the row under the transport
//   (Apple Music style), not in the top bar;
// * the library actions stay on the title line (no five inline stars);
// * the title has an “artist · album” line;
// * the grabber is centred on the full width;
// * the controls column is capped and vertically centred against the cover;
// * an open lyrics pane without lyrics shows its centred empty state;
// * covers without artwork tint the page from the placeholder colours.

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

final _track = TrackDto(
  id: 7,
  uid: 'track-7',
  title: 'Lekis Stage Preview',
  artists: const ['月兔'],
  albumTitle: '夜航',
  durationMs: BigInt.from(60000),
  genres: const [],
  loved: false,
  playCount: 0,
);

ProviderContainer _container({NowPlayingPane pane = NowPlayingPane.cover}) {
  final container = ProviderContainer(
    overrides: [
      coreEventsProvider.overrideWith((ref) => const Stream.empty()),
      playbackProvider.overrideWith(_FakePlayback.new),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => _track),
      currentArtworkProvider.overrideWith((ref) async => null),
      downloadStateProvider.overrideWith((ref, id) => null),
      downloadProgressProvider.overrideWith((ref, id) => null),
      lyricsProvider.overrideWith((ref, id) async => null),
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

    // Artist · album line.
    expect(find.text('月兔 · 夜航'), findsOneWidget);

    // Grabber centred on the full width.
    final grabber = tester.getCenter(
      find.byKey(const ValueKey('now-playing.top-bar.grabber')),
    );
    expect(grabber.dx, closeTo(829 / 2, 0.5));

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

  test('missing artwork tints from the placeholder colours', () async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(currentTrackProvider.future);
    await container.read(currentArtworkProvider.future);

    final palette = container.read(nowPlayingPaletteProvider(Brightness.dark));
    expect(palette, isNotNull);
    final (start, _) = placeholderGradientColors(
      _track.id.hashCode,
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
