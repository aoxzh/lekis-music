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
// textDirection / textHeightBehavior），否则拼音会和字错位——带注音的行
// 一律从 [rubyLineLayoutFor] 拿正文样式。

import 'dart:math' as math;

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

/// 测试用：测试环境没有 Rust 核心，直接把一行的注音结果塞进缓存。
@visibleForTesting
void debugSeedRubySpans(
  String text,
  LyricsRubyMode mode,
  List<rust.RubySpanDto> spans,
) => _rubyCache[(mode, text)] = spans;

// ---------------------------------------------------------------------------
// 排版
// ---------------------------------------------------------------------------
//
// 注音带要留在**每一个折行**的上方，而不只是整段最上面：
//
//   * 正文行高 = 原行高 + 注音带（[rubyBandFor]），折行之间也空出一条注音带，
//     第二行的拼音不会压到第一行的字上；
//   * [RubyLineLayout.heightBehavior] 关掉首行上沿和末行下沿的行高：首行上方
//     由 [RubyLineLayout.inset] 的 padding 留出注音带，末行下方保持字体自然
//     下沿，带注音的行底部不会平白多出半条带；
//   * 注音摆在每个字自然字框（不含行距）的顶上，字体自报 ascent 过高时
//     按该折行基线以上 0.92em 封顶；
//   * 同一行里比字宽的注音（`zhuang`、`itadaki`）成簇向两侧推开，不互相压。
//
// 所有尺寸都按 `TextScaler` 放大后的字号算：系统字号 / 歌词字号调大时，
// 留白一起变大。

/// 注音字号相对正文字号。
const double _rubyFontFactor = 0.42;

/// 注音文字的行高倍数。
const double _rubyLineHeight = 1.15;

/// 注音和正文之间的缝（相对正文字号）。
const double _rubyGapFactor = 0.037;

/// 正文字形顶边距基线的上限（相对字号）。CJK 字体的表意字框顶在 0.88em
/// 左右，而字体自报的 ascent 常常更高（Noto CJK 约 1.16em），直接贴着
/// ascent 注音会飘得离字很远、也更费行距。
const double _rubyInkAscent = 0.92;

/// 带注音时正文行高（不含注音带）的下限 / 缺省值：保证上一折行的下伸部
/// 碰不到下一折行的注音。
const double _rubyMinBodyHeight = 1.15;
const double _rubyDefaultBodyHeight = 1.2;

/// 带注音时正文额外加的字距（相对字号），给比字宽的注音一点横向余地。
const double _rubyTracking = 0.04;

/// 相邻两条注音之间至少留的空（相对注音字号）。
const double _rubyLabelSpacing = 0.25;

double _fontSizeOf(TextStyle style) => style.fontSize ?? 16;

/// 一条注音带的高度：注音文字本身 + 与正文之间的缝，已按 [scaler] 放大。
double rubyBandFor(
  TextStyle base, [
  TextScaler scaler = TextScaler.noScaling,
]) {
  final size = _fontSizeOf(base);
  return scaler.scale(size * _rubyFontFactor) * _rubyLineHeight +
      scaler.scale(size) * _rubyGapFactor;
}

/// 注音占用的上方高度（首行上方的留白），等于一条 [rubyBandFor]。
double rubyInsetFor(
  TextStyle base, [
  TextScaler scaler = TextScaler.noScaling,
]) => rubyBandFor(base, scaler);

/// 注音字号。
TextStyle rubyStyleFor(TextStyle base, Color color) => base.copyWith(
  fontSize: _fontSizeOf(base) * _rubyFontFactor,
  height: _rubyLineHeight,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
  color: color,
);

/// 一行带注音的歌词怎么排。
///
/// 正文 `Text`、卡拉 OK 的 `TextPainter` 和 [RubyOverlay] 必须用同一份
/// [style] + [heightBehavior]，否则注音会和字错位。
@immutable
class RubyLineLayout {
  const RubyLineLayout({required this.style, required this.inset});

  /// 正文样式：行高加上一条注音带，字距略放宽。
  final TextStyle style;

  /// 首行上方为注音留的高度。
  final double inset;

  /// 首行上沿、末行下沿不吃行高：首行的注音带由 [inset] 给，末行下方
  /// 不多留。
  static const TextHeightBehavior heightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  @override
  bool operator ==(Object other) =>
      other is RubyLineLayout && other.style == style && other.inset == inset;

  @override
  int get hashCode => Object.hash(style, inset);
}

