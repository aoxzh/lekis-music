// 注音歌词（UIX-11）：设置解析、排版尺寸、核心不可用时的降级。
//
// 真正的拼音由 Rust 侧 `lekis_enrich::ruby` 算（那一段有 Rust 单测覆盖
// UTF-16 偏移），这里只测 Dart 侧的行为：模式解析、上方留白、缓存复用，
// 以及「桥接没就绪时不能把歌词页搞崩」。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/now_playing/lyrics_ruby.dart';
import 'package:lekis/src/features/settings/settings_providers.dart';
import 'package:lekis/src/rust/api/ruby.dart' as rust;
import 'package:material_ui/material_ui.dart';

/// 固定值设置：不经过核心，模拟用户已经选过的注音模式。
class _FixedSetting extends SettingNotifier {
  _FixedSetting(super.key, this.value);

  final String? value;

  @override
  Future<String?> build() async => value;
}

Widget _host({required String? rubySetting, required Widget child}) {
  return ProviderScope(
    overrides: [
      settingProvider.overrideWith2(
        (key) => _FixedSetting(
          key,
          key == SettingKeys.lyricsRuby ? rubySetting : null,
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  setUp(debugClearRubyCache);

  group('LyricsRubyMode', () {
    test('存储值往返', () {
      for (final mode in LyricsRubyMode.values) {
        expect(LyricsRubyMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('缺失 / 未知值退回关闭', () {
      expect(LyricsRubyMode.fromStorage(null), LyricsRubyMode.off);
      expect(LyricsRubyMode.fromStorage(''), LyricsRubyMode.off);
      expect(LyricsRubyMode.fromStorage('unknown'), LyricsRubyMode.off);
    });

    test('只有 off 是关闭', () {
      expect(LyricsRubyMode.off.enabled, isFalse);
      for (final mode in LyricsRubyMode.values.where(
        (m) => m != LyricsRubyMode.off,
      )) {
        expect(mode.enabled, isTrue);
      }
    });

    test('区分拼音和日语注音', () {
      for (final mode in [
        LyricsRubyMode.plain,
        LyricsRubyMode.tone,
        LyricsRubyMode.toneNum,
      ]) {
        expect(mode.pinyin, isTrue);
        expect(mode.japanese, isFalse);
      }
      for (final mode in [LyricsRubyMode.kana, LyricsRubyMode.romaji]) {
        expect(mode.pinyin, isFalse);
        expect(mode.japanese, isTrue);
      }
      expect(LyricsRubyMode.off.pinyin, isFalse);
      expect(LyricsRubyMode.off.japanese, isFalse);
    });

    test('映射到核心的拼音写法', () {
      expect(LyricsRubyMode.off.rustStyle, rust.PinyinStyleDto.plain);
      expect(LyricsRubyMode.plain.rustStyle, rust.PinyinStyleDto.plain);
      expect(LyricsRubyMode.tone.rustStyle, rust.PinyinStyleDto.tone);
      expect(LyricsRubyMode.toneNum.rustStyle, rust.PinyinStyleDto.toneNum);
    });

    test('映射到核心的日语写法', () {
      expect(LyricsRubyMode.kana.japaneseStyle, rust.JapaneseRubyStyleDto.kana);
      expect(
        LyricsRubyMode.romaji.japaneseStyle,
        rust.JapaneseRubyStyleDto.romaji,
      );
    });
  });

  group('语言判断', () {
    test('假名行是日语，汉字行是中文', () {
      expect(containsKana('君の名は'), isTrue);
      expect(containsKana('カタカナ'), isTrue);
      expect(containsKana('ｶﾀｶﾅ'), isTrue);
      expect(containsKana('晴天'), isFalse);
      expect(containsKana('Hello'), isFalse);
    });
  });

  group('排版尺寸', () {
    test('注音留白随字号缩放', () {
      const small = TextStyle(fontSize: 16);
      const big = TextStyle(fontSize: 48);
      expect(rubyInsetFor(small), closeTo(8.32, 0.001));
      expect(rubyInsetFor(big), closeTo(24.96, 0.001));
      expect(rubyInsetFor(big), greaterThan(rubyInsetFor(small) * 2));
    });

    test('注音字号小于正文字号，颜色可覆盖', () {
      const base = TextStyle(fontSize: 40);
      final ruby = rubyStyleFor(base, const Color(0xFFFFFFFF));
      expect(ruby.fontSize, lessThan(40));
      expect(ruby.color, const Color(0xFFFFFFFF));
      expect(ruby.letterSpacing, 0);
    });
  });

  group('偏移 → 字框', () {
    TextPainter layout(String text, double size) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: size),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 400);
    }

    test('每个汉字一个框，横向递增且同高', () {
      final base = layout('晴天', 24);
      final anchors = rubyAnchorRects(base, const [
        rust.RubySpanDto(start: 0, end: 1, ruby: 'qing'),
        rust.RubySpanDto(start: 1, end: 2, ruby: 'tian'),
      ], '晴天');
      base.dispose();
      expect(anchors.length, 2);
      expect(anchors[0].ruby, 'qing');
      expect(anchors[1].ruby, 'tian');
      expect(anchors[1].box.left, greaterThan(anchors[0].box.left));
      expect(anchors[1].box.top, closeTo(anchors[0].box.top, 0.01));
      expect(anchors[0].box.width, greaterThan(0));
    });

    test('topInset 把整个字框下推', () {
      final base = layout('晴天', 24);
      const spans = [rust.RubySpanDto(start: 0, end: 2, ruby: 'qingtian')];
      final plain = rubyAnchorRects(base, spans, '晴天');
      final pushed = rubyAnchorRects(base, spans, '晴天', topInset: 12);
      base.dispose();
      expect(pushed.single.box.top, closeTo(plain.single.box.top + 12, 0.01));
      expect(
        pushed.single.box.center.dx,
        closeTo(plain.single.box.center.dx, 0.01),
      );
    });

    test('越界或空区间被丢弃', () {
      final base = layout('晴天', 24);
      final anchors = rubyAnchorRects(base, const [
        rust.RubySpanDto(start: 0, end: 0, ruby: 'x'),
        rust.RubySpanDto(start: 0, end: 99, ruby: 'x'),
      ], '晴天');
      base.dispose();
      expect(anchors, isEmpty);
    });
  });

  group('核心不可用时降级', () {
    test('取注音不抛异常，返回空', () {
      // 测试环境没有初始化 Rust，桥接调用会抛；这里必须被吞掉。
      expect(rubySpansFor('晴天', LyricsRubyMode.plain), isEmpty);
    });

    testWidgets('RubyLyricText 仍然渲染正文', (tester) async {
      await tester.pumpWidget(
        _host(
          rubySetting: 'plain',
          child: const RubyLyricText(
            text: '晴天',
            style: TextStyle(fontSize: 24),
            opacity: 1,
          ),
        ),
      );
      expect(find.text('晴天'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭注音时不加多余留白', (tester) async {
      await tester.pumpWidget(
        _host(
          rubySetting: 'off',
          child: const RubyLyricText(
            text: '晴天',
            style: TextStyle(fontSize: 24),
            opacity: 1,
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('晴天'));
      expect(text.data, '晴天');
      // 关闭时走的是裸 Text 分支，不创建注音图层。
      expect(find.byType(RubyOverlay), findsNothing);
    });
  });
}
