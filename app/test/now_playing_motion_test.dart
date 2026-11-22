// Now Playing motion / visual regression guards:
// * adaptive cover tint stays readable;
// * the low-power background is a still frame, not a repeating animation;
// * the artwork exposes play / skip semantics and responds to swipes;
// * a track change keeps an outgoing and an incoming cover during the slide;
// * the mini player is the floating 12 dp / 8 dp card from the reference.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_background.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 0,
  );
}

class _MutablePlayback extends PlaybackController {
  int? trackId = 1;
  int? queueIndex = 0;

  @override
  PlaybackUiState build() => PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: trackId,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: queueIndex,
  );

  void moveTo(int id, {int? index}) {
    trackId = id;
    queueIndex = index ?? queueIndex;
    state = state.copyWith(
      trackId: () => trackId,
      queueIndex: queueIndex == null ? null : () => queueIndex,
    );
  }
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

class _FakeActions extends PlayerActions {
  _FakeActions(super.ref);

  int nexts = 0;
  int previouses = 0;
  int toggles = 0;

  @override
  void next() => nexts++;

  @override
  void previous() => previouses++;

  @override
  void playPause() => toggles++;
}

TrackDto _track(int id) => TrackDto(
  id: id,
  uid: 'track-$id',
  title: '曲目 $id',
  artists: const ['月兔'],
  durationMs: BigInt.from(240000),
  genres: const [],
  loved: false,
  playCount: 0,
  isLocal: false,
);

PaletteDto _palette(int primary, int secondary, int onPrimary) => PaletteDto(
  primary: primary,
  secondary: secondary,
  onPrimary: onPrimary,
  gradient: Uint32List.fromList([primary, secondary, 0x223344, 0xFFFFFF]),
);

(ProviderContainer, _FakeActions) _container({
  PlaybackController Function()? playback,
}) {
  late _FakeActions actions;
  final container = ProviderContainer(
    overrides: [
      coreEventSourceProvider.overrideWithValue(const Stream.empty()),
      playbackProvider.overrideWith(playback ?? _FakePlayback.new),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => null),
      currentArtworkProvider.overrideWith((ref) async => null),
      playerActionsProvider.overrideWith((ref) => actions = _FakeActions(ref)),
    ],
  );
  container.read(playerActionsProvider);
  return (container, actions);
}

Widget _host(
  ProviderContainer container,
  Widget child, {
  bool reduceMotion = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: lekisDarkTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
}

void main() {
  test('adaptive tint keeps foreground and accent contrast', () {
    final scheme = lekisDarkTheme().colorScheme;

    for (final palette in [
      _palette(0x101018, 0x222233, 0xFFFFFF), // dark cover
      _palette(0xF2C46B, 0x6E5BF0, 0xFF4B12), // bright cover
    ]) {
      final tint = NowPlayingTint.resolve(palette, scheme);
      expect(
        contrastRatio(tint.foreground, tint.scene),
        greaterThanOrEqualTo(7),
      );
      expect(contrastRatio(tint.primary, tint.scene), greaterThanOrEqualTo(3));
      expect(
        contrastRatio(tint.onPrimary, tint.primary),
        greaterThanOrEqualTo(4.5),
      );
    }

    final fallback = NowPlayingTint.resolve(null, scheme);
    expect(fallback.foreground, scheme.onSurface);
  });

  testWidgets('low-power background settles into a still frame', (
    tester,
  ) async {
    final (container, _) = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _host(container, const NowPlayingBackground(lowPower: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NowPlayingBackground), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('animated background keeps a ticker running', (tester) async {
    final (container, _) = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _host(container, const NowPlayingBackground(lowPower: false)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artwork exposes semantics and swipes between tracks', (
    tester,
  ) async {
    final (container, actions) = _container();
    addTearDown(container.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _host(
        container,
        const Center(
          child: SizedBox.square(dimension: 320, child: NowPlayingArtwork()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.byKey(const ValueKey('now-playing.artwork')),
    );
    expect(node.label, contains('封面'));
    expect(node.getSemanticsData().customSemanticsActionIds, hasLength(3));

    await tester.tap(find.byKey(const ValueKey('now-playing.artwork')));
    await tester.pump();
    expect(actions.toggles, 1);

    await tester.drag(
      find.byKey(const ValueKey('now-playing.artwork')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    expect(actions.nexts, 1);

    await tester.drag(
      find.byKey(const ValueKey('now-playing.artwork')),
      const Offset(180, 0),
    );
    await tester.pumpAndSettle();
    expect(actions.previouses, 1);

    semantics.dispose();
  });

  testWidgets('track change slides the old cover out and the new one in', (
    tester,
  ) async {
    final playback = _MutablePlayback();
    final container = ProviderContainer(
      overrides: [
        coreEventSourceProvider.overrideWithValue(const Stream.empty()),
        playbackProvider.overrideWith(() => playback),
        positionProvider.overrideWith(_FakePosition.new),
        currentTrackProvider.overrideWith((ref) async {
          final id = ref.watch(playbackProvider.select((s) => s.trackId));
          return id == null ? null : _track(id);
        }),
        currentArtworkProvider.overrideWith((ref) async => null),
        playerActionsProvider.overrideWith((ref) => _FakeActions(ref)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _host(
        container,
        const Center(
          child: SizedBox.square(dimension: 320, child: NowPlayingArtwork()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ArtworkImage), findsOneWidget);

    playback.moveTo(2, index: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ArtworkImage), findsNWidgets(2));

    await tester.pumpAndSettle();
    expect(find.byType(ArtworkImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion skips the swipe spring', (tester) async {
    final (container, actions) = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _host(
        container,
        const Center(
          child: SizedBox.square(dimension: 320, child: NowPlayingArtwork()),
        ),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('now-playing.artwork')),
      const Offset(-180, 0),
    );
    await tester.pump();
    expect(actions.nexts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape keeps the cover left of the controls', (tester) async {
    tester.view.physicalSize = const Size(1100, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (container, _) = _container();
    addTearDown(container.dispose);

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

    final artwork = tester.getCenter(find.byType(NowPlayingArtwork));
    final controls = tester.getCenter(find.byType(NowPlayingControls));
    expect(artwork.dx, lessThan(controls.dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mini player floats as a glass capsule with 8 dp margins', (
    tester,
  ) async {
    final (container, actions) = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _host(
        container,
        const Align(alignment: Alignment.bottomCenter, child: MiniPlayer()),
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('mini-player.card'));
    final rect = tester.getRect(card);
    expect(rect.left, LekisSizes.miniPlayerMargin);
    expect(rect.right, 800 - LekisSizes.miniPlayerMargin);
    expect(rect.bottom, 600 - LekisSizes.miniPlayerMargin);
    expect(rect.height, LekisSizes.miniPlayerHeight);

    // Same capsule material as the tab bar (liquid glass by default).
    final capsule = tester.widget<LekisGlassCapsule>(card);
    expect(capsule.radius, LekisRadius.miniPlayer);
    expect(capsule.flat, isFalse);
    expect(
      find.descendant(of: card, matching: find.byType(LiquidGlass)),
      findsOneWidget,
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('mini-player.semantics')),
    );
    expect(node.label, contains('迷你播放器'));

    await tester.drag(card, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(actions.nexts, 1);
    expect(tester.takeException(), isNull);
  });
}
