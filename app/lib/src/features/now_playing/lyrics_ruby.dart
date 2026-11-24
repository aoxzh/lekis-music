// 注音歌词（UIX-11）：把汉字上方的拼音 / 振假名 / 罗马音画出来。
//
// 为什么不用 `WidgetSpan`：拼音要标在**每个汉字**上方，而 Flex 里的
// WidgetSpan 会让 Text 失去换行、行高和逐字高亮的排版能力（经典歌词的
// 卡拉 OK 填充靠 `TextPainter.getBoxesForSelection` 拿字框，换掉就全废）。
//
// 所以这里走「同一份排版量两次」的老路：
//   1. 正文仍然由普通的 `Text` 画，负责换行 / 行高 / 无障碍 / 卡拉 OK；
//   2. 注音层用**同样宽度、同样 style** 的 `TextPainter` 再排一次，只取
//      每个汉字的字框（`getBoxesForSelection`），把拼音居中画在字框上方。
//
// 两层的排版参数必须严格一致（width / style / textScaler / locale /
// textDirection），否则拼音会和字错位——`_RubyArt.matches` 就是用来兜这个的。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/ruby.dart' as rust;
import '../settings/settings_providers.dart';
import '../settings/strings.dart';

/// 注音模式。前三种是中文拼音的写法，后两种是日语歌词的振假名 / 罗马音。
enum LyricsRubyMode {
  off('off'),
  plain('plain'),
  tone('tone'),
  toneNum('tone_num'),
  kana('kana'),
  romaji('romaji');

  const LyricsRubyMode(this.storageValue);

  /// 写进核心设置 `ui.lyrics_ruby` 的值。
  final String storageValue;

  static LyricsRubyMode fromStorage(String? value) => values.firstWhere(
    (m) => m.storageValue == value,
    orElse: () => LyricsRubyMode.off,
  );

  bool get enabled => this != LyricsRubyMode.off;

  /// 日语振假名 / 罗马音。只作用于带假名的歌词行。
  bool get japanese =>
      this == LyricsRubyMode.kana || this == LyricsRubyMode.romaji;

  /// 中文拼音。日语行会被跳过，避免给日文汉字标中文读音。
  bool get pinyin => enabled && !japanese;

  rust.PinyinStyleDto get rustStyle => switch (this) {
    LyricsRubyMode.tone => rust.PinyinStyleDto.tone,
    LyricsRubyMode.toneNum => rust.PinyinStyleDto.toneNum,
    _ => rust.PinyinStyleDto.plain,
  };

  rust.JapaneseRubyStyleDto get japaneseStyle => this == LyricsRubyMode.romaji
      ? rust.JapaneseRubyStyleDto.romaji
      : rust.JapaneseRubyStyleDto.kana;

  String get label => switch (this) {
    LyricsRubyMode.off => SettingsStrings.rubyOff,
    LyricsRubyMode.plain => SettingsStrings.rubyPlain,
    LyricsRubyMode.tone => SettingsStrings.rubyTone,
    LyricsRubyMode.toneNum => SettingsStrings.rubyToneNum,
    LyricsRubyMode.kana => SettingsStrings.rubyKana,
    LyricsRubyMode.romaji => SettingsStrings.rubyRomaji,
  };
}

/// 是否含假名（平假名 / 片假名 / 半角片假名）。用来区分中文和日语歌词行。
bool containsKana(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x3041 && rune <= 0x309F) ||
        (rune >= 0x30A0 && rune <= 0x30FF) ||
        (rune >= 0x31F0 && rune <= 0x31FF) ||
        (rune >= 0xFF66 && rune <= 0xFF9F)) {
      return true;
    }
  }
  return false;
}

/// 当前注音设置；核心还没返回时按关闭处理。
final lyricsRubyProvider = Provider<LyricsRubyMode>((ref) {
  final value = ref.watch(settingProvider(SettingKeys.lyricsRuby)).value;
  return LyricsRubyMode.fromStorage(value);
});

// ---------------------------------------------------------------------------
// 注音结果缓存
// ---------------------------------------------------------------------------

/// 「模式 + 歌词行」→ 注音区间。
///
/// 一行几十个汉字，核心算一次是微秒级，但经典歌词在滚动时每帧都要重绘
/// 几十行，所以结果必须缓存。上限按「一首歌的行数 × 2」估，够翻几首歌，
/// 超了整表清空（比 LRU 便宜，且这里的复用是强局部的）。
final Map<(LyricsRubyMode, String), List<rust.RubySpanDto>> _rubyCache = {};
const int _rubyCacheLimit = 1200;

/// 取一行歌词的注音区间；关闭注音、语言不匹配、或者核心还不能用时返回空列表。
///
/// 中文拼音只作用于不带假名的行，日语注音只作用于带假名的行：一个全局
/// 开关同时服务两种语言，靠这一条把「日文汉字被标成中文拼音」的误伤挡掉。
/// 核心不可用（首帧、测试环境、桥接没初始化）时直接降级成「不注音」，
/// 不让一行歌词的装饰把整个播放页搞崩。
List<rust.RubySpanDto> rubySpansFor(String text, LyricsRubyMode mode) {
  if (!mode.enabled || text.isEmpty) return const [];
  if (mode.japanese != containsKana(text)) return const [];
  final key = (mode, text);
  final cached = _rubyCache[key];
  if (cached != null) return cached;
  List<rust.RubySpanDto> spans;
  try {
    spans = mode.japanese
        ? rust
              .lyricRubyJaLines(lines: [text], style: mode.japaneseStyle)
              .first
              .spans
        : rust.lyricRubyLines(lines: [text], style: mode.rustStyle).first.spans;
  } catch (_) {
    // 桥接还没就绪：当作没有注音，下一帧会重试。
    return const [];
  }
  if (_rubyCache.length >= _rubyCacheLimit) _rubyCache.clear();
  _rubyCache[key] = spans;
  return spans;
}