/// [base] 是不带注音时的正文样式；[scaler] 是正文实际用的 `TextScaler`。
RubyLineLayout rubyLineLayoutFor(TextStyle base, TextScaler scaler) {
  final scaled = scaler.scale(_fontSizeOf(base));
  final band = rubyBandFor(base, scaler);
  final body = math.max(
    base.height ?? _rubyDefaultBodyHeight,
    _rubyMinBodyHeight,
  );
  return RubyLineLayout(
    style: base.copyWith(
      height: body + (scaled > 0 ? band / scaled : 0),
      letterSpacing: (base.letterSpacing ?? 0) + scaled * _rubyTracking,
    ),
    inset: band,
  );
}

/// 只画注音、不画正文的图层。放进 `Stack` 里用 `Positioned.fill` 包住，
/// 正文由调用方自己的 `Text` 负责：正文要留出 [topInset] 的上边距，并且
/// 和 [baseStyle] / [textHeightBehavior] / [textAlign] / [maxLines] 完全一致
/// （带注音时用 [rubyLineLayoutFor] 的结果）。
class RubyOverlay extends ConsumerWidget {
  const RubyOverlay({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.opacity,
    this.topInset = 0,
    this.textHeightBehavior = RubyLineLayout.heightBehavior,
    this.textAlign = TextAlign.start,
    this.maxLines,
  });

  final String text;
  final TextStyle baseStyle;

  /// 跟随正文的透明度（经典歌词用颜色透明做淡出）。
  final double opacity;

  /// 正文上方为注音留出的高度，见 [rubyInsetFor]。
  final double topInset;

  final TextHeightBehavior textHeightBehavior;
  final TextAlign textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(lyricsRubyProvider);
    final spans = rubySpansFor(text, mode);
    if (spans.isEmpty) return const SizedBox.shrink();
    final fg = baseStyle.color ?? const Color(0xFFFFFFFF);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: RubyPainter(
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
            textHeightBehavior: textHeightBehavior,
            textAlign: textAlign,
            maxLines: maxLines,
          ),
        ),
      ),
    );
  }
}

