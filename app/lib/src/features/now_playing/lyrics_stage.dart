// 歌词舞台（可选；默认是经典视图）。照 egoist/mygo-music 的舞台重做，那边
// 又源自 Folia 的可视化：
//
// * 流动（Flow）：一次只有一句，占满整个舞台。句子按种子靠左 / 居中 /
//   靠右，略高或略低；每个词有自己的随机偏移、倾角和大小。词在唱到时才
//   从侧边、半大、模糊、转着的样子弹簧般落位，放大到 1.4 倍、亮起并带一圈
//   强调色光晕；唱完后缩回、变暗，慢慢漂移着转一点角度。
// * 阶梯（Steps，mygo 的「云阶」）：一句拆成几行错落的台阶，每行在它的
//   第一个词到来时从引导线一侧滑入，行下画一个直角引导线，唱时亮起强调色。
// * 倾斜（Tilt，mygo 的「倾诉」）：一句拆成一到四个大号短行，其中一行是
//   细斜体的强调色、字上下交错；字在被唱到时鼓起再回落，略大一点停住。
//
// 上一句在新句到来时 0.4 秒内淡出；长间奏显示三颗随进度点亮的呼吸点；
// 底部是翻译和下一句。
//
// 性能（mygo 用的是「只在会变时才要下一帧」，这里同样）：
// * 每句只在切换时排版一次（每个词 / 字一个 TextPainter）；之后每帧只做
//   canvas 变换和 drawParagraph，不重建 widget、不做布局。
// * 透明度、模糊、光晕不用 saveLayer：同一个词按量化后的透明度 / 模糊
//   半径缓存几份段落（[_Glyph]），每帧挑一份画。整块舞台没有 ShaderMask。
// * 时钟 [LyricsClock] 外推播放位置；只有弹簧 / 光晕 / 火花在动时才跑
//   Ticker（按屏幕刷新率，不节流以免 120Hz 下抖动），漂移阶段 10fps，
//   静止时等到下一个词再醒。暂停、手动浏览、低电量都不跑 Ticker。
// * 画布包在 RepaintBoundary 里，只有它自己重绘。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_classic.dart'
    show LyricsClock;
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 底部翻译 / 下一句预留的高度。
const double _footerReserve = 96;

/// 手动翻阅后自动回到当前句的等待时间。
const Duration _manualResume = Duration(seconds: 3);

/// 词提前多久开始进场（秒）。倾斜样式更早露出整行。
const double _flowLead = 0.08;
const double _tiltLead = 0.25;

/// 上一句淡出的时长（秒）。
const double _lineGone = 0.4;

/// 一个词的火花飞多久（秒）。
const double _sparkTime = 0.6;

/// 一句唱完后，离下一句还有这么久（秒）才显示间奏呼吸点。
const double _interludeGap = 4;

/// 透明度量化的级数：同一个词最多缓存这么多份不同透明度的段落。
const int _alphaSteps = 32;

const double _deg = math.pi / 180;

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _easeOutCubic(double t) {
  t = _clamp01(t);
  final u = 1 - t;
  return 1 - u * u * u;
}

double _easeOutQuad(double t) {
  t = _clamp01(t);
  return 1 - (1 - t) * (1 - t);
}

/// 刚度 200、阻尼 20 的弹簧（Folia / mygo 的参数）：略过冲，约半秒停稳。
double _springStep(double t) {
  if (t <= 0) return 0;
  final e = math.exp(-10 * t);
  return 1 - e * (math.cos(10 * t) + math.sin(10 * t));
}

/// 以句子和词为种子的小随机数：同一句每次出现都排得一样。
double _rand(double seed, double offset) {
  final x = math.sin(seed + offset) * 10000;
  return x - x.floorToDouble();
}

final RegExp _markRe = RegExp(r'[\p{P}\p{Z}\s]', unicode: true);
final RegExp _onlyMarksRe = RegExp(r'^[\p{P}\p{Z}\s]*$', unicode: true);
final RegExp _punctRe = RegExp(r'\p{P}', unicode: true);

bool _isSpaceRune(int r) => r == 0x20 || r == 0x09 || r == 0x3000;

bool _isCjk(int r) =>
    (r >= 0x3040 && r <= 0x30ff) || // かな
    (r >= 0x3400 && r <= 0x9fff) || // 汉字
    (r >= 0xac00 && r <= 0xd7af) || // 谚文
    (r >= 0xf900 && r <= 0xfaff);

// ---------------------------------------------------------------------------
// 时间轴
// ---------------------------------------------------------------------------

/// 舞台上的一个词，时间以秒计。
class _Word {
  const _Word(this.text, this.start, this.end, {required this.spaceAfter});

  final String text;
  final double start;
  final double end;

  /// 原文里这个词后面有空格（英文词之间）。
  final bool spaceAfter;

  /// 至少唱 0.15 秒。
  double get sungEnd => math.max(end, start + 0.15);
}

/// 舞台上的一句（空行已去掉）。
class _StageLine {
  _StageLine(this.line, this.words, this.end);

  final LyricLine line;
  final List<_Word> words;

  /// 这一句唱完的时间（秒）。
  final double end;

  double get start => line.startMs / 1000;
}

/// 没有逐字时间的行：中日韩每个字一个词，其余按空格分词，按字数分掉这句
/// 85% 的时长（最后一点留给换气，mygo 的做法）。
List<_Word> _spreadWords(String text, double start, double end) {
  final words = <(String, bool)>[];
  final cur = StringBuffer();
  void flush(bool space) {
    if (cur.isEmpty) return;
    words.add((cur.toString(), space));
    cur.clear();
  }

  for (final r in text.runes) {
    if (_isSpaceRune(r)) {
      flush(true);
    } else if (_isCjk(r)) {
      flush(false);
      words.add((String.fromCharCode(r), false));
    } else {
      cur.writeCharCode(r);
    }
  }
  flush(false);
  if (words.isEmpty) return const [];
  var total = 0;
  for (final w in words) {
    total += w.$1.runes.length;
  }
  final span = (end - start) * 0.85;
  var at = start;
  return [
    for (final w in words)
      () {
        final d = span * w.$1.runes.length / math.max(total, 1);
        final word = _Word(w.$1, at, at + d, spaceAfter: w.$2);
        at += d;
        return word;
      }(),
  ];
}

List<_StageLine> _stageLines(ParsedLyrics lyrics) {
  final src = lyrics.lines;
  final out = <_StageLine>[];
  for (var i = 0; i < src.length; i++) {
    final line = src[i];
    if (line.isInstrumental || line.startMs < 0) continue;
    final start = line.startMs / 1000;
    // 下一行（包括空行：空行就是这一句结束的地方）。
    final next = i + 1 < src.length ? src[i + 1].startMs / 1000 : null;
    var words = <_Word>[];
    if (line.hasWordTimings) {
      final raw = line.words!;
      for (var k = 0; k < raw.length; k++) {
        final w = raw[k];
        final text = w.text.trim();
        if (text.isEmpty) {
          if (words.isNotEmpty) {
            final last = words.removeLast();
            words.add(_Word(last.text, last.start, last.end, spaceAfter: true));
          }
          continue;
        }
        var end = w.endMs / 1000;
        // 句尾词的结束时间常被推到下一句；给它一个自然的上限。
        if (k == raw.length - 1) end = math.min(end, w.startMs / 1000 + 2.5);
        words.add(
          _Word(
            text,
            w.startMs / 1000,
            math.max(end, w.startMs / 1000),
            spaceAfter: w.text != w.text.trimRight(),
          ),
        );
      }
    }
    if (words.isEmpty) {
      final end = math.min(start + 6, next ?? start + 6);
      words = _spreadWords(line.text.trim(), start, math.max(end, start + 1));
    }
    if (words.isEmpty) continue;
    out.add(_StageLine(line, words, words.last.sungEnd));
  }
  return out;
}

