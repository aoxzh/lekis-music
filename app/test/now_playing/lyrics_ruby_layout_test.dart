// 注音歌词的排版：注音带要留在每一个折行上方，注音不能压到上一折行 / 上
// 一句歌词的字，比字宽的注音互相不能叠；当前句（卡拉 OK）和其它行用同
// 一份排版；开关注音后当前句仍然停在锚点上。
//
// 测试环境没有 Rust 核心，注音结果用 debugSeedRubySpans 直接塞进缓存。
// 测试字体（FlutterTest）的字形是满 em 的方块：ascent 0.75em、descent
// 0.25em，所以「字框」就是 [基线 − 0.75em, 基线 + 0.25em]，判断重叠是精确的。

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_classic.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_ruby.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/ruby.dart' as rust;
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

// ---------------------------------------------------------------------------
// 歌词和注音
// ---------------------------------------------------------------------------

const _line1 = '君の名前を呼んだ夜空の星';
const _line2 = '遠い記憶の中で笑った君';

const _kana = <String, List<rust.RubySpanDto>>{
  _line1: [
    rust.RubySpanDto(start: 0, end: 1, ruby: 'きみ'),
    rust.RubySpanDto(start: 2, end: 4, ruby: 'なまえ'),
    rust.RubySpanDto(start: 5, end: 6, ruby: 'よ'),
    rust.RubySpanDto(start: 8, end: 10, ruby: 'よぞら'),
    rust.RubySpanDto(start: 11, end: 12, ruby: 'ほし'),
  ],
  _line2: [
    rust.RubySpanDto(start: 0, end: 1, ruby: 'とお'),
    rust.RubySpanDto(start: 2, end: 4, ruby: 'きおく'),
    rust.RubySpanDto(start: 5, end: 6, ruby: 'なか'),
    rust.RubySpanDto(start: 7, end: 8, ruby: 'わら'),
    rust.RubySpanDto(start: 10, end: 11, ruby: 'きみ'),
  ],
};

/// 罗马音：汉字和假名都标，而且常常比字宽（`yozora` 盖在两个字上）。
const _romaji = <String, List<rust.RubySpanDto>>{
  _line1: [
    rust.RubySpanDto(start: 0, end: 1, ruby: 'kimi'),
    rust.RubySpanDto(start: 1, end: 2, ruby: 'no'),
    rust.RubySpanDto(start: 2, end: 4, ruby: 'namae'),
    rust.RubySpanDto(start: 4, end: 5, ruby: 'wo'),
    rust.RubySpanDto(start: 5, end: 6, ruby: 'yo'),
    rust.RubySpanDto(start: 6, end: 7, ruby: 'n'),
    rust.RubySpanDto(start: 7, end: 8, ruby: 'da'),
    rust.RubySpanDto(start: 8, end: 10, ruby: 'yozora'),
    rust.RubySpanDto(start: 10, end: 11, ruby: 'no'),
    rust.RubySpanDto(start: 11, end: 12, ruby: 'hoshi'),
  ],
  _line2: [
    rust.RubySpanDto(start: 0, end: 1, ruby: 'too'),
    rust.RubySpanDto(start: 1, end: 2, ruby: 'i'),
    rust.RubySpanDto(start: 2, end: 4, ruby: 'kioku'),
    rust.RubySpanDto(start: 4, end: 5, ruby: 'no'),
    rust.RubySpanDto(start: 5, end: 6, ruby: 'naka'),
    rust.RubySpanDto(start: 6, end: 7, ruby: 'de'),
    rust.RubySpanDto(start: 7, end: 8, ruby: 'wara'),
    rust.RubySpanDto(start: 8, end: 9, ruby: 'tt'),
    rust.RubySpanDto(start: 9, end: 10, ruby: 'ta'),
    rust.RubySpanDto(start: 10, end: 11, ruby: 'kimi'),
  ],
};

void _seed(LyricsRubyMode mode, Map<String, List<rust.RubySpanDto>> spans) {
  for (final e in spans.entries) {
    debugSeedRubySpans(e.key, mode, e.value);
  }
}

