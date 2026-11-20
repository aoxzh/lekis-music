// 歌词视图的默认值：默认是经典（Apple Music 风格）逐行歌词，只有设置里
// 显式选了舞台样式才渲染 LyricsStage；暂停时当前句仍然可见（不是空白）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_classic.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class _FakePlayback extends PlaybackController {
  _FakePlayback(this.playbackState);
  final PlaybackStateDto playbackState;

  @override
  PlaybackUiState build() => PlaybackUiState(
    state: playbackState,
    trackId: 1,
    durationMs: 180000,
    queueLength: 1,
    queueIndex: 0,
  );
}

class _FakePosition extends PositionController {
  _FakePosition(this.position);
  final int position;

  @override
  int build() => position;
}

/// 核心设置还没返回：`ui.lyrics_stage` 缺失，应当退回经典视图。
class _MissingSetting extends SettingNotifier {
  _MissingSetting(super.key);

  @override
  Future<String?> build() async => null;
}

ParsedLyrics _plain() => ParsedLyrics.parse(
  LyricsDto(
    format: LyricsFormatDto.lrc,
    content: '[00:01.00]first\n[00:05.00]second\n[00:09.00]third',
    source: 'test',
    offsetMs: 0,
    confidence: 1,
  ),
);

ParsedLyrics _lyrics() => ParsedLyrics.parse(
  LyricsDto(
    format: LyricsFormatDto.enhancedLrc,
    content:
        '[00:05.00]<00:05.00>hello <00:05.40>world\n'
        '[00:08.00]<00:08.00>next <00:08.40>line',
    source: 'test',
    offsetMs: 0,
    confidence: 1,
  ),
);

ProviderContainer _container({
  LyricsStyle? style,
  required PlaybackStateDto playback,
  int position = 5300,
  ParsedLyrics Function()? lyrics,
}) {
  final container = ProviderContainer(
    overrides: [
      playbackProvider.overrideWith(() => _FakePlayback(playback)),
      positionProvider.overrideWith(() => _FakePosition(position)),
      lyricsProvider.overrideWith(
        (ref, trackId) async => (lyrics ?? _lyrics)(),
      ),
      // 不覆盖 style 时走真实的设置 provider（缺失 → 经典）。
      if (style != null) lyricsStyleProvider.overrideWithValue(style),
      if (style != null) lyricsSparksProvider.overrideWithValue(false),
      if (style == null)
        settingProvider.overrideWith2((key) => _MissingSetting(key)),
    ],
  );
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: lekisDarkTheme(),
        home: const Scaffold(body: LyricsView(trackId: 1)),
      ),
    ),
  );
  // 等 FutureProvider / 设置加载完成，并跑完第一轮跟随动画。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('synced lyrics render the classic view by default', (
    tester,
  ) async {
    final container = _container(playback: PlaybackStateDto.paused);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.byType(ClassicLyrics), findsOneWidget);
    expect(find.byType(LyricsStage), findsNothing);
    expect(find.text('hello world'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic view keeps the active line visible while paused', (
    tester,
  ) async {
    // 暂停在 00:05.30，当前句是 "hello world"：位置不再更新时它也必须
    // 完整地留在屏幕上（曾经出现过暂停后整块歌词变空白的问题）。
    final container = _container(
      playback: PlaybackStateDto.paused,
      position: 5300,
    );
    addTearDown(container.dispose);
    await _pump(tester, container);

    final activeLine = find.text('hello world');
    expect(activeLine, findsOneWidget);
    expect(tester.getSize(activeLine).height, greaterThan(0));
    // 当前句（带逐字时间）由 painter 画出；不能被任何半透明图层盖住。
    final layers = tester.widgetList<Opacity>(
      find.ancestor(of: activeLine, matching: find.byType(Opacity)),
    );
    // 唯一的 Opacity 是撑高度用的隐形 Text 自己的那一层。
    expect(layers.length, 1);

    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('hello world'), findsOneWidget);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a stage style renders LyricsStage', (tester) async {
    final container = _container(
      style: LyricsStyle.flow,
      playback: PlaybackStateDto.playing,
    );
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.byType(LyricsStage), findsOneWidget);
    expect(find.byType(ClassicLyrics), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic dims other lines through text colour, not layers', (
    tester,
  ) async {
    final container = _container(
      playback: PlaybackStateDto.paused,
      position: 5200,
      lyrics: _plain,
    );
    addTearDown(container.dispose);
    await _pump(tester, container);
    await tester.pump(const Duration(milliseconds: 600));

    double alphaOf(String text) =>
        tester.widget<Text>(find.text(text)).style!.color!.a;
    expect(alphaOf('second'), closeTo(1, 0.01));
    // 邻句提亮过（0.55/0.4 → 0.62/0.45）：亮封面下远处歌词原来会糊掉。
    expect(alphaOf('third'), closeTo(0.62, 0.01));
    expect(alphaOf('first'), closeTo(0.45, 0.01));
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('karaoke fill only ticks while playing inside the line', (
    tester,
  ) async {
    final playing = _container(
      playback: PlaybackStateDto.playing,
      position: 5100,
    );
    addTearDown(playing.dispose);
    await _pump(tester, playing);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    final paused = _container(playback: PlaybackStateDto.paused);
    addTearDown(paused.dispose);
    await _pump(tester, paused);
    await tester.pump(const Duration(milliseconds: 600));
    // 暂停：没有任何逐帧回调（滚动弹簧也已停稳）。
    expect(tester.binding.transientCallbackCount, 0);
  });

  group('LyricsClock', () {
    test('follows reported positions and holds still while paused', () {
      final clock = LyricsClock(const TestVSync());
      addTearDown(clock.dispose);
      clock.sync(1000, false);
      expect(clock.value, 1000);
      clock.sync(1200, false);
      expect(clock.value, 1200);
      expect(clock.playing, isFalse);
    });

    test('never steps backwards by less than one report interval', () {
      final clock = LyricsClock(const TestVSync());
      addTearDown(clock.dispose);
      clock.sync(1000, true);
      final before = clock.value;
      // 核心晚到的推送比外推值略小：保持单调。
      clock.sync(990, true);
      expect(clock.value, greaterThanOrEqualTo(before));
      // 拖动进度：直接跳过去。
      clock.sync(60000, true);
      expect(clock.value, greaterThanOrEqualTo(60000));
      clock.sync(2000, true);
      expect(clock.value, lessThan(2300));
    });

    test('only runs its ticker when asked to animate while playing', () {
      final clock = LyricsClock(const TestVSync());
      addTearDown(clock.dispose);
      var notified = 0;
      clock.addListener(() => notified++);
      clock.sync(0, false);
      clock.animate = true;
      clock.sync(500, true);
      expect(notified, greaterThan(0));
      clock.animate = false;
      expect(clock.animate, isFalse);
    });
  });
}