/// [ms] 时刻在唱的句子；-1 表示第一句之前。
int _indexAt(List<_StageLine> lines, double ms) {
  var lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].line.startMs <= ms) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

int _charCount(Iterable<_Word> words) {
  var n = 0;
  for (final w in words) {
    n += w.text.runes.length;
  }
  return n;
}

// ---------------------------------------------------------------------------
// 字形缓存
// ---------------------------------------------------------------------------

/// 去掉颜色的文字样式（颜色 / 前景画笔在 [_Glyph] 里按需填）。
TextStyle _bare(
  TextStyle base,
  double size,
  FontWeight weight, {
  double height = 1.15,
  FontStyle? fontStyle,
}) => TextStyle(
  fontFamily: base.fontFamily,
  fontFamilyFallback: base.fontFamilyFallback,
  locale: base.locale,
  fontSize: size,
  fontWeight: weight,
  fontStyle: fontStyle,
  height: height,
  letterSpacing: 0,
);

/// 一个词（或一个字）的排版。尺寸只量一次；画的时候按量化后的颜色透明度
/// 和模糊半径取一份缓存的段落，代替每帧 saveLayer。
class _Glyph {
  _Glyph(this.text, this.style) {
    final probe = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    width = probe.width;
    height = probe.height;
    probe.dispose();
  }

  final String text;
  final TextStyle style;
  late final double width;
  late final double height;
  final Map<int, TextPainter> _cache = {};

  Offset get _origin => Offset(-width / 2, -height / 2);

  /// 以原点为中心，用 [color] × [alpha] 画出来；[blur] 是遮罩模糊的
  /// sigma。[tone] 区分不同颜色来源（正文 / 强调色），缓存按它分开。
  void paint(
    Canvas canvas,
    Color color,
    double alpha, {
    double blur = 0,
    int tone = 0,
  }) {
    final a = (_clamp01(alpha) * _alphaSteps).round();
    if (a <= 0) return;
    final b = blur < 0.4 ? 0 : blur.round().clamp(1, 24);
    final key = (tone << 16) | (b << 8) | a;
    final painter = _cache[key] ??= _make(
      color.withValues(alpha: color.a * a / _alphaSteps),
      b,
    );
    painter.paint(canvas, _origin);
  }

  TextPainter _make(Color color, int blur) {
    final s = blur == 0
        ? style.copyWith(color: color)
        : style.copyWith(
            foreground: Paint()
              ..color = color
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur.toDouble()),
          );
    return TextPainter(
      text: TextSpan(text: text, style: s),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  void dispose() {
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }
}

// ---------------------------------------------------------------------------
// 排版
// ---------------------------------------------------------------------------

/// 一个词的站位：偏移、倾角（度）、大小、唱完后的漂移角（度）和右边距。
class _Shape {
  _Shape(this.x, this.y, this.rot, this.scale, this.drift);

  final double x, y, rot, scale, drift;
  double margin = 0;
}

/// 给每个词后面留出位置：唱时放大 1.4 倍不会撞到下一个词（mygo 的
/// spaceWords）。
void _spaceWords(List<_Shape> shapes, List<double> widths, double gap) {
  for (var i = 0; i < shapes.length; i++) {
    final grow = widths[i] * (shapes[i].scale * 1.4 - 1) / 2;
    var next = 0.0, toward = 0.0;
    if (i + 1 < shapes.length) {
      next = widths[i + 1] * (shapes[i + 1].scale * 1.4 - 1) / 2;
      toward = shapes[i].x - shapes[i + 1].x;
    }
    shapes[i].margin = math.max(2 * gap, grow + next + toward + gap);
  }
}

/// 流动 / 阶梯里的一个词。
class _Placed {
  _Placed(this.glyph, this.word, this.shape, this.center, {this.row = 0});

  final _Glyph glyph;
  final _Word word;
  final _Shape shape;

  /// 排版位置的中心（阶梯里不含行的错位）。
  final Offset center;
  final int row;
  bool last = false;
}

/// 阶梯的一行。
class _Row {
  _Row({
    required this.rect,
    required this.offset,
    required this.left,
    required this.start,
    required this.end,
  });

  /// 排版位置（含内边距），错位前。
  final Rect rect;

  /// 静止时相对排版位置的错位。
  final Offset offset;

  /// 引导线在左边，从左边滑入。
  final bool left;

  /// 第一个词进场（已减去提前量） / 最后一个词唱完的时间。
  final double start;
  final double end;
}

/// 倾斜里的一个字。
class _TiltChar {
  _TiltChar({
    required this.glyph,
    required this.part,
    required this.center,
    required this.start,
    required this.duration,
    required this.k,
    required this.spark,
    required this.sparkLast,
    required this.wordStart,
  });

  final _Glyph glyph;
  final int part;
  final Offset center;

  /// 这个字被唱到的时间、鼓起的时长（秒）。
  final double start;
  final double duration;

  /// 在这一行里是第几个字（依次淡入）。
  final int k;
  final bool spark;
  final bool sparkLast;
  final double wordStart;
}

/// 倾斜的一行。
class _TiltPart {
  _TiltPart({
    required this.rect,
    required this.lean,
    required this.start,
    required this.chars,
  });

  final Rect rect;
  final bool lean;

  /// 这一行开始进场的时间（第一个词前 [_tiltLead]）。
  final double start;
  final int chars;
}

/// 一句排好的样子。
class _LineArt {
  _LineArt({
    required this.line,
    required this.fontSize,
    required this.glyphs,
    this.words = const [],
    this.rows = const [],
    this.chars = const [],
    this.parts = const [],
    this.fit = 1,
  });

  final _StageLine line;
  final double fontSize;
  final List<_Glyph> glyphs;
  final List<_Placed> words;
  final List<_Row> rows;
  final List<_TiltChar> chars;
  final List<_TiltPart> parts;

  /// 小于 1 表示放不下，需要按这个比例缩小字号重排。
  final double fit;

  /// 需要逐帧绘制的时间段（弹簧、光晕、火花），以及只需慢速刷新的漂移段。
  final List<(double, double)> hot = [];
  final List<(double, double)> drift = [];

  /// 点中的词的开始时间（秒）。
  double? hit(Offset p) {
    for (final w in words) {
      final rowOffset = rows.isEmpty ? Offset.zero : rows[w.row].offset;
      final c = w.center + rowOffset + Offset(w.shape.x, w.shape.y);
      final r = Rect.fromCenter(
        center: c,
        width: w.glyph.width * w.shape.scale,
        height: w.glyph.height * w.shape.scale,
      ).inflate(10);
      if (r.contains(p)) return w.word.start;
    }
    for (final ch in chars) {
      final r = Rect.fromCenter(
        center: ch.center,
        width: ch.glyph.width,
        height: ch.glyph.height,
      ).inflate(8);
      if (r.contains(p)) return ch.wordStart;
    }
    return null;
  }

