// Layout guards for accessibility text sizes.
//
// Desktop and mobile both let the user scale the system font up (Windows
// "Text size", Android "Font size"). Chrome that relies on a fixed height
// must either grow with the scale or clamp it, or the last line is clipped
// (RenderFlex overflow). These tests pinch the busiest surfaces at 2.0x —
// the largest accessibility step — and at narrow phone widths.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_providers.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/now_playing/now_playing_style.dart';
import 'package:lekis/src/features/player/mini_player.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/settings/equalizer_page.dart';
import 'package:lekis/src/features/settings/equalizer_providers.dart';
import 'package:lekis/src/features/settings/settings_page.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 7,
    durationMs: 240000,
    queueLength: 3,
    queueIndex: 0,
    volume: 0.8,
  );
}

class _FakePosition extends PositionController {
  @override
  int build() => 61000;
}

class _EmptySources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => const [];
}

class _PendingZero extends EnrichPendingCountNotifier {
  @override
  int? build() => 0;
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
  artists: const ['和田光司', 'Another Artist'],
  albumId: 3,
  albumTitle: 'We Love DiGiMONMUSIC',
  durationMs: BigInt.from(227000),
  genres: const [],
  qualityBadge: 'FLAC 24bit/96kHz',
  loved: true,
  playCount: 5,
  isLocal: false,
);

TrackRowDto _row() => TrackRowDto(
  id: 7,
  title: '青春コンプレックス (A very long track title that must ellipsize)',
  artistLine: 'サナリカ / Another Artist',
  albumTitle: 'An equally long album title',
  durationMs: BigInt.from(240000),
  artworkId: null,
  qualityBadge: 'FLAC 24bit/96kHz',
  loved: false,
  isLocal: true,
);

const _bilingualLyrics = LyricsDto(
  format: LyricsFormatDto.lrc,
  source: 'test',
  offsetMs: 0,
  confidence: 1.0,
  content: '[00:05.00]鼓動は胸を焦がしてる\n[00:05.00]躁动仿佛将心灼伤\n[01:08.00]忘れられた明日\n[01:08.00]已经遗忘了的明天\n',
);

