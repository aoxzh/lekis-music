import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/now_playing/lyric_typography.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_style.dart';
import 'package:lekis/src/features/now_playing/now_playing_turntable.dart';
import 'package:lekis/src/features/now_playing/track_dial.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/settings_categories.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/settings/strings.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  void update(PlaybackStateDto playbackState, {int? duration}) =>
      state = state.copyWith(state: playbackState, durationMs: duration);

  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 7,
    durationMs: 227000,
    queueLength: 1,
    queueIndex: 0,
  );
}

class _FakePosition extends PositionController {
  void seek(int ms) => state = ms;

  @override
  int build() => 68000;
}

class _FixedStyle extends NowPlayingStyleNotifier {
  _FixedStyle(this.initial);
  final NowPlayingStyle initial;

  @override
  NowPlayingStyle build() => initial;
}

class _FixedSetting extends SettingNotifier {
  _FixedSetting(super.key, this.value);

  final String? value;

  @override
  Future<String?> build() async => value;
}

final _track = TrackDto(
  id: 7,
  uid: 'track-7',
  title: 'ターゲット〜赤い衝撃〜 (Target - Akai Shougeki)',
  artists: const ['和田光司'],
  albumId: 3,
  albumTitle: 'We Love DiGiMONMUSIC',
  durationMs: BigInt.from(227000),
  genres: const [],
  loved: true,
  playCount: 5,
  isLocal: false,
);

const _bilingualLyrics = LyricsDto(
  format: LyricsFormatDto.lrc,
  source: 'test',
  offsetMs: 0,
  confidence: 1.0,
  content: '[00:05.00]鼓動は胸を焦がしてる\n[00:05.00]躁动仿佛将心灼伤\n[01:08.00]忘れられた明日\n[01:08.00]已经遗忘了的明天\n',
);

ProviderContainer _container({
  NowPlayingPane pane = NowPlayingPane.lyrics,
  NowPlayingStyle style = NowPlayingStyle.cover,
}) {
  final container = ProviderContainer(
    overrides: [
      coreEventSourceProvider.overrideWithValue(const Stream.empty()),
      playbackProvider.overrideWith(_FakePlayback.new),
      positionProvider.overrideWith(_FakePosition.new),
      currentTrackProvider.overrideWith((ref) async => _track),
      currentArtworkProvider.overrideWith((ref) async => null),
      downloadStateProvider.overrideWith((ref, id) => null),
      downloadProgressProvider.overrideWith((ref, id) => null),
      nowPlayingStyleProvider.overrideWith(() => _FixedStyle(style)),
      lyricsProvider.overrideWith(
        (ref, id) async => ParsedLyrics.parse(_bilingualLyrics),
      ),
      settingProvider(
        SettingKeys.lyricsDialButton,
      ).overrideWith(() => _FixedSetting(SettingKeys.lyricsDialButton, 'true')),
    ],
  );
  container.read(nowPlayingPaneProvider.notifier).set(pane);
  return container;
}