  void dispose() {
    for (final g in glyphs) {
      g.dispose();
    }
  }
}

/// 流动：词按种子散开，整句靠左 / 居中 / 靠右，略高或略低。
_LineArt _layoutFlow(_StageLine l, Size size, TextStyle base, double f) {
  final style = _bare(base, f, FontWeight.w800);
  final seed = l.line.startMs.toDouble();
  final glyphs = [for (final w in l.words) _Glyph(w.text, style)];
  final widths = [for (final g in glyphs) g.width];
  final j = f * 0.6;
  final shapes = [
    for (var i = 0; i < glyphs.length; i++)
      _Shape(
        (_rand(seed + i, 1) - 0.5) * j,
        (_rand(seed + i, 2) - 0.5) * j,
        (_rand(seed + i, 3) - 0.5) * 10,
        1.1 + _rand(seed + i, 4) * 0.2,
        (_rand(seed + i, 5) - 0.5) * 10,
      ),
  ];
  _spaceWords(shapes, widths, f * 0.08);

  // 折行：左右各留 10%。
  final pad = size.width * 0.1;
  final avail = size.width - 2 * pad;
  final rows = <List<int>>[];
  var cur = <int>[];
  var x = 0.0;
  for (var i = 0; i < glyphs.length; i++) {
    if (cur.isNotEmpty && x + widths[i] > avail) {
      rows.add(cur);
      cur = [];
      x = 0;
    }
    cur.add(i);
    x += widths[i] + shapes[i].margin;
  }
  if (cur.isNotEmpty) rows.add(cur);

  double rowWidth(List<int> r) {
    var w = 0.0;
    for (final i in r) {
      w += widths[i] + shapes[i].margin;
    }
    return w - shapes[r.last].margin;
  }

  final rowGap = f * 0.3;
  var total = 0.0, widest = 0.0;
  final heights = <double>[];
  for (final r in rows) {
    var h = 0.0;
    for (final i in r) {
      h = math.max(h, glyphs[i].height);
    }
    heights.add(h);
    total += h;
    widest = math.max(widest, rowWidth(r));
  }
  total += rowGap * math.max(0, rows.length - 1);

  final justify = l.line.startMs % 3;
  const lifts = [-0.14, 0.0, 0.12];
  final lift = lifts[(l.line.startMs * 2) % 3] * size.height;
  final margin = f * 0.9;
  var top = (size.height - total) / 2 + lift;
  top = top.clamp(margin, math.max(margin, size.height - total - margin));

  final placed = <_Placed>[];
  var y = top;
  for (var r = 0; r < rows.length; r++) {
    final rw = rowWidth(rows[r]);
    var cursor = switch (justify) {
      0 => pad,
      1 => (size.width - rw) / 2,
      _ => size.width - pad - rw,
    };
    for (final i in rows[r]) {
      placed.add(
        _Placed(
          glyphs[i],
          l.words[i],
          shapes[i],
          Offset(cursor + widths[i] / 2, y + heights[r] / 2),
        ),
      );
      cursor += widths[i] + shapes[i].margin;
    }
    y += heights[r] + rowGap;
  }
  if (placed.isNotEmpty) placed.last.last = true;

  final art = _LineArt(
    line: l,
    fontSize: f,
    glyphs: glyphs,
    words: placed,
    fit: math.min(
      1,
      math.min(avail / math.max(widest, 1), size.height * 0.8 / total),
    ),
  );
  _wordTimes(art, _flowLead);
  return art;
}

/// 一个词从进场到光晕散尽要逐帧画；之后五秒在慢慢漂移。
void _wordTimes(_LineArt art, double lead) {
  for (final p in art.words) {
    final w = p.word;
    final start = w.start - lead;
    art.hot.add((start, math.max(start + 0.7, w.sungEnd + 0.9)));
    art.drift.add((w.sungEnd, w.sungEnd + 5));
  }
}

/// mygo 的 stageUnits：把一句切成「单位」，英文一个词一个，中日文到空格
/// 或标点为止的一段（长的四个字一切）。标点跟着前一个单位。
List<(int, int)> _stageUnits(List<_Word> words) {
  final units = <(int, int)>[];
  void phrase(int from, int to) {
    var n = (to - from + 3) ~/ 4;
    if (to - from <= 6) n = 1;
    for (var k = 0; k < n; k++) {
      units.add((
        from + (to - from) * k ~/ n,
        from + (to - from) * (k + 1) ~/ n,
      ));
    }
  }

  var from = 0;
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (i == from && units.isNotEmpty && _onlyMarksRe.hasMatch(w.text)) {
      units[units.length - 1] = (units.last.$1, i + 1);
      from = i + 1;
      continue;
    }
    final runes = w.text.runes;
    final last = runes.isEmpty ? '' : String.fromCharCode(runes.last);
    // 撇号和连字符把词连到下一个（It’s）。
    final joins = "'’-".contains(last) && last.isNotEmpty;
    final breaks = w.spaceAfter || (_markRe.hasMatch(last) && !joins);
    if (i + 1 == words.length || breaks) {
      phrase(from, i + 1);
      from = i + 1;
    }
  }
  return units;
}

/// 阶梯的行规划。
class _RowPlan {
  _RowPlan(this.from, this.to, this.x, this.y, this.scale, this.left);

  final int from, to;
  final double x, y, scale;
  final bool left;
}

/// mygo 的 partitaRows：像手写那样把一句不均匀地分成几行。
List<_RowPlan> _partitaRows(List<_Word> words, double seed, double h) {
  final units = _stageUnits(words);
  if (units.isEmpty) return const [];
  var k = 0.0;
  double random() {
    k++;
    return _rand(seed, k);
  }

  final count = math.min(units.length, math.max(1, (h * 0.65 / 100).floor()));
  final rows = <_RowPlan>[];
  var left = units.length, unit = 0;
  for (var i = 0; i < count; i++) {
    var n = left;
    if (i < count - 1) {
      final avg = left / (count - i);
      n = math.min(
        (avg * 1.5).ceil(),
        math.max(1, (avg + (random() - 0.5) * avg).round()),
      );
    }
    n = math.max(1, math.min(n, left - (count - i - 1)));
    final stagger = 20 + random() * 80;
    final isLeft = i.isEven;
    rows.add(
      _RowPlan(
        units[unit].$1,
        units[unit + n - 1].$2,
        isLeft ? -stagger : stagger,
        (i - (count - 1) / 2) * 2.5,
        0.8 + random() * 0.9,
        isLeft,
      ),
    );
    unit += n;
    left -= n;
  }
  return rows;
}