Widget _wrap(
  Widget child,
  Size size,
  double scale, {
  NowPlayingStyle? style,
  EdgeInsets padding = EdgeInsets.zero,
}) => ProviderScope(
  overrides: [
    coreEventSourceProvider.overrideWithValue(const Stream.empty()),
    desktopLyricsSupportedProvider.overrideWithValue(true),
    playbackProvider.overrideWith(_FakePlayback.new),
    positionProvider.overrideWith(_FakePosition.new),
    currentTrackProvider.overrideWith((ref) async => _track),
    currentArtworkProvider.overrideWith((ref) async => null),
    downloadStateProvider.overrideWith((ref, id) => null),
    downloadProgressProvider.overrideWith((ref, id) => null),
    sourcesProvider.overrideWith(_EmptySources.new),
    enrichPendingCountProvider.overrideWith(_PendingZero.new),
    downloadsSummaryProvider.overrideWithValue((
      readyCount: 0,
      totalBytes: 0,
      activeCount: 0,
    )),
    aboutInfoProvider.overrideWithValue(
      const AboutInfo(coreVersion: '9.9.9', deviceId: 'dev-1'),
    ),
    lyricsProvider.overrideWith(
      (ref, id) async => ParsedLyrics.parse(_bilingualLyrics),
    ),
    settingProvider(
      SettingKeys.lyricsDialButton,
    ).overrideWith(() => _FixedSetting(SettingKeys.lyricsDialButton, 'true')),
    if (style != null)
      nowPlayingStyleProvider.overrideWith(() => _FixedStyle(style)),
  ],
  child: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: lekisDarkTheme(),
      home: Material(
        child: Padding(padding: padding, child: child),
      ),
    ),
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('PlayerBar', () {
    for (final width in const [480.0, 600.0, 840.0, 1280.0]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets('fits at ${width.toInt()}dp @${scale}x', (tester) async {
          final size = Size(width, 640);
          _size(tester, size);
          await tester.pumpWidget(
            _wrap(
              const Align(
                alignment: Alignment.bottomCenter,
                child: PlayerBar(),
              ),
              size,
              scale,
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);

          // The bar grows with the system text size instead of clipping the
          // seek times; at 1.0x it is exactly the design height.
          final height = tester.getSize(find.byType(PlayerBar)).height;
          expect(
            height,
            greaterThanOrEqualTo(LekisSizes.desktopPlayerBarHeight),
          );
          if (scale > 1.0) {
            expect(height, greaterThan(LekisSizes.desktopPlayerBarHeight));
          }
        });
      }
    }
  });

  group('MiniPlayerFace', () {
    for (final width in const [320.0, 360.0]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('fits at ${width.toInt()}dp @${scale}x', (tester) async {
          final size = Size(width, 640);
          _size(tester, size);
          await tester.pumpWidget(
            _wrap(
              const Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayerFace(),
              ),
              size,
              scale,
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('TrackTile', () {
    for (final width in const [320.0, 360.0]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('fixed row fits at ${width.toInt()}dp @${scale}x', (
          tester,
        ) async {
          final size = Size(width, 640);
          _size(tester, size);
          await tester.pumpWidget(
            _wrap(
              Scaffold(
                body: ListView(
                  children: [TrackTile(track: _row(), onTap: () {})],
                ),
              ),
              size,
              scale,
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('NowPlayingPage', () {
    for (final style in NowPlayingStyle.values) {
      for (final size in const [Size(320, 640), Size(1024, 600)]) {
        testWidgets(
          '${style.name} fits ${size.width.toInt()}x${size.height.toInt()} @2.0x',
          (tester) async {
            _size(tester, size);
            await tester.pumpWidget(
              _wrap(const NowPlayingPage(), size, 2.0, style: style),
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  testWidgets('SettingsPage fits 320dp @2.0x', (tester) async {
    const size = Size(320, 640);
    _size(tester, size);
    await tester.pumpWidget(_wrap(const SettingsPage(), size, 2.0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  group('EqualizerPage', () {
    for (final size in const [
      Size(320, 720),
      Size(360, 800),
      Size(1280, 900),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets('fits ${size.width.toInt()}dp @${scale}x', (tester) async {
          _size(tester, size);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                equalizerRepositoryProvider.overrideWithValue(
                  _FakeEqualizerRepository(),
                ),
              ],
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: MaterialApp(
                  theme: lekisLightTheme(),
                  home: const EqualizerPage(),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('QueuePanel', () {
    for (final size in const [
      Size(320, 640),
      Size(360, 740),
      Size(1280, 820),
    ]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets('fits ${size.width.toInt()}dp @${scale}x', (tester) async {
          _size(tester, size);
          final container = ProviderContainer(
            overrides: [
              playbackProvider.overrideWith(_QueuePlayback.new),
              positionProvider.overrideWith(_FakePosition.new),
              currentTrackProvider.overrideWith((ref) async => null),
              currentArtworkProvider.overrideWith((ref) async => null),
              queuePreviewProvider.overrideWith(
                (ref) async => [for (var i = 0; i < 3; i++) _queueRow(i)],
              ),
              queueListProvider.overrideWith((ref) => _queueList()),
              downloadStateProvider.overrideWith((ref, trackId) => null),
              trackArtworkProvider.overrideWith((ref, trackId) async => null),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: MaterialApp(
                  theme: lekisDarkTheme(),
                  home: Scaffold(body: QueuePanel(onClose: () {})),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

const _queueLength = 80;

class _FakeEqualizerRepository extends EqualizerRepository {
  _FakeEqualizerRepository();

  @override
  Future<EqualizerState> load() async => EqualizerState.fromDto(
    EqualizerDto(
      enabled: true,
      preampDb: 0,
      bandsDb: Float32List(equalizerBandCount),
      preset: null,
    ),
    [
      EqualizerPresetDto(
        id: 'sennheiser-hd-600',
        name: 'Sennheiser HD 600',
        description: '接近中性的微调',
        preampDb: -2,
        bandsDb: Float32List.fromList(const [
          0.5,
          0.5,
          0,
          -0.5,
          -0.5,
          0,
          0.5,
          0.5,
          0,
          -0.5,
        ]),
      ),
    ],
  );

  @override
  Future<void> save(EqualizerState state) async {}
}

TrackRowDto _queueRow(int index) => TrackRowDto(
  id: 1000 + index,
  title: '曲目 $index (a very long queue entry title that must ellipsize)',
  artistLine: '月兔 / Another Artist',
  albumTitle: '月面',
  durationMs: BigInt.from(180000),
  qualityBadge: 'FLAC',
  loved: false,
  isLocal: false,
);

class _QueuePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1040,
    durationMs: 240000,
    queueLength: _queueLength,
    queueIndex: 40,
  );
}

PagedList<TrackRowDto> _queueList() => PagedList<TrackRowDto>(
  pageSize: 20,
  count: () async => _queueLength,
  fetch: (offset, limit) async {
    final end = (offset + limit).clamp(0, _queueLength);
    return [for (var i = offset; i < end; i++) _queueRow(i)];
  },
);
