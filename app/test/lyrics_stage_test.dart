// 歌词舞台：三种样式 × 火花开关的渲染烟测、逐帧回调只在需要时运行、
// 间奏 / 手动浏览，以及设置页的样式选择器。

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
  _FakePlayback([this.playbackState = PlaybackStateDto.playing]);
  final PlaybackStateDto playbackState;

  @override
  PlaybackUiState build() =>
      PlaybackUiState(state: playbackState, trackId: 1, durationMs: 240000);
}

class _FakePosition extends PositionController {
  _FakePosition(this.value);
  final int value;

  @override
  int build() => value;
}

/// 设置项缺失的假实现：核心还没返回时 `ui.lyrics_stage` 是 null。
class _MissingSetting extends SettingNotifier {
  _MissingSetting(super.key);

  @override
  Future<String?> build() async => null;
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

Future<void> _pumpStage(
  WidgetTester tester, {
  required ParsedLyrics lyrics,
  required int position,
  LyricsStageStyle style = LyricsStageStyle.flow,
  PlaybackStateDto playback = PlaybackStateDto.playing,
  bool lowPower = false,
}) async {
  tester.view.physicalSize = const Size(420, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      // 每次都是一棵新树：上一次的舞台和它的时钟一起销毁。
      key: UniqueKey(),
      overrides: [
        playbackProvider.overrideWith(() => _FakePlayback(playback)),
        positionProvider.overrideWith(() => _FakePosition(position)),
      ],
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: LyricsStage(
            lyrics: lyrics,
            style: style,
            sparks: true,
            lowPower: lowPower,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ParsedLyrics _gapLyrics() => ParsedLyrics.parse(
  LyricsDto(
    format: LyricsFormatDto.enhancedLrc,
    content:
        '[00:01.00]<00:01.00>one <00:01.40>two\n'
        '[00:20.00]<00:20.00>after <00:20.50>break',
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

  testWidgets('style selector offers classic first and reports a choice', (
    tester,
  ) async {
    LyricsStyle? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: lekisDarkTheme(),
        home: Scaffold(
          body: Center(
            child: LyricsStyleSelector(
              selected: LyricsStyle.classic,
              onChanged: (style) => chosen = style,
            ),
          ),
        ),
      ),
    );
    // 经典是默认；四个选项按 经典 / 流动 / 阶梯 / 倾斜 排列。
    final button = tester.widget<SegmentedButton<LyricsStyle>>(
      find.byType(SegmentedButton<LyricsStyle>),
    );
    expect(button.selected, {LyricsStyle.classic});
    expect(
      [for (final segment in button.segments) (segment.label! as Text).data],
      ['经典', '流动', '阶梯', '倾斜'],
    );

    await tester.tap(find.text('倾斜'));
    await tester.pump();
    expect(chosen, LyricsStyle.tilt);
  });

  test('storage values: classic is the default, old stage choices survive', () {
    expect(LyricsStyle.fromStorage('classic'), LyricsStyle.classic);
    expect(LyricsStyle.fromStorage('flow'), LyricsStyle.flow);
    expect(LyricsStyle.fromStorage('steps'), LyricsStyle.steps);
    expect(LyricsStyle.fromStorage('tilt'), LyricsStyle.tilt);
    expect(LyricsStyle.fromStorage('nope'), LyricsStyle.classic);
    expect(LyricsStyle.fromStorage(null), LyricsStyle.classic);
    expect(LyricsStyle.classic.isStage, isFalse);
    expect(LyricsStyle.tilt.isStage, isTrue);
    expect(LyricsStyle.tilt.stage, LyricsStageStyle.tilt);
    expect(SettingKeys.lyricsStage, 'ui.lyrics_stage');
    expect(SettingKeys.lyricsSparks, 'ui.lyrics_sparks');
  });

  test('lyricsStyleProvider falls back to the classic view', () async {
    final container = ProviderContainer(
      overrides: [settingProvider.overrideWith2((key) => _MissingSetting(key))],
    );
    addTearDown(container.dispose);
    await container.read(settingProvider(SettingKeys.lyricsStage).future);
    expect(container.read(lyricsStyleProvider), LyricsStyle.classic);
  });

  for (final style in LyricsStageStyle.values) {
    testWidgets('${style.name}: frames only while words move', (tester) async {
      // 正在唱 "Hello"：逐帧推进。
      await _pumpStage(tester, lyrics: _lyrics(), position: 1100, style: style);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(tester.takeException(), isNull);

      // 暂停：一帧都不要。
      await _pumpStage(
        tester,
        lyrics: _lyrics(),
        position: 1100,
        style: style,
        playback: PlaybackStateDto.paused,
      );
      expect(tester.binding.transientCallbackCount, 0);

      // 低电量：只跟着位置推送重绘。
      await _pumpStage(
        tester,
        lyrics: _lyrics(),
        position: 1100,
        style: style,
        lowPower: true,
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('long break after a line shows the interlude', (tester) async {
    await _pumpStage(tester, lyrics: _gapLyrics(), position: 9000);
    expect(find.byKey(const ValueKey('stage-interlude')), findsOneWidget);
    // 呼吸点靠低频定时器，不跑逐帧 Ticker。
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line being sung hides the interlude', (tester) async {
    await _pumpStage(tester, lyrics: _gapLyrics(), position: 1500);
    expect(find.byKey(const ValueKey('stage-interlude')), findsNothing);
  });

  testWidgets('swiping browses lines and offers a way back', (tester) async {
    await _pumpStage(
      tester,
      lyrics: _lyrics(),
      position: 2200,
      playback: PlaybackStateDto.paused,
    );
    expect(find.text('回到当前'), findsNothing);
    await tester.drag(find.byType(LyricsStage), const Offset(0, -200));
    await tester.pump();
    expect(find.text('回到当前'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('下一句'), findsOneWidget);
    semantics.dispose();

    await tester.tap(find.text('回到当前'));
    await tester.pump();
    expect(find.text('回到当前'), findsNothing);
    // 浏览计时器已取消，不会留下挂起的 Timer。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('plain LRC lines are spread into words on the stage', (
    tester,
  ) async {
    final lyrics = ParsedLyrics.parse(
      LyricsDto(
        format: LyricsFormatDto.lrc,
        content: '[00:01.00]我们一起去看海吧 then sing along\n[00:06.00]next',
        source: 'test',
        offsetMs: 0,
        confidence: 1,
      ),
    );
    for (final style in LyricsStageStyle.values) {
      await _pumpStage(tester, lyrics: lyrics, position: 2500, style: style);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    }
  });
}