/// 测试用：清空缓存。
@visibleForTesting
void debugClearRubyCache() => _rubyCache.clear();

// ---------------------------------------------------------------------------
// 排版
// ---------------------------------------------------------------------------

/// 注音占用的上方高度（相对正文字号）。
///
/// 拼音音节最多 6 个字母（`zhuang`），日语振假名 / 罗马音也按 0.42× 字号、
/// 行高 1.15 画，0.52 倍字号的高度足够且不显得空。
double rubyInsetFor(TextStyle base) => (base.fontSize ?? 16) * 0.52;

/// 注音字号。
TextStyle rubyStyleFor(TextStyle base, Color color) => base.copyWith(
  fontSize: (base.fontSize ?? 16) * 0.42,
  height: 1.15,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
  color: color,
);

/// 只画注音、不画正文的图层。放进 `Stack` 里用 `Positioned.fill` 包住，
/// 正文由调用方自己的 `Text` 负责（并且要留出 [topInset] 的上边距）。
class RubyOverlay extends ConsumerWidget {
  const RubyOverlay({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.opacity,
    this.topInset = 0,
  });

  final String text;
  final TextStyle baseStyle;

  /// 跟随正文的透明度（经典歌词用颜色透明做淡出）。
  final double opacity;

  /// 正文上方为注音留出的高度，见 [rubyInsetFor]。
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(lyricsRubyProvider);
    final spans = rubySpansFor(text, mode);
    if (spans.isEmpty) return const SizedBox.shrink();
    final fg = baseStyle.color ?? const Color(0xFFFFFFFF);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _RubyPainter(
            text: text,
            spans: spans,
            baseStyle: baseStyle,
            rubyStyle: rubyStyleFor(
              baseStyle,
              fg.withValues(alpha: fg.a * opacity * 0.78),
            ),
            topInset: topInset,
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

/// 带注音的歌词正文：自动在上方为注音留出高度。
///
/// [opacity] 跟随经典歌词的淡入淡出（颜色透明），不会触发 saveLayer。
class RubyLyricText extends ConsumerWidget {
  const RubyLyricText({
    super.key,
    required this.text,
    required this.style,
    required this.opacity,
    this.maxLines,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle style;
  final double opacity;
  final int? maxLines;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(lyricsRubyProvider).enabled) {
      return Text(text, style: style, maxLines: maxLines, textAlign: textAlign);
    }
    final inset = rubyInsetFor(style);
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(top: inset),
          child: Text(
            text,
            style: style,
            maxLines: maxLines,
            textAlign: textAlign,
          ),
        ),
        Positioned.fill(
          child: RubyOverlay(
            text: text,
            baseStyle: style,
            opacity: opacity,
            topInset: inset,
          ),
        ),
      ],
    );
  }
}

/// 一个待绘制的注音：字形框 [box]（已带 [topInset]）和它的读法。
@immutable
class RubyAnchor {
  const RubyAnchor(this.box, this.ruby);

  final Rect box;
  final String ruby;

  @override
  bool operator ==(Object other) =>
      other is RubyAnchor && other.box == box && other.ruby == ruby;

  @override
  int get hashCode => Object.hash(box, ruby);

  @override
  String toString() => 'RubyAnchor($box, $ruby)';
}

/// 把「UTF-16 区间」换算成「画布上的字框」。
///
/// 抽出来是为了能单独测：注音错位是这个功能唯一的真 bug 风险，而错位只能
/// 从「偏移 → 字框」这一步看出来。一个字被换行拆成两个框时两个框都会返回。
@visibleForTesting
List<RubyAnchor> rubyAnchorRects(
  TextPainter base,
  List<rust.RubySpanDto> spans,
  String text, {
  double topInset = 0,
}) {
  final out = <RubyAnchor>[];
  for (final span in spans) {
    if (span.end <= span.start || span.end > text.length) continue;
    final boxes = base.getBoxesForSelection(
      TextSelection(baseOffset: span.start, extentOffset: span.end),
    );
    for (final box in boxes) {
      final rect = box.toRect().shift(Offset(0, topInset));
      if (rect.isEmpty) continue;
      out.add(RubyAnchor(rect, span.ruby));
    }
  }
  return out;
}

class _RubyPainter extends CustomPainter {
  _RubyPainter({
    required this.text,
    required this.spans,
    required this.baseStyle,
    required this.rubyStyle,
    required this.topInset,
    required this.textScaler,
    required this.locale,
    required this.textDirection,
  });

  final String text;
  final List<rust.RubySpanDto> spans;
  final TextStyle baseStyle;
  final TextStyle rubyStyle;
  final double topInset;
  final TextScaler textScaler;
  final Locale? locale;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (spans.isEmpty || size.width <= 0) return;
    // 和正文完全相同的排版参数，只为了拿字框。
    final base = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: size.width);
    final anchors = rubyAnchorRects(base, spans, text, topInset: topInset);
    for (final rect in anchors) {
      final label = TextPainter(
        text: TextSpan(text: rect.ruby, style: rubyStyle),
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      label.paint(
        canvas,
        Offset(
          rect.box.center.dx - label.width / 2,
          rect.box.top - label.height,
        ),
      );
      label.dispose();
    }
    base.dispose();
  }

  @override
  bool shouldRepaint(_RubyPainter old) =>
      !identical(old.spans, spans) ||
      old.text != text ||
      old.baseStyle != baseStyle ||
      old.rubyStyle != rubyStyle ||
      old.topInset != topInset ||
      old.textScaler != textScaler ||
      old.locale != locale ||
      old.textDirection != textDirection;
}