Future<void> _pumpDesktop(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(1280, 820),
}) async {
  tester.view.physicalSize = size;
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
  for (final size in [const Size(360, 740), const Size(1024, 600)]) {
    testWidgets('select, seek and leave track dial at $size', (tester) async {
      final container = _container(
        pane: NowPlayingPane.cover,
        style: NowPlayingStyle.vinyl,
      );
      addTearDown(container.dispose);
      await _pumpDesktop(tester, container, size: size);
      expect(find.byType(VinylRecordArtwork), findsOneWidget);
      await tester.tap(find.text('曲目刻度'));
      await tester.pumpAndSettle();
      final dial = find.byType(TrackDial);
      expect(dial, findsOneWidget);
      expect(
        find.descendant(of: dial, matching: find.text('29%')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dial, matching: find.byIcon(Icons.pause_rounded)),
        findsOneWidget,
      );
      final position =
          container.read(positionProvider.notifier) as _FakePosition;
      final playback =
          container.read(playbackProvider.notifier) as _FakePlayback;
      playback.update(PlaybackStateDto.playing);
      position.seek(170250);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: dial, matching: find.text('75%')),
        findsOneWidget,
      );
      final face = find
          .descendant(of: dial, matching: find.byType(CustomPaint))
          .first;
      expect(
        tester.renderObject(face),
        paints
          ..arc(sweepAngle: math.pi * 1.5)
          ..arc(sweepAngle: math.pi * 1.5 * 0.75),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        find.descendant(
          of: dial,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      position.seek(0);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: dial, matching: find.text('0%')),
        findsOneWidget,
      );
      playback.update(PlaybackStateDto.buffering, duration: 0);
      await tester.pump();
      expect(
        find.descendant(of: dial, matching: find.text('—')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dial,
          matching: find.byIcon(Icons.hourglass_empty_rounded),
        ),
        findsOneWidget,
      );
      playback.update(PlaybackStateDto.paused);
      await tester.tap(find.text('返回封面'));
      await tester.pumpAndSettle();
      expect(dial, findsNothing);
      expect(find.byType(VinylRecordArtwork), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('very small dial keeps the cover at full size', (tester) async {
    const cover = SizedBox(key: ValueKey('tiny-cover'));
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 80,
              child: TrackDial(cover: cover),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byWidget(cover)), const Size.square(80));
    expect(
      find.descendant(
        of: find.byType(TrackDial),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
  });

  test('detectLyricLocale & lyricTextStyleFor split ja / zh / ko / latin', () {
    expect(detectLyricLocale('鼓動は胸を焦がしてる'), const Locale('ja'));
    expect(detectLyricLocale('ターゲット〜赤い衝撃〜'), const Locale('ja'));
    expect(detectLyricLocale('躁动仿佛将心灼伤'), const Locale('zh', 'CN'));
    expect(detectLyricLocale('사랑해요'), const Locale('ko'));
    expect(detectLyricLocale('Target Red Crash'), isNull);

    const base = TextStyle(fontSize: 28);
    final ja = lyricTextStyleFor('鼓動は胸を焦がしてる', base);
    final zh = lyricTextStyleFor('躁动仿佛将心灼伤', base);
    expect(ja.locale, const Locale('ja'));
    expect(zh.locale, const Locale('zh', 'CN'));
    expect(ja.fontFamilyFallback, isNotEmpty);
    expect(zh.fontFamilyFallback, isNotEmpty);
    expect(ja.fontFamilyFallback, isNot(equals(zh.fontFamilyFallback)));
  });

  testWidgets(
    'desktop 1280x820 with lyrics uses spacious 2-column stacked layout',
    (tester) async {
      final container = _container(pane: NowPlayingPane.lyrics);
      addTearDown(container.dispose);
      await _pumpDesktop(tester, container, size: const Size(1280, 820));

      final art = tester.getRect(find.byType(NowPlayingArtwork));
      final controls = tester.getRect(find.byType(NowPlayingControls));
      final lyrics = tester.getRect(find.byType(LyricsView));

      // Artwork sits above controls in the left column, not beside them.
      expect(art.bottom, lessThanOrEqualTo(controls.top + 1));
      // Lyrics occupy the generous right half (> 50% width).
      expect(lyrics.left, greaterThanOrEqualTo(controls.right - 24));
      expect(lyrics.width, greaterThan(640));
      // Controls keep full width instead of being squeezed into a narrow strip.
      expect(controls.width, greaterThan(400));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop 1024x600 with lyrics has zero overflow', (tester) async {
    final container = _container(pane: NowPlayingPane.lyrics);
    addTearDown(container.dispose);
    await _pumpDesktop(tester, container, size: const Size(1024, 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('NowPlayingStyle switches between vinyl and cassette visuals', (
    tester,
  ) async {
    final vinylContainer = _container(style: NowPlayingStyle.vinyl);
    addTearDown(vinylContainer.dispose);
    await _pumpDesktop(tester, vinylContainer);
    expect(find.byType(VinylRecordArtwork), findsOneWidget);
    expect(find.byType(CassetteArtwork), findsNothing);

    final cassetteContainer = _container(style: NowPlayingStyle.cassette);
    addTearDown(cassetteContainer.dispose);
    await _pumpDesktop(tester, cassetteContainer);
    expect(find.byType(CassetteArtwork), findsOneWidget);
    expect(find.byType(VinylRecordArtwork), findsNothing);
  });

  testWidgets('lyrics settings are merged inside Appearance category', (
    tester,
  ) async {
    UiProfile.debugOverride = UiProfile.desktop;
    addTearDown(() => UiProfile.debugOverride = null);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    expect(SettingsCategory.values.where((c) => c.name == 'lyrics'), isEmpty);
    expect(SettingsCategory.appearance.matches('歌词'), isTrue);
    expect(SettingsCategory.appearance.matches('黑胶'), isTrue);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: ListView(children: SettingsCategory.appearance.sections),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(SettingsStrings.language), findsOneWidget);
    expect(find.text(SettingsStrings.nowPlayingStyle), findsOneWidget);
    expect(find.text(SettingsStrings.lyricsStage), findsOneWidget);
  });
}