/// 和真实歌词一样的正文样式（32px，行高 1.25，even 分配，字距 −0.2）。
const _style = TextStyle(
  fontSize: 32,
  height: 1.25,
  letterSpacing: -0.2,
  leadingDistribution: TextLeadingDistribution.even,
  color: Color(0xFFFFFFFF),
);

class _Mode extends Notifier<LyricsRubyMode> {
  _Mode(this.initial);
  final LyricsRubyMode initial;

  @override
  LyricsRubyMode build() => initial;

  void set(LyricsRubyMode mode) => state = mode;
}

// ---------------------------------------------------------------------------
// 几何
// ---------------------------------------------------------------------------

Rect _toGlobal(RenderBox box, Rect local) =>
    MatrixUtils.transformRect(box.getTransformTo(null), local);

/// 一个 Text 每个折行的字形框（全局坐标）。默认的 tight 选区框就是字体
/// 自然的 ascent / descent（不含行距），同一折行的框并成一个。
List<Rect> _glyphRows(WidgetTester tester, Finder text) {
  final para = tester.renderObject<RenderParagraph>(text);
  final length = para.text.toPlainText().length;
  final rows = <Rect>[];
  for (final box in para.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: length),
  )) {
    final r = box.toRect();
    final i = rows.indexWhere((row) => (row.top - r.top).abs() < 0.5);
    if (i < 0) {
      rows.add(r);
    } else {
      rows[i] = rows[i].expandToInclude(r);
    }
  }
  rows.sort((a, b) => a.top.compareTo(b.top));
  return [for (final r in rows) _toGlobal(para, r)];
}

/// 某个注音图层画出来的每条注音（全局坐标）。
List<({Rect rect, int line, String ruby})> _labels(
  WidgetTester tester,
  Finder overlay,
) {
  final paint = find.descendant(of: overlay, matching: find.byType(CustomPaint));
  final box = tester.renderObject<RenderBox>(paint);
  final painter = tester.widget<CustomPaint>(paint).painter! as RubyPainter;
  return [
    for (final l in painter.labels(box.size))
      (rect: _toGlobal(box, l.rect), line: l.line, ruby: l.ruby),
  ];
}

/// 浮点误差以内的「接触」不算重叠。
bool _overlaps(Rect a, Rect b) => a.deflate(0.01).overlaps(b.deflate(0.01));