/// 带注音的歌词正文：有注音的行在每个折行上方都留出注音带；没有注音的行
/// （注音关闭、语言不匹配、核心未就绪）就是普通 `Text`，和以前完全一样。
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
    final spans = rubySpansFor(text, ref.watch(lyricsRubyProvider));
    if (spans.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, textAlign: textAlign);
    }
    final layout = rubyLineLayoutFor(style, MediaQuery.textScalerOf(context));
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(top: layout.inset),
          child: Text(
            text,
            style: layout.style,
            textHeightBehavior: RubyLineLayout.heightBehavior,
            maxLines: maxLines,
            textAlign: textAlign,
          ),
        ),
        Positioned.fill(
          child: RubyOverlay(
            text: text,
            baseStyle: layout.style,
            opacity: opacity,
            topInset: layout.inset,
            textAlign: textAlign,
            maxLines: maxLines,
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

/// 一条摆好位置的注音（画布坐标，已含 topInset）。
@immutable
class RubyLabel {
  const RubyLabel(this.rect, this.ruby, this.line);

  final Rect rect;
  final String ruby;

  /// 所在的折行（从 0 开始）。
  final int line;

  @override
  String toString() => 'RubyLabel($rect, $ruby, line $line)';
}

/// 摆放过程中的一条注音。
class _Placed {
  _Placed(this.painter, this.ruby, this.line, this.center, this.bottom);

  final TextPainter painter;
  final String ruby;
  final int line;

  /// 理想的水平中心（字框中心）。
  final double center;
  final double bottom;
  late double left = center - width / 2;

  double get width => painter.width;
  Rect get rect =>
      Rect.fromLTWH(left, bottom - painter.height, width, painter.height);
}

/// 一簇挨着的注音：整体居中在各自理想位置的平均处（位移平方和最小）。
class _Cluster {
  _Cluster(_Placed p)
    : items = [p],
      width = p.width,
      _sum = p.center - p.width / 2,
      _count = 1 {
    left = math.max(0, _sum);
  }

  final List<_Placed> items;
  double width;

  /// Σ（每条注音的理想左边 − 它在簇里的偏移）。
  double _sum;
  int _count;
  late double left;

  double get right => left + width;

  _Cluster absorb(_Cluster next, double spacing) {
    final shift = width + spacing;
    _sum += next._sum - next._count * shift;
    _count += next._count;
    items.addAll(next.items);
    width += spacing + next.width;
    left = math.max(0, _sum / _count);
    return this;
  }
}

/// 同一折行里的注音从左到右排，重叠的并成一簇推开，再夹进 `[0, width]`。
void _spreadRow(List<_Placed> row, double spacing, double width) {
  row.sort((a, b) => a.center.compareTo(b.center));
  final clusters = <_Cluster>[];
  for (final p in row) {
    var c = _Cluster(p);
    while (clusters.isNotEmpty && clusters.last.right + spacing > c.left) {
      c = clusters.removeLast().absorb(c, spacing);
    }
    clusters.add(c);
  }
  var limit = width;
  for (var i = clusters.length - 1; i >= 0; i--) {
    final c = clusters[i];
    if (c.right > limit) c.left = math.max(0, limit - c.width);
    limit = c.left - spacing;
  }
  for (final c in clusters) {
    var x = c.left;
    for (final p in c.items) {
      p.left = x;
      x += p.width + spacing;
    }
  }
}

/// 画注音的 painter。公开只是为了测试能拿到 [labels] 检查摆放。
class RubyPainter extends CustomPainter {
  RubyPainter({
    required this.text,
    required this.spans,
    required this.baseStyle,
    required this.rubyStyle,
    required this.topInset,
    required this.textScaler,
    required this.locale,
    required this.textDirection,
    this.textHeightBehavior = RubyLineLayout.heightBehavior,
    this.textAlign = TextAlign.start,
    this.maxLines,
  });

  final String text;
  final List<rust.RubySpanDto> spans;
  final TextStyle baseStyle;
  final TextStyle rubyStyle;
  final double topInset;
  final TextScaler textScaler;
  final Locale? locale;
  final TextDirection textDirection;
  final TextHeightBehavior textHeightBehavior;
  final TextAlign textAlign;
  final int? maxLines;

  List<_Placed> _place(double width) {
    if (spans.isEmpty || width <= 0) return const [];
    // 和正文完全相同的排版参数，只为了拿字框和每个折行的基线。
    final base = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      textAlign: textAlign,
      maxLines: maxLines,
      textHeightBehavior: textHeightBehavior,
    )..layout(maxWidth: width);
    final anchors = rubyAnchorRects(base, spans, text);
    final lines = base.computeLineMetrics();
    base.dispose();
    if (anchors.isEmpty || lines.isEmpty) return const [];

    final size = _fontSizeOf(baseStyle);
    final scaled = textScaler.scale(size);
    final gap = scaled * _rubyGapFactor;
    final spacing =
        textScaler.scale(size * _rubyFontFactor) * _rubyLabelSpacing;
    final rows = <int, List<_Placed>>{};
    for (final anchor in anchors) {
      final y = anchor.box.center.dy;
      var row = lines.length - 1;
      for (var i = 0; i < lines.length; i++) {
        if (y <= lines[i].baseline + lines[i].descent) {
          row = i;
          break;
        }
      }
      // 默认（tight）字框就是字体自然的 ascent / descent，不含行高带来的
      // 行距（`LineMetrics.ascent / unscaledAscent` 都含行距，不能用）；字体
      // 自报的 ascent 太高时按 0.92em 封顶，注音贴近字形。
      final ink = math.max(
        anchor.box.top,
        lines[row].baseline - scaled * _rubyInkAscent,
      );
      final label = TextPainter(
        text: TextSpan(text: anchor.ruby, style: rubyStyle),
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      rows
          .putIfAbsent(row, () => [])
          .add(
            _Placed(
              label,
              anchor.ruby,
              row,
              anchor.box.center.dx,
              topInset + ink - gap / 2,
            ),
          );
    }
    final out = <_Placed>[];
    for (final row in rows.values) {
      _spreadRow(row, spacing, width);
      out.addAll(row);
    }
    return out;
  }

  /// 注音在画布上的位置。测试用它检查注音不压字、不互压。
  @visibleForTesting
  List<RubyLabel> labels(Size size) {
    final placed = _place(size.width);
    final out = [for (final p in placed) RubyLabel(p.rect, p.ruby, p.line)];
    for (final p in placed) {
      p.painter.dispose();
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _place(size.width)) {
      p.painter.paint(canvas, p.rect.topLeft);
      p.painter.dispose();
    }
  }

  @override
  bool shouldRepaint(RubyPainter old) =>
      !identical(old.spans, spans) ||
      old.text != text ||
      old.baseStyle != baseStyle ||
      old.rubyStyle != rubyStyle ||
      old.topInset != topInset ||
      old.textScaler != textScaler ||
      old.locale != locale ||
      old.textDirection != textDirection ||
      old.textHeightBehavior != textHeightBehavior ||
      old.textAlign != textAlign ||
      old.maxLines != maxLines;
}
