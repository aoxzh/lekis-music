// 歌词舞台的渲染烟测：三种样式 × 火花开关，以及设置页的样式选择器。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState(
    state: PlaybackStateDto.playing,
    trackId: 1,
    durationMs: 240000,
  );
}

class _FakePosition extends PositionController {
  _FakePosition(this.value);
  final int value;

  @override
  int build() => value;
}

ParsedLyrics _lyrics() => ParsedLyrics.parse(
  LyricsDto(
    format: LyricsFormatDto.enhancedLrc,
    content:
        '[00:01.00]<00:01.00>Hello <00:01.50>world <00:02.00>今夜 '
        '<00:02.50>星光\n[00:06.00]下一句',
    source: 'test',
    offsetMs: 0,
    confidence: 1,
  ),
);

void main() {
  for (final style in LyricsStageStyle.values) {
    for (final sparks in [false, true]) {
      testWidgets('${style.name} style renders with sparks=$sparks', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(420, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackProvider.overrideWith(_FakePlayback.new),
              positionProvider.overrideWith(() => _FakePosition(2200)),
            ],
            child: MaterialApp(
              theme: lekisDarkTheme(),
              home: Scaffold(
                body: LyricsStage(
                  lyrics: _lyrics(),
                  style: style,
                  sparks: sparks,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));

        expect(tester.takeException(), isNull);
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel(RegExp('Hello world')), findsOneWidget);
        semantics.dispose();
      });
    }
  }

  testWidgets('reduced motion renders every style without sparks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final style in LyricsStageStyle.values) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackProvider.overrideWith(_FakePlayback.new),
            positionProvider.overrideWith(() => _FakePosition(2200)),
          ],
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: Scaffold(
              body: LyricsStage(
                lyrics: _lyrics(),
                style: style,
                sparks: true,
                lowPower: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('long intro shows the breathing interlude', (tester) async {
    final lyrics = ParsedLyrics.parse(
      LyricsDto(
        format: LyricsFormatDto.lrc,
        content: '[00:05.00]first\n[00:10.00]second',
        source: 'test',
        offsetMs: 0,
        confidence: 1,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(_FakePlayback.new),
          positionProvider.overrideWith(() => _FakePosition(1000)),
        ],
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(
            body: LyricsStage(
              lyrics: lyrics,
              style: LyricsStageStyle.flow,
              sparks: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('stage-interlude')), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('间奏'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('style selector reports the chosen style', (tester) async {
    LyricsStageStyle? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: Center(
            child: LyricsStageStyleSelector(
              selected: LyricsStageStyle.flow,
              onChanged: (style) => chosen = style,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('倾斜'));
    await tester.pump();
    expect(chosen, LyricsStageStyle.tilt);
  });

  test('unknown storage value falls back to flow', () {
    expect(LyricsStageStyle.fromStorage('tilt'), LyricsStageStyle.tilt);
    expect(LyricsStageStyle.fromStorage('nope'), LyricsStageStyle.flow);
    expect(LyricsStageStyle.fromStorage(null), LyricsStageStyle.flow);
    expect(SettingKeys.lyricsStage, 'ui.lyrics_stage');
    expect(SettingKeys.lyricsSparks, 'ui.lyrics_sparks');
  });
}