/// 阶梯：几行错落叠在中间，每行一条直角引导线。
_LineArt _layoutSteps(_StageLine l, Size size, TextStyle base, double f) {
  final style = _bare(base, f, FontWeight.w800);
  final plans = _partitaRows(l.words, l.start, size.height);
  final staggerScale = (size.width / 900).clamp(0.35, 1.0);
  final glyphs = <_Glyph>[];
  final placedRows = <List<(_Glyph, _Word, _Shape)>>[];
  final boxes = <Size>[];
  final margins = <(double, double)>[];
  final overhang = <double>[];
  for (final plan in plans) {
    final words = l.words.sublist(plan.from, plan.to);
    final seed = words.first.start;
    final j = f * 0.25;
    final items = <(_Glyph, _Word, _Shape)>[];
    for (var i = 0; i < words.length; i++) {
      final ws = seed + i * 7.13;
      final g = _Glyph(words[i].text, style);
      glyphs.add(g);
      items.add((
        g,
        words[i],
        _Shape(
          (_rand(ws, 1) - 0.5) * j,
          (_rand(ws, 2) - 0.5) * j,
          (_rand(ws, 3) - 0.5) * 6,
          plan.scale,
          (_rand(ws, 8) - 0.5) * 20,
        ),
      ));
    }
    final shapes = [for (final it in items) it.$3];
    _spaceWords(shapes, [for (final it in items) it.$1.width], f * 0.1);
    shapes.last.margin = 0;
    var w = 0.0, h = 0.0;
    for (final it in items) {
      w += it.$1.width + it.$3.margin;
      h = math.max(h, it.$1.height);
    }
    final grow = math.max(0.0, f * (plan.scale * 1.4 - 1) / 2);
    placedRows.add(items);
    boxes.add(Size(w + 16, h + 6));
    margins.add((grow, grow + 10));
    // 行首、行尾的词唱时放大，会伸出行框。
    final k = (plan.scale * 1.4 - 1) / 2;
    overhang.add((items.first.$1.width + items.last.$1.width) * k);
  }

  var total = 0.0, widest = 0.0;
  for (var r = 0; r < plans.length; r++) {
    total += margins[r].$1 + boxes[r].height + margins[r].$2;
    widest = math.max(
      widest,
      boxes[r].width + overhang[r] + 2 * plans[r].x.abs() * staggerScale + 40,
    );
  }
  var y = (size.height - total) / 2;
  final rows = <_Row>[];
  final placed = <_Placed>[];
  for (var r = 0; r < plans.length; r++) {
    y += margins[r].$1;
    final rect = Rect.fromLTWH(
      (size.width - boxes[r].width) / 2,
      y,
      boxes[r].width,
      boxes[r].height,
    );
    y += boxes[r].height + margins[r].$2;
    final items = placedRows[r];
    final first = items.first.$2, last = items.last.$2;
    rows.add(
      _Row(
        rect: rect,
        offset: Offset(plans[r].x * staggerScale, plans[r].y),
        left: plans[r].left,
        start: first.start - _flowLead,
        end: last.sungEnd,
      ),
    );
    var cursor = rect.left + 8;
    for (final it in items) {
      placed.add(
        _Placed(
          it.$1,
          it.$2,
          it.$3,
          Offset(cursor + it.$1.width / 2, rect.center.dy),
          row: r,
        ),
      );
      cursor += it.$1.width + it.$3.margin;
    }
  }
  if (placed.isNotEmpty) placed.last.last = true;

  final art = _LineArt(
    line: l,
    fontSize: f,
    glyphs: glyphs,
    words: placed,
    rows: rows,
    fit: math.min(
      1,
      math.min(
        size.width * 0.94 / math.max(widest, 1),
        size.height * 0.95 / math.max(total, 1),
      ),
    ),
  );
  _wordTimes(art, _flowLead);
  return art;
}

/// 倾斜的分行规划（词的下标区间）。
class _PartPlan {
  _PartPlan(this.from, this.to);

  final int from, to;
  bool lean = false;
  bool tail = false;
}

/// mygo 的 splitParts：在单位边界上切成 n 行，切点尽量平分字数，更愿意
/// 切在标点后。
List<_PartPlan> _splitParts(List<_Word> words, List<(int, int)> units, int n) {
  final total = _charCount(words).toDouble();
  final before = List<double>.filled(units.length + 1, 0);
  for (var i = 0; i < units.length; i++) {
    before[i + 1] =
        before[i] + _charCount(words.sublist(units[i].$1, units[i].$2));
  }
  final parts = <_PartPlan>[];
  var from = 0;
  for (var k = 1; k < n; k++) {
    var at = -1;
    var best = 0.0;
    for (var cut = from + 1; cut <= units.length - (n - k); cut++) {
      var d = (before[cut] - total * k / n).abs();
      final text = words[units[cut - 1].$2 - 1].text;
      final runes = text.runes;
      if (runes.isNotEmpty &&
          _punctRe.hasMatch(String.fromCharCode(runes.last))) {
        d -= total * 0.15;
      }
      if (at < 0 || d < best) {
        at = cut;
        best = d;
      }
    }
    parts.add(_PartPlan(units[from].$1, units[at - 1].$2));
    from = at;
  }
  parts.add(_PartPlan(units[from].$1, units.last.$2));
  return parts;
}

/// mygo 的 tiltParts：越长的句子分越多行（一到四行），约三行里一行倾斜；
/// 放不下就再多分一行。
List<_PartPlan> _tiltParts(
  List<_Word> words,
  double seed,
  bool Function(List<_PartPlan>) fits,
) {
  final units = _stageUnits(words);
  if (units.isEmpty) return const [];
  final chars = _charCount(words);
  final score =
      math.log(chars + 4) / math.log(24) * (_rand(seed, 1) * 0.6 + 0.7) * 0.75;
  var n = 4;
  const thresholds = [0.45, 1.05, 1.7];
  for (var i = 0; i < thresholds.length; i++) {
    if (score < thresholds[i]) {
      n = i + 1;
      break;
    }
  }
  List<_PartPlan> parts;
  while (true) {
    parts = _splitParts(words, units, math.min(n, units.length));
    final lean = <int>[
      for (var i = 0; i < parts.length; i++)
        if (_rand(seed, 100.0 + i) < 0.35) i,
    ];
    if (lean.isNotEmpty) {
      parts[lean[(_rand(seed, 200) * lean.length).floor()]].lean = true;
    }
    if (n >= 4 || n >= units.length || fits(parts)) break;
    n++;
  }
  final k = parts.length;
  if (k > 1 && !parts[k - 1].lean) {
    final last = _charCount(words.sublist(parts[k - 1].from, parts[k - 1].to));
    final before = _charCount(
      words.sublist(parts[k - 2].from, parts[k - 2].to),
    );
    parts[k - 1].tail = last <= 2 && last * 2 <= before;
  }
  return parts;
}