/// 所有注音都不压任何一行的字、彼此也不叠；而且确实有注音画在折行上。
void _expectClear(
  List<({Rect rect, int line, String ruby})> labels,
  List<Rect> glyphRows,
) {
  expect(labels, isNotEmpty);
  expect(
    labels.any((l) => l.line > 0),
    isTrue,
    reason: '应当有注音落在第二个折行上（这一行要够长、会折行）',
  );
  for (final l in labels) {
    for (final row in glyphRows) {
      expect(
        _overlaps(l.rect, row),
        isFalse,
        reason: '注音「${l.ruby}」${l.rect} 压到了字形行 $row',
      );
    }
  }
  for (var i = 0; i < labels.length; i++) {
    for (var j = i + 1; j < labels.length; j++) {
      expect(
        _overlaps(labels[i].rect, labels[j].rect),
        isFalse,
        reason:
            '注音「${labels[i].ruby}」${labels[i].rect} 和'
            '「${labels[j].ruby}」${labels[j].rect} 叠在一起',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 宿主
// ---------------------------------------------------------------------------

Widget _pair(LyricsRubyMode mode, {double width = 300}) => ProviderScope(
  overrides: [lyricsRubyProvider.overrideWithValue(mode)],
  child: MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          // 和经典歌词一样：上下两句紧挨着，中间只有行内的上下留白。
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: RubyLyricText(text: _line1, style: _style, opacity: 1),
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: RubyLyricText(text: _line2, style: _style, opacity: 1),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(debugClearRubyCache);

  group('相邻两句带注音的日语歌词', () {
    for (final (mode, spans) in [
      (LyricsRubyMode.kana, _kana),
      (LyricsRubyMode.romaji, _romaji),
    ]) {
      testWidgets('${mode.name}：注音不压上一折行 / 上一句，也不互相叠', (tester) async {
        _seed(mode, spans);
        await tester.pumpWidget(_pair(mode));

        final rows1 = _glyphRows(tester, find.text(_line1));
        final rows2 = _glyphRows(tester, find.text(_line2));
        expect(rows1.length, greaterThanOrEqualTo(2), reason: '第一句要折行');
        expect(rows2.length, greaterThanOrEqualTo(2), reason: '第二句要折行');
        final overlays = find.byType(RubyOverlay);
        expect(overlays, findsNWidgets(2));
        final labels1 = _labels(tester, overlays.at(0));
        final labels2 = _labels(tester, overlays.at(1));
        _expectClear([...labels1, ...labels2], [...rows1, ...rows2]);

        // 每条注音都紧贴在自己那一折行的上方，并且在上一折行（或上一句）
        // 的字下面。
        for (final (labels, rows, above) in [
          (labels1, rows1, null),
          (labels2, rows2, rows1.last),
        ]) {
          for (final l in labels) {
            final row = rows[l.line];
            expect(l.rect.bottom, lessThanOrEqualTo(row.top + 0.01));
            final ceiling = l.line > 0 ? rows[l.line - 1] : above;
            if (ceiling != null) {
              expect(l.rect.top, greaterThanOrEqualTo(ceiling.bottom - 0.01));
            }
          }
        }
        // 整体都在各自的组件里，不会伸出去盖住更上面的东西。
        final top1 = tester.getTopLeft(overlays.at(0)).dy;
        for (final l in labels1) {
          expect(l.rect.top, greaterThanOrEqualTo(top1 - 0.01));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('系统字号放大时注音带跟着放大', (tester) async {
      _seed(LyricsRubyMode.kana, _kana);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: _pair(LyricsRubyMode.kana, width: 360),
        ),
      );
      final rows = [
        ..._glyphRows(tester, find.text(_line1)),
        ..._glyphRows(tester, find.text(_line2)),
      ];
      final overlays = find.byType(RubyOverlay);
      _expectClear([
        ..._labels(tester, overlays.at(0)),
        ..._labels(tester, overlays.at(1)),
      ], rows);
    });
  });

  group('不带注音时和以前完全一样', () {
    testWidgets('注音关闭：原样式、没有注音层', (tester) async {
      _seed(LyricsRubyMode.kana, _kana);
      await tester.pumpWidget(_pair(LyricsRubyMode.off));
      expect(tester.widget<Text>(find.text(_line1)).style, _style);
      expect(find.byType(RubyOverlay), findsNothing);
      expect(
        find.ancestor(of: find.text(_line1), matching: find.byType(Stack)),
        findsNothing,
      );
    });

    testWidgets('开着注音但这一句没有读音：不留注音带', (tester) async {
      // 没有塞缓存：核心不可用 → 这一句没有注音。
      await tester.pumpWidget(_pair(LyricsRubyMode.kana));
      final text = tester.widget<Text>(find.text(_line1));
      expect(text.style, _style);
      expect(text.textHeightBehavior, isNull);
      expect(find.byType(RubyOverlay), findsNothing);
    });
  });

  group('rubyLineLayoutFor', () {
    test('行高加上一条注音带，首行上方留同样的高度', () {
      final layout = rubyLineLayoutFor(_style, TextScaler.noScaling);
      expect(layout.inset, closeTo(rubyBandFor(_style), 1e-9));
      expect(layout.style.height, closeTo(1.25 + layout.inset / 32, 1e-9));
      expect(layout.style.fontSize, 32);
      expect(layout.style.letterSpacing, greaterThan(-0.2));
    });

    test('按 TextScaler 放大', () {
      final plain = rubyLineLayoutFor(_style, TextScaler.noScaling);
      final big = rubyLineLayoutFor(_style, const TextScaler.linear(1.5));
      expect(big.inset, closeTo(plain.inset * 1.5, 1e-9));
      // 行高是倍数，线性放大时倍数不变。
      expect(big.style.height, closeTo(plain.style.height!, 1e-9));
    });

    test('正文行高过紧时抬到下限', () {
      final tight = rubyLineLayoutFor(
        _style.copyWith(height: 0.9),
        TextScaler.noScaling,
      );
      expect(tight.style.height, greaterThan(1.15));
    });
  });

  group('经典歌词', () {
    const lrc =
        '[00:05.00]<00:05.00>君の<00:05.40>名前を<00:05.80>呼んだ'
        '<00:06.20>夜空の星\n'
        '[00:09.00]<00:09.00>遠い<00:09.40>記憶の<00:09.80>中で'
        '<00:10.20>笑った君\n'
        '[00:13.00]<00:13.00>end';

    Future<ProviderContainer> pumpClassic(
      WidgetTester tester,
      NotifierProvider<_Mode, LyricsRubyMode> modeProvider, {
      int position = 5300,
    }) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          playbackProvider.overrideWith(_PausedPlayback.new),
          positionProvider.overrideWith(() => _FixedPosition(position)),
          lyricsProvider.overrideWith(
            (ref, trackId) async => ParsedLyrics.parse(
              LyricsDto(
                format: LyricsFormatDto.enhancedLrc,
                content: lrc,
                source: 'test',
                offsetMs: 0,
                confidence: 1,
              ),
            ),
          ),
          settingProvider.overrideWith2((key) => _NullSetting(key)),
          lyricsRubyProvider.overrideWith((ref) => ref.watch(modeProvider)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const Scaffold(body: LyricsView(trackId: 1)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      return container;
    }

    double activeTop(WidgetTester tester) {
      // 当前句（第二句，卡拉 OK）的隐形占位 Text 所在的 Stack 顶边。
      final stack = find
          .ancestor(of: find.text(_line2), matching: find.byType(Stack))
          .first;
      return tester.getTopLeft(stack).dy;
    }

    testWidgets('当前句（卡拉 OK）和下一句的注音互不相压', (tester) async {
      _seed(LyricsRubyMode.kana, _kana);
      final mode = NotifierProvider<_Mode, LyricsRubyMode>(
        () => _Mode(LyricsRubyMode.kana),
      );
      await pumpClassic(tester, mode);
      expect(find.byType(ClassicLyrics), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      final overlays = find.byType(RubyOverlay);
      expect(overlays, findsNWidgets(2));
      _expectClear(
        [..._labels(tester, overlays.at(0)), ..._labels(tester, overlays.at(1))],
        [
          ..._glyphRows(tester, find.text(_line1)),
          ..._glyphRows(tester, find.text(_line2)),
          ..._glyphRows(tester, find.text('end')),
        ],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关注音后当前句仍停在锚点', (tester) async {
      _seed(LyricsRubyMode.kana, _kana);
      final mode = NotifierProvider<_Mode, LyricsRubyMode>(
        () => _Mode(LyricsRubyMode.off),
      );
      // 当前句是第二句：它在列表里的位置取决于第一句（带注音时更高）。
      final container = await pumpClassic(tester, mode, position: 9300);
      await tester.pump(const Duration(seconds: 1));
      final before = activeTop(tester);

      container.read(mode.notifier).set(LyricsRubyMode.kana);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RubyOverlay), findsWidgets);
      expect(activeTop(tester), closeTo(before, 1));

      container.read(mode.notifier).set(LyricsRubyMode.off);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RubyOverlay), findsNothing);
      expect(activeTop(tester), closeTo(before, 1));
    });
  });
}

class _PausedPlayback extends PlaybackController {
  @override
  PlaybackUiState build() => PlaybackUiState(
    state: PlaybackStateDto.paused,
    trackId: 1,
    durationMs: 180000,
    queueLength: 1,
    queueIndex: 0,
  );
}

class _FixedPosition extends PositionController {
  _FixedPosition(this.position);
  final int position;

  @override
  int build() => position;
}

class _NullSetting extends SettingNotifier {
  _NullSetting(super.key);

  @override
  Future<String?> build() async => null;
}