/// 倾斜：一到四个大号短行上下排在中间。
_LineArt _layoutTilt(_StageLine l, Size size, TextStyle base, double size0) {
  final avail = size.width * 0.85;
  final seed = l.start;
  TextStyle styleFor(bool lean, double s) => _bare(
    base,
    s,
    lean ? FontWeight.w300 : FontWeight.w400,
    height: lean ? 1.25 : 1.35,
    fontStyle: lean ? FontStyle.italic : null,
  );

  double partWidth(_PartPlan p, double s) {
    final buf = StringBuffer();
    for (var i = p.from; i < p.to; i++) {
      buf.write(l.words[i].text);
      if (l.words[i].spaceAfter) buf.write(' ');
    }
    final text = buf.toString().trim();
    final tp = TextPainter(
      text: TextSpan(text: text, style: styleFor(p.lean, s)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w + text.runes.length * s * (p.lean ? 0.15 : 0.08);
  }

  double widest(List<_PartPlan> parts, double s) {
    var m = 0.0;
    for (final p in parts) {
      m = math.max(m, partWidth(p, s));
    }
    return m;
  }

  final plans = _tiltParts(
    l.words,
    seed,
    (parts) => widest(parts, size0) <= avail,
  );
  var sz = size0;
  final m = widest(plans, sz);
  if (m > avail) sz *= math.max(0.5, avail / m);

  final glyphCache = <(String, bool, bool), _Glyph>{};
  final chars = <_TiltChar>[];
  final partRows = <(int, int, double, double)>[]; // 字区间、宽、高
  for (var pi = 0; pi < plans.length; pi++) {
    final plan = plans[pi];
    final s = plan.tail ? sz * 1.18 : sz;
    final style = styleFor(plan.lean, s);
    final spacing = plan.lean ? 0.15 : 0.08;
    final gap = plan.lean ? 0.35 : 0.25;
    final first = chars.length;
    var cursor = 0.0, height = 0.0, k = 0;
    for (var wi = plan.from; wi < plan.to; wi++) {
      final w = l.words[wi];
      final runes = w.text.runes.toList();
      final each = (w.end - w.start) / math.max(runes.length, 1);
      for (var i = 0; i < runes.length; i++) {
        if (_isSpaceRune(runes[i])) {
          cursor += s * gap;
          continue;
        }
        final ch = String.fromCharCode(runes[i]);
        final g = glyphCache[(ch, plan.lean, plan.tail)] ??= _Glyph(ch, style);
        height = math.max(height, g.height);
        chars.add(
          _TiltChar(
            glyph: g,
            part: pi,
            // 先记横向位置，纵向等整体排完再补。
            center: Offset(cursor + g.width / 2, 0),
            start: w.start + i * each,
            duration: each.clamp(0.2, 0.9),
            k: k,
            spark: i == 0,
            sparkLast: pi == plans.length - 1 && wi == plan.to - 1,
            wordStart: w.start,
          ),
        );
        cursor += g.width + s * spacing;
        k++;
      }
      if (w.spaceAfter && wi < plan.to - 1) cursor += s * gap;
    }
    final width = math.max(0.0, cursor - s * spacing);
    partRows.add((first, chars.length, width, height));
  }

  final gapY = sz * 0.22;
  var total = 0.0;
  for (final r in partRows) {
    total += r.$4;
  }
  total += gapY * math.max(0, partRows.length - 1);
  var y = (size.height - total) / 2;
  final parts = <_TiltPart>[];
  final placedChars = <_TiltChar>[];
  for (var pi = 0; pi < partRows.length; pi++) {
    final (from, to, width, height) = partRows[pi];
    final left = (size.width - width) / 2;
    final rect = Rect.fromLTWH(left, y, width, height);
    for (var c = from; c < to; c++) {
      final ch = chars[c];
      placedChars.add(
        _TiltChar(
          glyph: ch.glyph,
          part: pi,
          center: Offset(left + ch.center.dx, rect.center.dy),
          start: ch.start,
          duration: ch.duration,
          k: ch.k,
          spark: ch.spark,
          sparkLast: ch.sparkLast,
          wordStart: ch.wordStart,
        ),
      );
    }
    parts.add(
      _TiltPart(
        rect: rect,
        lean: plans[pi].lean,
        start: l.words[plans[pi].from].start - _tiltLead,
        chars: to - from,
      ),
    );
    y += height + gapY;
  }

  final art = _LineArt(
    line: l,
    fontSize: sz,
    glyphs: glyphCache.values.toList(),
    chars: placedChars,
    parts: parts,
    fit: math.min(1, size.height * 0.95 / math.max(total, 1)),
  );
  for (final p in parts) {
    art.hot.add((p.start, p.start + 0.65 + p.chars * 0.05 + 0.5));
  }
  for (final ch in placedChars) {
    final settle = ch.duration * 2.2 + 0.05;
    art.hot.add((ch.start, ch.start + math.max(settle, _sparkTime)));
  }
  return art;
}

// ---------------------------------------------------------------------------
// 舞台
// ---------------------------------------------------------------------------

/// 逐字跟唱的歌词舞台。
class LyricsStage extends ConsumerStatefulWidget {
  const LyricsStage({
    super.key,
    required this.lyrics,
    required this.style,
    required this.sparks,
    this.baseStyle,
    this.compact = false,
    this.lowPower = false,
  });

  final ParsedLyrics lyrics;
  final LyricsStageStyle style;
  final bool sparks;

  /// 字体族 / 回退字体和颜色从这里取；字号由舞台按宽度决定。
  final TextStyle? baseStyle;
  final bool compact;

  /// 减少动态 / 低电量：静态排版，按位置推送一步步点亮，不跑 Ticker。
  final bool lowPower;

  @override
  ConsumerState<LyricsStage> createState() => _LyricsStageState();
}

/// 一帧需要的全部排版。
class _Scene {
  _Scene({
    required this.lines,
    required this.focus,
    required this.current,
    required this.previous,
    required this.lead,
  });

  final List<_StageLine> lines;
  final int focus;
  final _LineArt? current;
  final _LineArt? previous;
  final double lead;

  /// [t] 秒时要显示的间奏区间。
  (double, double)? interludeAt(double t) {
    if (lines.isEmpty) return null;
    if (focus < 0) return (0, lines.first.start);
    if (focus + 1 >= lines.length) return null;
    final cur = lines[focus], next = lines[focus + 1];
    if (t > cur.end + 1 && next.start - cur.end > _interludeGap) {
      return (cur.end, next.start);
    }
    return null;
  }
}

class _LyricsStageState extends ConsumerState<LyricsStage>
    with SingleTickerProviderStateMixin {
  late final LyricsClock _clock = LyricsClock(this)..addListener(_onClock);
  late List<_StageLine> _lines = _stageLines(widget.lyrics);

  int _active = -1;
  bool _interlude = false;
  int? _manual;
  Timer? _manualTimer;
  Timer? _wake;
  double _dragDy = 0;
  bool _reduce = false;
  bool _building = false;

  /// 排好的句子，按句子下标缓存；只留当前句和上一句。
  final Map<int, _LineArt> _arts = {};
  Object? _artsKey;
  _Scene? _scene;

  double get _lead =>
      widget.style == LyricsStageStyle.tilt ? _tiltLead : _flowLead;

  @override
  void initState() {
    super.initState();
    ref.listenManual<int>(positionProvider, (_, _) => _sync());
    ref.listenManual<bool>(
      playbackProvider.select((s) => s.isPlaying),
      (_, _) => _sync(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = widget.lowPower || MediaQuery.disableAnimationsOf(context);
    _building = true;
    _sync();
    _building = false;
  }

  @override
  void didUpdateWidget(covariant LyricsStage old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _lines = _stageLines(widget.lyrics);
      _manualTimer?.cancel();
      _manual = null;
      _clearArts();
    }
    _reduce = widget.lowPower || MediaQuery.disableAnimationsOf(context);
    _building = true;
    _sync();
    _building = false;
  }

  @override
  void dispose() {
    _manualTimer?.cancel();
    _wake?.cancel();
    _clock.dispose();
    _clearArts();
    super.dispose();
  }

  void _clearArts() {
    final old = _arts.values.toList();
    _arts.clear();
    _artsKey = null;
    if (old.isEmpty) return;
    // 这一帧的 painter 可能还拿着它们，下一帧再释放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final a in old) {
        a.dispose();
      }
    });
  }

  void _sync() {
    _clock.sync(
      ref.read(positionProvider),
      ref.read(playbackProvider.select((s) => s.isPlaying)),
    );
    _onClock();
  }

  /// 时钟每走一步：看要不要换句 / 切间奏（只有这时才重建），再决定下一帧
  /// 什么时候要。
  void _onClock() {
    if (!mounted) return;
    final ms = _clock.value;
    // 提前一点换句，让第一个词的进场从头开始。
    final active = _indexAt(_lines, ms + _lead * 1000);
    final scene = _scene;
    final interlude =
        scene != null &&
        scene.focus == active &&
        scene.interludeAt(ms / 1000) != null;
    if (active != _active || interlude != _interlude) {
      _active = active;
      _interlude = interlude;
      if (!_building) setState(() {});
    }
    _schedule();
  }

  void _schedule() {
    _wake?.cancel();
    _wake = null;
    final scene = _scene;
    if (!_clock.playing || _reduce || _manual != null || scene == null) {
      _clock.animate = false;
      return;
    }
    final t = _clock.value / 1000;
    var next = double.infinity;
    var slow = 0.0;

    bool scan(_LineArt? art) {
      if (art == null) return false;
      for (final (a, b) in art.hot) {
        if (t >= a && t < b) return true;
        if (a > t && a < next) next = a;
      }
      return false;
    }

    final cur = scene.current;
    var hot = scan(cur) || scan(scene.previous);
    if (!hot && cur != null && scene.previous != null) {
      hot = t < cur.line.start - _lead + _lineGone;
    }
    if (!hot) {
      final interlude = scene.interludeAt(t);
      if (interlude != null) {
        slow = 0.05; // 呼吸点
      } else if (cur != null) {
        for (final (a, b) in cur.drift) {
          if (t >= a && t < b) {
            slow = 0.1; // 唱完的词在慢慢漂移
            break;
          }
        }
        // 间奏到来的时刻。
        if (scene.focus + 1 < _lines.length) {
          final il = cur.line.end + 1;
          if (il > t && il < next) next = il;
        }
      }
      // 下一句换上来的时刻。
      final focus = scene.focus;
      if (focus + 1 < _lines.length) {
        final s = _lines[focus + 1].start - _lead;
        if (s > t && s < next) next = s;
      }
    }
    _clock.animate = hot;
    if (hot) return;
    var wait = slow > 0 ? slow : math.min(next - t, 0.25);
    if (!wait.isFinite || wait <= 0) wait = 0.016;
    _wake = Timer(Duration(microseconds: (wait * 1e6).round()), _clock.refresh);
  }

  int get _focus {
    final m = _manual;
    if (m != null && m >= 0 && m < _lines.length) return m;
    return _active;
  }

  void _browse(int delta) {
    if (_lines.isEmpty) return;
    final base = _focus < 0 ? 0 : _focus;
    final next = (base + delta).clamp(0, _lines.length - 1);
    if (next == base && _focus >= 0) return;
    _manualTimer?.cancel();
    _manualTimer = Timer(_manualResume, _resumeFollow);
    setState(() => _manual = next);
  }

  void _resumeFollow() {
    _manualTimer?.cancel();
    _manualTimer = null;
    if (_manual == null || !mounted) return;
    setState(() => _manual = null);
  }

  void _onDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    final dy = _dragDy;
    _dragDy = 0;
    if (dy.abs() < 36 && v.abs() < 140) return;
    _browse(dy < 0 || v < 0 ? 1 : -1);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _browse(event.scrollDelta.dy > 0 ? 1 : -1);
  }

  void _onTap(Offset local) {
    final focus = _focus;
    if (focus < 0 || focus >= _lines.length) return;
    final art = _scene?.current;
    final target = art?.hit(local) ?? _lines[focus].start;
    _resumeFollow();
    ref.read(playerActionsProvider).seek((target * 1000).round());
  }

  _LineArt? _art(int index, Size size, TextStyle base) {
    if (index < 0 || index >= _lines.length) return null;
    final cached = _arts[index];
    if (cached != null) return cached;
    final l = _lines[index];
    final minFont = widget.compact ? 24.0 : 30.0;
    var f = switch (widget.style) {
      // 窄屏上 mygo 的 6.9% 宽太小；至少比流动的字号再大一点。
      LyricsStageStyle.tilt =>
        math.min(size.width * 0.06875, 90.0).clamp(minFont * 1.15, 90.0),
      LyricsStageStyle.steps =>
        (size.width * 0.045).clamp(minFont, 64.0) *
            0.8 *
            (_charCount(l.words) > 40 ? 0.8 : 1.0),
      LyricsStageStyle.flow => (size.width * 0.045).clamp(minFont, 64.0),
    };
    _LineArt art;
    for (var attempt = 0; ; attempt++) {
      art = switch (widget.style) {
        LyricsStageStyle.flow => _layoutFlow(l, size, base, f),
        LyricsStageStyle.steps => _layoutSteps(l, size, base, f),
        LyricsStageStyle.tilt => _layoutTilt(l, size, base, f),
      };
      // 放不下就缩小字号重排，最多三次，最小一半。
      if (art.fit >= 0.999 || attempt >= 2 || f <= minFont * 0.5) break;
      art.dispose();
      f = math.max(minFont * 0.5, f * art.fit * 0.98);
    }
    _arts[index] = art;
    return art;
  }

  _Scene _sceneFor(Size size, TextStyle base, Color bright, Color accent) {
    final key = (
      size,
      widget.style,
      widget.compact,
      base.fontFamily,
      base.fontFamilyFallback,
      bright,
      accent,
    );
    if (key != _artsKey) {
      _clearArts();
      _artsKey = key;
    }
    final focus = _focus;
    final browsing = _manual != null;
    final keep = {focus, if (!browsing) focus - 1};
    final stale = [
      for (final e in _arts.entries)
        if (!keep.contains(e.key)) e,
    ];
    for (final e in stale) {
      _arts.remove(e.key);
      WidgetsBinding.instance.addPostFrameCallback((_) => e.value.dispose());
    }
    return _Scene(
      lines: _lines,
      focus: focus,
      current: _art(focus, size, base),
      previous: browsing ? null : _art(focus - 1, size, base),
      lead: _lead,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bright = widget.baseStyle?.color ?? theme.colorScheme.onSurface;
    final base = widget.baseStyle ?? LekisText.lyricsActive;
    // 强调色（光晕、斜行、引导线）：主色往前景色提一点亮度，深色背景上
    // 也读得清。
    final accent = Color.lerp(theme.colorScheme.primary, bright, 0.3)!;
    final browsing = _manual != null;
    final focus = _focus;
    final line = focus >= 0 && focus < _lines.length ? _lines[focus] : null;
    final next = focus + 1 < _lines.length ? _lines[focus + 1] : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.biggest;
        final size = Size(
          full.width,
          math.max(0, full.height - _footerReserve),
        );
        final scene = size.width < 40 || size.height < 40
            ? null
            : _sceneFor(size, base, bright, accent);
        _scene = scene;
        // 第一次排版前时钟回调还拿不到场景，这里补算一次间奏。
        _interlude =
            scene != null && scene.interludeAt(_clock.value / 1000) != null;
        _schedule();

        return Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTap(d.localPosition),
            onVerticalDragStart: (_) => _dragDy = 0,
            onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
            onVerticalDragEnd: _onDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  bottom: _footerReserve,
                  child: Semantics(
                    button: line != null,
                    selected: line != null,
                    label: line == null
                        ? null
                        : line.line.translation == null
                        ? line.line.text
                        : '${line.line.text}，${line.line.translation}',
                    hint: '上下滑动浏览歌词，点按跳到这一句',
                    excludeSemantics: true,
                    onTap: line == null
                        ? null
                        : () {
                            _resumeFollow();
                            ref
                                .read(playerActionsProvider)
                                .seek(line.line.startMs);
                          },
                    child: RepaintBoundary(
                      child: scene == null
                          ? const SizedBox.expand()
                          : CustomPaint(
                              painter: _StagePainter(
                                scene: scene,
                                clock: _clock,
                                style: widget.style,
                                sparks: widget.sparks && !_reduce,
                                still: _reduce,
                                browsing: browsing,
                                bright: bright,
                                accent: accent,
                              ),
                              isComplex: true,
                              willChange: true,
                              child: const SizedBox.expand(),
                            ),
                    ),
                  ),
                ),
                if (_interlude && !browsing)
                  Positioned.fill(
                    bottom: _footerReserve,
                    child: Semantics(
                      key: const ValueKey('stage-interlude'),
                      container: true,
                      label: '间奏',
                      child: const SizedBox.expand(),
                    ),
                  ),
                Positioned(
                  left: LekisSpacing.lg,
                  right: LekisSpacing.lg,
                  bottom: LekisSpacing.lg,
                  child: _StageFooter(
                    translation: line?.line.translation,
                    next: next?.line.text,
                    lowPower: _reduce,
                  ),
                ),
                if (browsing)
                  Positioned(
                    top: LekisSpacing.sm,
                    right: LekisSpacing.lg,
                    child: _ManualChip(onTap: _resumeFollow),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 绘制
// ---------------------------------------------------------------------------

class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.scene,
    required this.clock,
    required this.style,
    required this.sparks,
    required this.still,
    required this.browsing,
    required this.bright,
    required this.accent,
  }) : super(repaint: clock);

  final _Scene scene;
  final LyricsClock clock;
  final LyricsStageStyle style;
  final bool sparks;

  /// 减少动态：不弹、不转、不模糊，只按时间点亮。
  final bool still;

  /// 手动浏览：整句静态、全部点亮。
  final bool browsing;
  final Color bright;
  final Color accent;

  final Paint _line = Paint()
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  final Paint _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value / 1000;
    final cur = scene.current;
    if (browsing) {
      if (cur != null) _paintLine(canvas, size, cur, t, 1, settled: true);
      return;
    }
    // 上一句随新句到来淡出。
    final prev = scene.previous;
    if (prev != null && cur != null && !still) {
      final gone = (t - (cur.line.start - scene.lead)) / _lineGone;
      if (gone < 1) {
        _paintLine(canvas, size, prev, t, 1 - _easeOutCubic(gone));
      }
    }
    final interlude = scene.interludeAt(t);
    if (interlude != null) {
      _paintInterlude(canvas, size, t, interlude.$1, interlude.$2);
    } else if (cur != null) {
      _paintLine(canvas, size, cur, t, 1);
    }
  }

  void _paintLine(
    Canvas canvas,
    Size size,
    _LineArt art,
    double t,
    double fade, {
    bool settled = false,
  }) {
    if (fade <= 0.01) return;
    switch (style) {
      case LyricsStageStyle.flow:
        for (final p in art.words) {
          _paintWord(canvas, p, Offset.zero, t, art.fontSize, fade, settled);
        }
      case LyricsStageStyle.steps:
        _paintSteps(canvas, size, art, t, fade, settled);
      case LyricsStageStyle.tilt:
        _paintTilt(canvas, art, t, fade, settled);
    }
  }

  /// 一个词此刻的样子：等待（不可见）、正在唱、唱完（mygo 的 stageWord）。
  void _paintWord(
    Canvas canvas,
    _Placed p,
    Offset shift,
    double t,
    double f,
    double fade,
    bool settled,
  ) {
    final w = p.word, s = p.shape, g = p.glyph;
    final origin = p.center + shift;
    if (settled || still) {
      final sung = settled || t >= w.start;
      canvas.save();
      canvas.translate(origin.dx + s.x, origin.dy + s.y);
      canvas.rotate(s.rot * _deg);
      canvas.scale(s.scale);
      g.paint(canvas, bright, (sung ? 0.9 : 0.35) * fade);
      canvas.restore();
      return;
    }
    final start = w.start - _flowLead;
    final end = w.sungEnd;
    final since = t - start;
    if (since <= 0) return;
    final after = t - end;
    final singing = math.max(0.08, end - w.start);

    // 等待的位置：偏到一边、半大、转着、模糊。
    var x = s.x + math.sin(s.y) * f * 1.6;
    var y = s.y + math.cos(s.x) * f * 0.8;
    final e = _springStep(since);
    x = _lerp(x, s.x, e);
    y = _lerp(y, s.y, e);
    var scale = _lerp(0.5, s.scale * 1.4, e);
    var rot = _lerp(s.rot + 20, s.rot, e);
    var opacity = _clamp01(since / 0.1);
    final blur = 10 * (1 - _clamp01(since / 0.2));
    var alpha = _lerp(0.5, 1, _clamp01(since / singing));
    var glow = _clamp01(since / math.max(0.08, 0.3 * singing));
    if (after > 0) {
      // 唱完：缩回、变暗、慢慢漂移。
      final q = _easeOutCubic(after / 0.5);
      scale = _lerp(s.scale * 1.4, s.scale, q);
      opacity = _lerp(1, 0.82, q);
      rot = s.rot + s.drift * _clamp01(after / 5);
      alpha = _lerp(1, 0.5, _easeOutCubic(after / 0.8));
      glow = 1 - _clamp01(after / 0.9);
    }
    final o = opacity * fade;
    if (o <= 0.01) return;
    final cx = origin.dx + x, cy = origin.dy + y;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rot * _deg);
    canvas.scale(scale);
    g.paint(canvas, bright, alpha * o, blur: blur);
    if (glow > 0.01) {
      // 光晕：同一个词，强调色，糊开罩在上面。
      g.paint(canvas, accent, 0.85 * glow * o, blur: f * 0.2, tone: 1);
    }
    canvas.restore();
    if (sparks) {
      _paintSparks(
        canvas,
        Offset(cx, cy),
        g.width * scale,
        g.height * scale,
        t - w.start,
        w.start * 1000,
        p.last,
        fade,
      );
    }
  }

  /// 阶梯：每行从引导线一侧滑入（mygo 的 partitaLine）。
  void _paintSteps(
    Canvas canvas,
    Size size,
    _LineArt art,
    double t,
    double fade,
    bool settled,
  ) {
    final grow = 1 + 0.05 * (1 - fade);
    canvas.save();
    if (grow != 1) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(grow);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    final side = art.fontSize * 0.8;
    for (var r = 0; r < art.rows.length; r++) {
      final row = art.rows[r];
      final since = t - row.start;
      var x = row.offset.dx, scale = 1.0, opacity = 1.0;
      if (!settled && !still) {
        final from = row.offset.dx + (row.left ? -side : side);
        if (since <= 0) continue;
        final e = _springStep(since);
        x = _lerp(from, row.offset.dx, e);
        scale = _lerp(0.85, 1, e);
        opacity = _clamp01(since / 0.1);
      }
      final o = opacity * fade;
      if (o <= 0.01) continue;
      final c = row.rect.center;
      canvas.save();
      canvas.translate(c.dx + x, c.dy + row.offset.dy);
      canvas.scale(scale);
      canvas.translate(-c.dx, -c.dy);
      // 引导线：行尾下方的直角，进场时画出来，唱时亮起强调色。
      final guide = settled || still ? 1.0 : _easeOutCubic(since / 0.4);
      final Color color;
      if (settled || t >= row.end) {
        color = bright.withValues(alpha: bright.a * 0.22 * o * guide);
      } else if (since > 0) {
        color = accent.withValues(alpha: accent.a * o * guide);
      } else {
        color = bright.withValues(alpha: bright.a * 0.14 * o * guide);
      }
      if (guide > 0) _paintGuide(canvas, row, guide, color);
      for (final p in art.words) {
        if (p.row != r) continue;
        _paintWord(canvas, p, Offset.zero, t, art.fontSize, o, settled);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  void _paintGuide(Canvas canvas, _Row row, double guide, Color color) {
    _line
      ..color = color
      ..strokeWidth = 1;
    final r = row.rect;
    final bottom = r.bottom;
    if (row.left) {
      canvas.drawLine(
        Offset(r.left - 8, bottom + 16),
        Offset(r.left - 8, bottom + 16 - 32 * guide),
        _line,
      );
      canvas.drawLine(
        Offset(r.left - 16, bottom + 8),
        Offset(r.left - 16 + (r.width + 36) * guide, bottom + 8),
        _line,
      );
    } else {
      canvas.drawLine(
        Offset(r.right + 8, bottom + 16),
        Offset(r.right + 8, bottom + 16 - 32 * guide),
        _line,
      );
      canvas.drawLine(
        Offset(r.right + 16, bottom + 8),
        Offset(r.right + 16 - (r.width + 36) * guide, bottom + 8),
        _line,
      );
    }
  }

  /// 倾斜：每行升起淡入，字在唱到时鼓起（mygo 的 tiltLine）。
  void _paintTilt(
    Canvas canvas,
    _LineArt art,
    double t,
    double fade,
    bool settled,
  ) {
    canvas.save();
    canvas.translate(0, -12 * (1 - fade));
    final size = art.fontSize;
    for (var pi = 0; pi < art.parts.length; pi++) {
      final part = art.parts[pi];
      final since = t - part.start;
      final lean = part.lean;
      final color = lean ? accent : bright;
      final tone = lean ? 1 : 0;
      final pulse = lean ? 0.18 : 0.15;
      final stagger = lean ? 0.05 : 0.04;
      var inT = 1.0, rise = 0.0, scale = 1.0;
      if (!settled && !still) {
        inT = _easeOutQuad(since / (lean ? 0.6 : 0.55));
        rise = (lean ? 24 : 20) * (1 - inT);
        if (lean) scale = 0.92 + 0.08 * inT;
      }
      if (inT <= 0.01) continue;
      final c = part.rect.center;
      canvas.save();
      canvas.translate(c.dx, c.dy + rise);
      canvas.scale(scale);
      canvas.translate(-c.dx, -c.dy);
      for (final ch in art.chars) {
        if (ch.part != pi) continue;
        var s = 1.0, shown = 1.0, alpha = 1.0;
        if (settled || still) {
          alpha = settled || t >= ch.start ? 0.92 : 0.4;
        } else {
          final d = ch.duration;
          final tt = t - ch.start;
          final double swell;
          if (tt < 0) {
            swell = 0;
          } else if (tt <= d) {
            swell = math.sin(tt / d * math.pi);
          } else {
            swell = 0.25 * _clamp01((tt - d) / (d * 1.2));
          }
          s = 1 + swell * pulse;
          shown = _easeOutQuad((since - ch.k * stagger) / 0.5);
        }
        final a = alpha * inT * shown * fade;
        if (a <= 0.01) continue;
        var y = 0.0;
        if (lean) {
          // 斜行的字上下交错，从两倍远处落下来。
          y = size / 6 * (2 - shown);
          if (ch.k.isEven) y = -y;
        }
        canvas.save();
        canvas.translate(ch.center.dx, ch.center.dy + y);
        if (s != 1) canvas.scale(s);
        ch.glyph.paint(canvas, color, a, tone: tone);
        canvas.restore();
        if (sparks && ch.spark && !settled) {
          _paintSparks(
            canvas,
            Offset(ch.center.dx, ch.center.dy + y),
            ch.glyph.width * s,
            ch.glyph.height * s,
            t - ch.start,
            ch.wordStart * 1000,
            ch.sparkLast,
            fade,
          );
        }
      }
      canvas.restore();
    }
    canvas.restore();
  }

  /// 火花：词落定时从边缘飞出几道强调色短线，先白后褪、越飞越短；句尾
  /// 的词更多更远（mygo 的 stageSparks）。只是 drawLine，很便宜。
  void _paintSparks(
    Canvas canvas,
    Offset c,
    double w,
    double h,
    double since,
    double seed,
    bool last,
    double fade,
  ) {
    if (since < 0 || since >= _sparkTime) return;
    final t = since / _sparkTime;
    var n = 9;
    var reach = math.max(w, h) * 0.75;
    if (last) {
      n = 16;
      reach *= 1.6;
    }
    final u = 1 - t;
    final out = 1 - u * u * u;
    final color = Color.lerp(accent, const Color(0xFFFFFFFF), 0.6 * u)!;
    _line
      ..color = color.withValues(alpha: 0.9 * u * u * fade)
      ..strokeWidth = 0.8 + 1.6 * u;
    for (var i = 0; i < n; i++) {
      final angle = 2 * math.pi * (i + _rand(seed, i.toDouble()) * 0.7) / n;
      final dx = math.cos(angle), dy = math.sin(angle);
      final edge = w / 2 * 0.7 * dx.abs() + h / 2 * 0.7 * dy.abs();
      final head = edge + reach * (0.55 + 0.45 * _rand(seed, i + 50.0)) * out;
      final tail = math.max(edge, head - reach * 0.3 * u);
      canvas.drawLine(
        Offset(c.dx + dx * tail, c.dy + dy * tail),
        Offset(c.dx + dx * head, c.dy + dy * head),
        _line,
      );
    }
  }

  /// 间奏：三颗呼吸的圆点，随下一句临近依次点亮。
  void _paintInterlude(
    Canvas canvas,
    Size size,
    double t,
    double from,
    double to,
  ) {
    final progress = _clamp01((t - from) / math.max(0.1, to - from));
    final breath = still ? 1.0 : 1 + 0.12 * math.sin(t * 1000 / 420);
    const r = 8.0, gap = 18.0;
    final cx = size.width / 2, cy = size.height / 2;
    for (var i = 0; i < 3; i++) {
      final lit = _clamp01(progress * 3 - i);
      _fill.color = bright.withValues(alpha: bright.a * (0.2 + 0.7 * lit));
      canvas.drawCircle(
        Offset(cx + (i - 1) * (2 * r + gap), cy),
        r * breath,
        _fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) =>
      old.scene != scene ||
      old.clock != clock ||
      old.style != style ||
      old.sparks != sparks ||
      old.still != still ||
      old.browsing != browsing ||
      old.bright != bright ||
      old.accent != accent;
}

// ---------------------------------------------------------------------------
// 底部与浮层
// ---------------------------------------------------------------------------

/// 底部：这一句的翻译，和淡淡的下一句。
class _StageFooter extends StatelessWidget {
  const _StageFooter({
    required this.translation,
    required this.next,
    required this.lowPower,
  });

  final String? translation;
  final String? next;
  final bool lowPower;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final duration = lowPower ? Duration.zero : LekisMotion.normal;
    final tr = translation?.trim();
    final nx = next?.trim();
    final hasTr = tr != null && tr.isNotEmpty;
    final hasNext = nx != null && nx.isNotEmpty;
    if (!hasTr && !hasNext) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasTr)
          AnimatedSwitcher(
            duration: duration,
            child: Text(
              tr,
              key: ValueKey('tr-$tr'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: fg.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        if (hasTr && hasNext) const SizedBox(height: LekisSpacing.xs),
        if (hasNext)
          AnimatedSwitcher(
            duration: duration,
            child: Text(
              nx,
              key: ValueKey('next-$nx'),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg.withValues(alpha: 0.32),
              ),
            ),
          ),
      ],
    );
  }
}

class _ManualChip extends StatelessWidget {
  const _ManualChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    return Material(
      color: fg.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(LekisRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LekisRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.md,
            vertical: LekisSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.my_location_rounded, size: 14, color: fg),
              const SizedBox(width: LekisSpacing.xs),
              Text(
                '回到当前',
                style: theme.textTheme.labelSmall?.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
