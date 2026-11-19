// 歌词舞台：一句一行、逐字进场，三种排版（流动 / 阶梯 / 倾斜）。
//
// 动效的节奏参考了 Folia / mygo 的舞台观感，但布局、随机数和弹簧都在这里
// 独立实现。时间轴只决定每个词的状态；真正的 60fps 补间由一个只在需要时
// 启动的 Ticker 推动，静止时退回到播放位置的 200ms 心跳。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/lyrics_stage_settings.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// 底部翻译 / 下一句预留的高度。
const double _stageFooterReserve = 96;

/// 短于这个间隔的空行直接跳过，长于它的间奏才显示呼吸点。
const int _stageInterludeMinMs = 3000;

/// 手动翻阅后自动回到当前句的等待时间。
const Duration _stageManualResume = Duration(seconds: 3);

/// 一个词的普通 / 收尾火花持续时间。
const double _sparkTime = 0.62;
const double _sparkLastTime = 0.9;

/// 一个词的“提前量”：倾斜样式更早露出下一句。
const double _flowLead = 0.08;
const double _tiltLead = 0.25;

double _clamp01(double v) => v.clamp(0.0, 1.0);

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _easeOutCubic(double t) {
  t = _clamp01(t);
  return 1 - math.pow(1 - t, 3).toDouble();
}

/// 临界阻尼附近的弹簧：约 0.5s 稳定，带一点点过冲。
double _springStep(double t) {
  if (t <= 0) return 0;
  final e = math.exp(-10 * t);
  return 1 - e * (math.cos(10 * t) + math.sin(10 * t));
}

/// 稳定、与平台无关的小随机数：同一句、同一个词每次得到同一组偏移。
double _lineRandom(int seed, int salt) {
  final x = math.sin(seed * 0.001 + salt * 12.9898) * 43758.5453;
  return x - x.floorToDouble();
}

bool _isCjk(int rune) =>
    (rune >= 0x3040 && rune <= 0x30ff) || // かな
    (rune >= 0x3400 && rune <= 0x9fff) || // 汉字
    (rune >= 0xac00 && rune <= 0xd7af) || // 谚文
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0xff00 && rune <= 0xffef);

bool _isStopRune(int rune) {
  const stops = {
    0x2c, 0x2e, 0x21, 0x3f, 0x3b, 0x3a, // , . ! ? ; :
    0x3001, 0x3002, 0xff0c, 0xff01, 0xff1f, 0xff1b, 0xff1a,
    0x300d, 0x300f, 0x3011, 0x3015, 0x2026, 0x2014, 0x2013,
  };
  return stops.contains(rune);
}

/// 判断一个词后面是否需要留出词间距；英文需要，CJK 不需要。
bool _spacesAfter(String text) {
  if (text.isEmpty) return false;
  final last = text.runes.last;
  return !_isCjk(last);
}

String _trimEnd(String s) {
  var end = s.length;
  while (end > 0 && _isSpace(s.codeUnitAt(end - 1))) {
    end--;
  }
  return s.substring(0, end);
}

/// 词间距：英文词按空格，中文按很小的字距。
double _wordGap(_StageToken token, double fontSize) =>
    fontSize * (token.spaceAfter ? 0.24 : 0.04);

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09 || unit == 0x0a;

List<String> _plainChunks(String text) {
  final out = <String>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isNotEmpty) {
      out.add(buffer.toString());
      buffer.clear();
    }
  }

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_isSpace(rune)) {
      flush();
    } else if (_isCjk(rune)) {
      flush();
      out.add(ch);
    } else if (_isStopRune(rune)) {
      buffer.write(ch);
      flush();
    } else {
      buffer.write(ch);
    }
  }
  flush();
  return out;
}

class _StageToken {
  const _StageToken({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.index,
    required this.wordIndex,
    required this.spark,
    required this.sparkLast,
    required this.lastInLine,
    required this.spaceAfter,
  });

  final String text;
  final int startMs;
  final int endMs;
  final int index;
  final int wordIndex;
  final bool spark;
  final bool sparkLast;
  final bool lastInLine;
  final bool spaceAfter;

  _StageToken copyWith({bool? lastInLine, bool? sparkLast}) => _StageToken(
    text: text,
    startMs: startMs,
    endMs: endMs,
    index: index,
    wordIndex: wordIndex,
    spark: spark,
    sparkLast: sparkLast ?? this.sparkLast,
    lastInLine: lastInLine ?? this.lastInLine,
    spaceAfter: spaceAfter,
  );
}

List<_StageToken> _plainStageTokens(LyricLine line) {
  final chunks = _plainChunks(line.text);
  final out = <_StageToken>[];
  final base = line.startMs < 0 ? 0 : line.startMs;
  for (var i = 0; i < chunks.length; i++) {
    final start = base + i * 45;
    out.add(
      _StageToken(
        text: chunks[i],
        startMs: start,
        endMs: start + 620,
        index: i,
        wordIndex: i,
        spark: true,
        sparkLast: i == chunks.length - 1,
        lastInLine: i == chunks.length - 1,
        spaceAfter: _spacesAfter(chunks[i]),
      ),
    );
  }
  return out;
}

List<_StageToken> _stageTokens(LyricLine line, {required bool chars}) {
  final words = line.words;
  final wordsOut = <_StageToken>[];
  if (words == null || words.isEmpty) {
    wordsOut.addAll(_plainStageTokens(line));
  } else {
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final text = word.text.trim();
      if (text.isEmpty) continue;
      final display = _trimEnd(text);
      wordsOut.add(
        _StageToken(
          text: display,
          startMs: word.startMs,
          endMs: math.max(word.endMs, word.startMs + 120),
          index: wordsOut.length,
          wordIndex: wordsOut.length,
          spark: true,
          sparkLast: i == words.length - 1,
          lastInLine: i == words.length - 1,
          spaceAfter: word.text.endsWith(' ') || _spacesAfter(display),
        ),
      );
    }
    if (wordsOut.isNotEmpty) {
      wordsOut[wordsOut.length - 1] = wordsOut.last.copyWith(
        lastInLine: true,
        sparkLast: true,
      );
    }
  }
  if (wordsOut.isEmpty) return const [];
  if (!chars) return wordsOut;

  final out = <_StageToken>[];
  for (final word in wordsOut) {
    final runes = word.text.runes.toList();
    if (runes.isEmpty) continue;
    // 句尾词的 end 常被延长到下一句，逐字拆开时不能把最后一个字拖到
    // 间奏里；给字符一个自然的朗读时长上限。
    final natural = math.min(
      math.max(1, word.endMs - word.startMs),
      (runes.length * 210).clamp(520, 1500),
    );
    final span = math.max(1, natural);
    for (var i = 0; i < runes.length; i++) {
      final start = word.startMs + (span * i / runes.length).round();
      final end = word.startMs + (span * (i + 1) / runes.length).round();
      out.add(
        _StageToken(
          text: String.fromCharCode(runes[i]),
          startMs: start,
          endMs: math.max(start + 1, end),
          index: out.length,
          wordIndex: word.wordIndex,
          spark: word.spark && i == 0,
          sparkLast: word.sparkLast && i == 0,
          lastInLine: word.lastInLine && i == runes.length - 1,
          spaceAfter: word.spaceAfter && i == runes.length - 1,
        ),
      );
    }
  }
  if (out.isNotEmpty) {
    out[out.length - 1] = out.last.copyWith(lastInLine: true);
  }
  return out;
}

TextStyle _foregroundStyle(TextStyle base, Paint paint) => TextStyle(
  inherit: base.inherit,
  fontFamily: base.fontFamily,
  fontFamilyFallback: base.fontFamilyFallback,
  fontSize: base.fontSize,
  fontWeight: base.fontWeight,
  fontStyle: base.fontStyle,
  letterSpacing: base.letterSpacing,
  wordSpacing: base.wordSpacing,
  height: base.height,
  leadingDistribution: base.leadingDistribution,
  locale: base.locale,
  foreground: paint,
);

class _TokenArt {
  _TokenArt({
    required this.token,
    required this.dim,
    required this.bright,
    required this.settled,
    required this.glow,
    required this.blur,
  });

  final _StageToken token;
  final TextPainter dim;
  final TextPainter bright;
  final TextPainter settled;
  final TextPainter glow;
  final TextPainter blur;

  double get width => bright.width;
  double get height => bright.height;

  void dispose() {
    dim.dispose();
    bright.dispose();
    settled.dispose();
    glow.dispose();
    blur.dispose();
  }
}

class _PlacedToken {
  const _PlacedToken({
    required this.art,
    required this.rect,
    required this.rotation,
    required this.baseScale,
    required this.drift,
    required this.row,
    required this.lean,
  });

  final _TokenArt art;
  final Rect rect;
  final double rotation;
  final double baseScale;
  final double drift;
  final int row;
  final bool lean;
}

class _StageRow {
  const _StageRow({
    required this.rect,
    required this.first,
    required this.last,
    required this.fromLeft,
    required this.slide,
    required this.rotation,
    required this.lean,
  });

  final Rect rect;
  final int first;
  final int last;
  final bool fromLeft;
  final double slide;
  final double rotation;
  final bool lean;
}

class _StageLineLayout {
  _StageLineLayout({
    required this.line,
    required this.tokens,
    required this.rows,
    required this.height,
    required this.fontSize,
  });

  final LyricLine line;
  final List<_PlacedToken> tokens;
  final List<_StageRow> rows;
  final double height;
  final double fontSize;

  void dispose() {
    for (final t in tokens) {
      t.art.dispose();
    }
  }
}

class _StageScene {
  _StageScene({required this.size, this.active, this.previous});

  final Size size;
  final _StageLineLayout? active;
  final _StageLineLayout? previous;

  void dispose() {
    active?.dispose();
    previous?.dispose();
  }
}

TextPainter _textPainter(
  String text,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
  Locale? locale,
) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: direction,
  textScaler: scaler,
  locale: locale,
  maxLines: 1,
)..layout();

_TokenArt _tokenArt(
  _StageToken token,
  TextStyle base,
  TextScaler scaler,
  TextDirection direction,
  Locale? locale, {
  required Color brightColor,
  required Color dimColor,
  required Color glowColor,
}) {
  final bright = base.copyWith(color: brightColor);
  final dim = base.copyWith(color: dimColor);
  final settled = base.copyWith(color: brightColor.withValues(alpha: 0.82));
  final glowPaint = Paint()
    ..color = glowColor
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
  final blurPaint = Paint()
    ..color = brightColor.withValues(alpha: 0.65)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

  return _TokenArt(
    token: token,
    dim: _textPainter(token.text, dim, scaler, direction, locale),
    bright: _textPainter(token.text, bright, scaler, direction, locale),
    settled: _textPainter(token.text, settled, scaler, direction, locale),
    glow: _textPainter(
      token.text,
      _foregroundStyle(base, glowPaint),
      scaler,
      direction,
      locale,
    ),
    blur: _textPainter(
      token.text,
      _foregroundStyle(base, blurPaint),
      scaler,
      direction,
      locale,
    ),
  );
}

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
  final TextStyle? baseStyle;
  final bool compact;
  final bool lowPower;

  @override
  ConsumerState<LyricsStage> createState() => _LyricsStageState();
}

class _LyricsStageState extends ConsumerState<LyricsStage>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<int> _clock = ValueNotifier<int>(0);
  final Stopwatch _watch = Stopwatch()..start();
  late final Ticker _ticker;
  Timer? _manualTimer;

  int _providerMs = 0;
  int _anchorMs = 0;
  Duration _anchorAt = Duration.zero;
  bool _playing = false;

  int? _manualIndex;
  double _dragDy = 0;

  _StageScene? _scene;
  Object? _sceneKey;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(covariant LyricsStage old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _manualTimer?.cancel();
      _manualIndex = null;
      _clearScene();
    }
  }

  @override
  void dispose() {
    _manualTimer?.cancel();
    _ticker.dispose();
    _clock.dispose();
    _clearScene();
    super.dispose();
  }

  void _clearScene() {
    final old = _scene;
    _scene = null;
    _sceneKey = null;
    old?.dispose();
  }

  int _estimateMs() {
    if (!_playing) return _anchorMs;
    final elapsed = _watch.elapsed - _anchorAt;
    // 播放位置每 200ms 来一次；插值最多走一秒，避免应用从后台回来时
    // 在一个旧锚点上突然跳很远。
    return _anchorMs + elapsed.inMilliseconds.clamp(0, 1000);
  }

  void _syncClock(int positionMs, bool playing) {
    if (positionMs != _providerMs) {
      _providerMs = positionMs;
      _anchorMs = positionMs;
      _anchorAt = _watch.elapsed;
      _clock.value = positionMs;
    }
    if (playing != _playing) {
      final now = _estimateMs();
      _anchorMs = now;
      _anchorAt = _watch.elapsed;
      _playing = playing;
      _clock.value = now;
    }
  }

  void _onTick(Duration _) {
    final now = _estimateMs();
    if (_clock.value != now) _clock.value = now;
    final scene = _scene;
    if (scene == null || !_needsFrames(scene, now)) {
      _ticker.stop();
    }
  }

  bool _needsFrames(_StageScene scene, int now) {
    final layout = scene.active;
    if (layout == null) return false;
    final lead = widget.style == LyricsStageStyle.tilt
        ? _tiltLead * 1000
        : _flowLead * 1000;
    final line = layout.line;
    if (now >= line.startMs - 350 && now <= line.startMs + 550) return true;
    for (final placed in layout.tokens) {
      final token = placed.art.token;
      final start = token.startMs - lead;
      // 弹簧、模糊和光晕在 1.6s 内结束；长词的填充由 200ms 心跳接着走。
      if (now >= start - 220 && now <= token.startMs + 1600) return true;
    }
    return false;
  }

  void _syncTicker(
    _StageScene? scene,
    bool reduceMotion,
    bool browsing,
    bool playing,
  ) {
    final need =
        !reduceMotion &&
        !browsing &&
        playing &&
        scene != null &&
        _needsFrames(scene, _clock.value);
    if (need) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  int _focusIndex(int active) {
    final manual = _manualIndex;
    if (manual != null && manual >= 0 && manual < widget.lyrics.lines.length) {
      return manual;
    }
    return active;
  }

  void _startManual(int focus, int delta) {
    if (widget.lyrics.lines.isEmpty) return;
    final base = focus < 0 ? 0 : focus;
    final next = (base + delta).clamp(0, widget.lyrics.lines.length - 1);
    if (next == base && focus >= 0) return;
    _manualIndex = next;
    _manualTimer?.cancel();
    _manualTimer = Timer(_stageManualResume, _resumeFollow);
    setState(() {});
  }

  void _resumeFollow() {
    _manualTimer?.cancel();
    _manualTimer = null;
    if (_manualIndex == null) return;
    setState(() {
      _manualIndex = null;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragDy.abs() < 36 && velocity.abs() < 140) {
      _dragDy = 0;
      return;
    }
    final active = widget.lyrics.indexAt(_clock.value);
    final focus = _focusIndex(active);
    final delta = _dragDy < 0 || velocity < 0 ? 1 : -1;
    _dragDy = 0;
    _startManual(focus, delta);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final active = widget.lyrics.indexAt(_clock.value);
    final focus = _focusIndex(active);
    _startManual(focus, event.scrollDelta.dy > 0 ? 1 : -1);
  }

  void _seekAt(Offset local, _StageScene scene) {
    final active = widget.lyrics.indexAt(_clock.value);
    final focus = _focusIndex(active);
    if (focus < 0 || focus >= widget.lyrics.lines.length) return;
    final layout = scene.active;
    var target = widget.lyrics.lines[focus].startMs;
    if (layout != null) {
      for (final placed in layout.tokens) {
        if (placed.rect.inflate(10).contains(local)) {
          target = placed.art.token.startMs;
          break;
        }
      }
    }
    _resumeFollow();
    ref.read(playerActionsProvider).seek(target);
  }

  _StageLineLayout? _layoutFor(
    LyricLine line,
    Size size,
    TextStyle base,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
    Color dim,
    Color bright,
    Color accent,
    Color tiltAccent,
  ) {
    final content = Size(
      size.width,
      math.max(0, size.height - _stageFooterReserve),
    );
    if (content.width < 40 || content.height < 40) return null;
    return switch (widget.style) {
      LyricsStageStyle.flow => _layoutFlow(
        line,
        content,
        base,
        scaler,
        direction,
        locale,
        dim,
        bright,
        accent,
      ),
      LyricsStageStyle.steps => _layoutSteps(
        line,
        content,
        base,
        scaler,
        direction,
        locale,
        dim,
        bright,
        accent,
      ),
      LyricsStageStyle.tilt => _layoutTilt(
        line,
        content,
        base,
        scaler,
        direction,
        locale,
        dim,
        bright,
        accent,
        tiltAccent,
      ),
    };
  }

  _StageScene _sceneFor(
    Size size,
    TextStyle base,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
    Color dim,
    Color bright,
    Color accent,
    Color tiltAccent,
    LyricLine? line,
    LyricLine? previous,
  ) {
    final key = (
      line?.startMs,
      line?.text,
      previous?.startMs,
      previous?.text,
      widget.style,
      widget.compact,
      size.width,
      size.height,
      scaler.scale(16),
      direction,
      locale,
      base,
      dim.toARGB32(),
      bright.toARGB32(),
      accent.toARGB32(),
      tiltAccent.toARGB32(),
    );
    if (_scene != null && _sceneKey == key) return _scene!;
    final next = _StageScene(
      size: size,
      active: line == null
          ? null
          : _layoutFor(
              line,
              size,
              base,
              scaler,
              direction,
              locale,
              dim,
              bright,
              accent,
              tiltAccent,
            ),
      previous: previous == null
          ? null
          : _layoutFor(
              previous,
              size,
              base,
              scaler,
              direction,
              locale,
              dim,
              bright,
              accent,
              tiltAccent,
            ),
    );
    final old = _scene;
    _scene = next;
    _sceneKey = key;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    return next;
  }

  ({bool show, int start, int end}) _interlude(
    int positionMs,
    int active,
    int focus,
  ) {
    if (_manualIndex != null) return (show: false, start: 0, end: 0);
    if (focus < 0) {
      if (widget.lyrics.lines.isEmpty) return (show: false, start: 0, end: 0);
      final first = widget.lyrics.lines.first.startMs;
      return (
        show: first >= _stageInterludeMinMs && positionMs < first,
        start: 0,
        end: first,
      );
    }
    if (focus + 1 >= widget.lyrics.lines.length) {
      return (show: false, start: 0, end: 0);
    }
    final line = widget.lyrics.lines[focus];
    final next = widget.lyrics.lines[focus + 1];
    final contentEnd = _contentEnd(line, next.startMs);
    final gap = next.startMs - contentEnd;
    final show =
        active == focus &&
        gap >= _stageInterludeMinMs &&
        positionMs >= contentEnd + 1000;
    return (show: show, start: contentEnd, end: next.startMs);
  }

  int _contentEnd(LyricLine line, int nextStart) {
    final words = line.words;
    if (words == null || words.isEmpty) {
      final span = nextStart - line.startMs;
      return line.startMs + math.min(4000, math.max(1200, (span * .6).round()));
    }
    final last = words.last;
    final natural = math.min(1500, math.max(600, last.endMs - last.startMs));
    return last.startMs + natural;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPlaying = ref.watch(playbackProvider.select((s) => s.isPlaying));
    final positionMs = ref.watch(positionProvider);
    _syncClock(positionMs, isPlaying);

    final active = widget.lyrics.indexAt(positionMs);
    final focus = _focusIndex(active);
    final line = focus >= 0 && focus < widget.lyrics.lines.length
        ? widget.lyrics.lines[focus]
        : null;
    final previous = focus > 0 ? widget.lyrics.lines[focus - 1] : null;
    final next = focus >= 0 && focus + 1 < widget.lyrics.lines.length
        ? widget.lyrics.lines[focus + 1]
        : null;
    final interlude = _interlude(positionMs, active, focus);
    final browsing = _manualIndex != null;
    final reduceMotion =
        widget.lowPower || MediaQuery.disableAnimationsOf(context);

    final bright = widget.baseStyle?.color ?? theme.colorScheme.onSurface;
    final baseStyle =
        widget.baseStyle ??
        LekisText.lyricsActive.copyWith(color: theme.colorScheme.onSurface);
    final dim = bright.withValues(alpha: 0.34);
    final accent = theme.colorScheme.tertiary;
    final tiltAccent = theme.colorScheme.secondary;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final scene = _sceneFor(
          size,
          baseStyle,
          scaler,
          direction,
          locale,
          dim,
          bright,
          accent,
          tiltAccent,
          line,
          previous,
        );
        _syncTicker(scene, reduceMotion, browsing, isPlaying);

        return Listener(
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _seekAt(details.localPosition, scene),
            onVerticalDragStart: (_) => _dragDy = 0,
            onVerticalDragUpdate: (details) => _dragDy += details.delta.dy,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  bottom: _stageFooterReserve,
                  child: Semantics(
                    button: line != null,
                    selected: line != null,
                    label: line == null
                        ? '间奏'
                        : line.translation == null
                        ? line.text
                        : '${line.text}，${line.translation}',
                    hint: '上下滑动浏览歌词，点按跳到这一句',
                    excludeSemantics: true,
                    onTap: line == null
                        ? null
                        : () {
                            _resumeFollow();
                            ref.read(playerActionsProvider).seek(line.startMs);
                          },
                    child: _StageFade(
                      child: CustomPaint(
                        painter: _StagePainter(
                          scene: scene,
                          clock: _clock,
                          style: widget.style,
                          sparks: widget.sparks,
                          reduceMotion: reduceMotion,
                          browsing: browsing,
                          showLine: !interlude.show,
                          foreground: bright,
                          accent: accent,
                          tiltAccent: tiltAccent,
                          textDirection: direction,
                        ),
                        isComplex: true,
                        willChange: true,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                if (interlude.show)
                  Positioned.fill(
                    bottom: _stageFooterReserve,
                    child: _StageInterlude(
                      key: const ValueKey('stage-interlude'),
                      startMs: interlude.start,
                      endMs: interlude.end,
                      lowPower: reduceMotion,
                    ),
                  ),
                Positioned(
                  left: LekisSpacing.lg,
                  right: LekisSpacing.lg,
                  bottom: LekisSpacing.sm,
                  child: _StageFooter(
                    translation: line?.translation,
                    next: next?.text,
                    lowPower: reduceMotion,
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

class _StageFade extends StatelessWidget {
  const _StageFade({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ShaderMask(
    shaderCallback: (rect) => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0x00000000),
        Color(0xE6000000),
        Color(0xE6000000),
        Color(0x00000000),
      ],
      stops: [0, 0.14, 0.87, 1],
    ).createShader(rect),
    blendMode: BlendMode.dstIn,
    child: child,
  );
}

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
    final translationText = translation?.trim();
    final nextText = next?.trim();
    if ((translationText == null || translationText.isEmpty) &&
        (nextText == null || nextText.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (translationText != null && translationText.isNotEmpty)
          AnimatedSwitcher(
            duration: duration,
            child: Text(
              translationText,
              key: ValueKey('tr-$translationText'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        if (translationText != null &&
            translationText.isNotEmpty &&
            nextText != null &&
            nextText.isNotEmpty)
          const SizedBox(height: LekisSpacing.xs),
        if (nextText != null && nextText.isNotEmpty)
          AnimatedSwitcher(
            duration: duration,
            child: Text(
              nextText,
              key: ValueKey('next-$nextText'),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
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

class _StageInterlude extends ConsumerStatefulWidget {
  const _StageInterlude({
    super.key,
    required this.startMs,
    required this.endMs,
    required this.lowPower,
  });

  final int startMs;
  final int endMs;
  final bool lowPower;

  @override
  ConsumerState<_StageInterlude> createState() => _StageInterludeState();
}

class _StageInterludeState extends ConsumerState<_StageInterlude>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _StageInterlude old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final animate =
        !widget.lowPower && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!animate && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final position = ref.watch(positionProvider);
    final span = math.max(1, widget.endMs - widget.startMs);
    final progress = _clamp01((position - widget.startMs) / span);
    final dot = 14.0;
    return Semantics(
      container: true,
      label: '间奏',
      excludeSemantics: true,
      child: Center(
        child: AnimatedBuilder(
          animation: _breath,
          builder: (context, child) => Transform.scale(
            scale: 0.94 + 0.1 * Curves.easeInOut.transform(_breath.value),
            child: child,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: LekisSpacing.lg),
                Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fg.withValues(
                      alpha: 0.2 + 0.7 * _clamp01(progress * 3 - i),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------

double _stageFontSize(Size size, LyricsStageStyle style, double baseSize) {
  final width = size.width;
  final height = size.height;
  final flow = math.min(
    (width * 0.085).clamp(22.0, 50.0),
    math.max(24.0, baseSize * 1.25),
  );
  final tilt = math.min(
    (width * 0.105).clamp(28.0, 64.0),
    math.max(28.0, baseSize * 1.9),
  );
  final base = style == LyricsStageStyle.tilt ? tilt * .9 : flow;
  final heightCap = style == LyricsStageStyle.tilt
      ? height * 0.2
      : height * 0.16;
  return math.max(16, math.min(base, heightCap));
}

_StageLineLayout? _layoutFlow(
  LyricLine line,
  Size size,
  TextStyle base,
  TextScaler scaler,
  TextDirection direction,
  Locale? locale,
  Color dim,
  Color bright,
  Color accent,
) {
  final tokens = _stageTokens(line, chars: false);
  if (tokens.isEmpty) return null;
  final fontSize = _stageFontSize(
    size,
    LyricsStageStyle.flow,
    base.fontSize ?? 32,
  );
  final style = base.copyWith(
    fontSize: fontSize,
    fontWeight: FontWeight.w800,
    height: 1.16,
  );
  final arts = [
    for (final token in tokens)
      _tokenArt(
        token,
        style,
        scaler,
        direction,
        locale,
        brightColor: bright,
        dimColor: dim,
        glowColor: accent,
      ),
  ];
  final maxWidth = math.max(80.0, size.width - 2 * LekisSpacing.xl);
  final rows = <List<int>>[];
  final rowWidths = <double>[];
  var current = <int>[];
  var currentWidth = 0.0;
  var previousGrowth = 0.0;

  for (var i = 0; i < arts.length; i++) {
    final art = arts[i];
    final growth = art.width * 0.08;
    final gap = current.isEmpty
        ? 0.0
        : _wordGap(tokens[current.last], fontSize);
    final advance = current.isEmpty
        ? art.width
        : gap + previousGrowth + growth + art.width;
    if (current.isNotEmpty && currentWidth + advance > maxWidth) {
      rows.add(current);
      rowWidths.add(currentWidth);
      current = [];
      currentWidth = 0;
      previousGrowth = 0;
    }
    currentWidth += current.isEmpty
        ? art.width
        : _wordGap(tokens[current.last], fontSize) +
              previousGrowth +
              growth +
              art.width;
    current.add(i);
    previousGrowth = growth;
  }
  if (current.isNotEmpty) {
    rows.add(current);
    rowWidths.add(currentWidth);
  }

  final rowHeight = math.max(fontSize * 1.35, 24.0);
  final totalHeight =
      rows.length * rowHeight + math.max(0, rows.length - 1) * fontSize * 0.12;
  final lift = (_lineRandom(line.startMs, 31) - 0.5) * size.height * 0.1;
  final originY =
      (size.height - totalHeight) / 2 +
      lift.clamp(-size.height * 0.08, size.height * 0.08);

  final placed = <_PlacedToken>[];
  final stageRows = <_StageRow>[];
  var rowY = originY;
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final rowWidth = rowWidths[r];
    final startX = (size.width - rowWidth) / 2;
    final rowRect = Rect.fromLTRB(
      startX,
      rowY,
      startX + rowWidth,
      rowY + rowHeight,
    );
    stageRows.add(
      _StageRow(
        rect: rowRect,
        first: placed.length,
        last: placed.length + row.length - 1,
        fromLeft: true,
        slide: 0,
        rotation: 0,
        lean: false,
      ),
    );
    var x = startX;
    int? previousIndex;
    for (final index in row) {
      final art = arts[index];
      final seed = line.startMs + index * 131;
      final growth = art.width * 0.08;
      if (previousIndex != null) {
        x += _wordGap(tokens[previousIndex], fontSize);
      }
      x += growth;
      final center = Offset(
        x + art.width / 2 + (_lineRandom(seed, 1) - 0.5) * 15,
        rowY + rowHeight / 2 + (_lineRandom(seed, 2) - 0.5) * 14,
      );
      placed.add(
        _PlacedToken(
          art: art,
          rect: Rect.fromCenter(
            center: center,
            width: art.width,
            height: art.height,
          ),
          rotation: (_lineRandom(seed, 3) - 0.5) * 0.16,
          baseScale: 1.04 + _lineRandom(seed, 4) * 0.15,
          drift: (_lineRandom(seed, 5) - 0.5) * 0.18,
          row: r,
          lean: false,
        ),
      );
      x += art.width + growth;
      previousIndex = index;
    }
    rowY += rowHeight + fontSize * 0.12;
  }

  return _StageLineLayout(
    line: line,
    tokens: placed,
    rows: stageRows,
    height: totalHeight,
    fontSize: fontSize,
  );
}

_StageLineLayout? _layoutSteps(
  LyricLine line,
  Size size,
  TextStyle base,
  TextScaler scaler,
  TextDirection direction,
  Locale? locale,
  Color dim,
  Color bright,
  Color accent,
) {
  final tokens = _stageTokens(line, chars: false);
  if (tokens.isEmpty) return null;
  final fontSize =
      _stageFontSize(size, LyricsStageStyle.steps, base.fontSize ?? 32) * 0.84;
  final style = base.copyWith(
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: 1.16,
  );
  final arts = [
    for (final token in tokens)
      _tokenArt(
        token,
        style,
        scaler,
        direction,
        locale,
        brightColor: bright,
        dimColor: dim,
        glowColor: accent,
      ),
  ];
  final maxWidth = math.max(80.0, size.width - 2 * LekisSpacing.xl);
  final targetWidth = maxWidth * 0.56;
  final rows = <List<int>>[];
  final rowWidths = <double>[];
  var current = <int>[];
  var currentWidth = 0.0;
  var previousGrowth = 0.0;

  for (var i = 0; i < arts.length; i++) {
    final art = arts[i];
    final growth = art.width * 0.10;
    final gap = current.isEmpty
        ? 0.0
        : _wordGap(tokens[current.last], fontSize);
    final advance = current.isEmpty
        ? art.width
        : gap + previousGrowth + growth + art.width;
    final full = current.length >= 3;
    if (current.isNotEmpty &&
        (currentWidth + advance > targetWidth ||
            (full && currentWidth + advance > maxWidth * 0.9))) {
      rows.add(current);
      rowWidths.add(currentWidth);
      current = [];
      currentWidth = 0;
      previousGrowth = 0;
    }
    currentWidth += current.isEmpty
        ? art.width
        : _wordGap(tokens[current.last], fontSize) +
              previousGrowth +
              growth +
              art.width;
    current.add(i);
    previousGrowth = growth;
  }
  if (current.isNotEmpty) {
    rows.add(current);
    rowWidths.add(currentWidth);
  }

  final rowHeight = math.max(fontSize * 1.35, 22.0);
  final rowGap = fontSize * 0.36;
  final totalHeight =
      rows.length * rowHeight + math.max(0, rows.length - 1) * rowGap;
  final originY = (size.height - totalHeight) / 2;

  final placed = <_PlacedToken>[];
  final stageRows = <_StageRow>[];
  var rowY = originY;
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final fromLeft = r.isEven;
    final rowWidth = rowWidths[r];
    final stagger =
        LekisSpacing.sm + _lineRandom(line.startMs + r * 73, 21) * 26;
    final startX = fromLeft
        ? math.max(LekisSpacing.md, stagger)
        : math.max(
            LekisSpacing.md,
            size.width - LekisSpacing.md - rowWidth - stagger,
          );
    final rowRect = Rect.fromLTRB(
      startX,
      rowY,
      startX + rowWidth,
      rowY + rowHeight,
    );
    stageRows.add(
      _StageRow(
        rect: rowRect,
        first: placed.length,
        last: placed.length + row.length - 1,
        fromLeft: fromLeft,
        slide:
            (fromLeft ? -1 : 1) *
            (24 + _lineRandom(line.startMs + r * 73, 22) * 28),
        rotation: 0,
        lean: false,
      ),
    );
    var x = startX;
    int? previousIndex;
    for (final index in row) {
      final art = arts[index];
      final seed = line.startMs + index * 131;
      final growth = art.width * 0.10;
      if (previousIndex != null) {
        x += _wordGap(tokens[previousIndex], fontSize);
      }
      x += growth;
      final center = Offset(
        x + art.width / 2 + (_lineRandom(seed, 11) - 0.5) * 5,
        rowY + rowHeight / 2 + (_lineRandom(seed, 12) - 0.5) * 5,
      );
      placed.add(
        _PlacedToken(
          art: art,
          rect: Rect.fromCenter(
            center: center,
            width: art.width,
            height: art.height,
          ),
          rotation: (_lineRandom(seed, 13) - 0.5) * 0.07,
          baseScale: 0.97 + _lineRandom(seed, 14) * 0.08,
          drift: (_lineRandom(seed, 15) - 0.5) * 0.12,
          row: r,
          lean: false,
        ),
      );
      x += art.width + growth;
      previousIndex = index;
    }
    rowY += rowHeight + rowGap;
  }

  return _StageLineLayout(
    line: line,
    tokens: placed,
    rows: stageRows,
    height: totalHeight,
    fontSize: fontSize,
  );
}

_StageLineLayout? _layoutTilt(
  LyricLine line,
  Size size,
  TextStyle base,
  TextScaler scaler,
  TextDirection direction,
  Locale? locale,
  Color dim,
  Color bright,
  Color accent,
  Color tiltAccent,
) {
  final tokens = _stageTokens(line, chars: true);
  if (tokens.isEmpty) return null;
  final groups = <List<int>>[];
  var currentWord = tokens.first.wordIndex;
  var group = <int>[];
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].wordIndex != currentWord) {
      if (group.isNotEmpty) groups.add(group);
      group = [];
      currentWord = tokens[i].wordIndex;
    }
    group.add(i);
  }
  if (group.isNotEmpty) groups.add(group);
  if (groups.isEmpty) return null;

  final totalChars = tokens.length;
  var wanted = totalChars <= 10
      ? 1
      : totalChars <= 20
      ? 2
      : totalChars <= 32
      ? 3
      : 4;
  // 哪怕一句很短，也拆成两行，让倾斜行与直立行形成对比。
  if (groups.length >= 2 && totalChars >= 4) wanted = math.max(wanted, 2);
  final partCount = math.min(groups.length, wanted);
  // 在词边界上找最接近均分的位置，避免第一行只有一个短词。
  final prefix = <int>[0];
  for (final group in groups) {
    prefix.add(prefix.last + group.length);
  }
  final cuts = <int>[];
  var fromGroup = 0;
  for (var k = 1; k < partCount; k++) {
    final target = totalChars * k / partCount;
    final lastPossible = groups.length - (partCount - k);
    var best = fromGroup + 1;
    var bestDelta = double.infinity;
    for (var cut = fromGroup + 1; cut <= lastPossible; cut++) {
      final delta = (prefix[cut] - target).abs();
      if (delta < bestDelta) {
        best = cut;
        bestDelta = delta.toDouble();
      }
    }
    cuts.add(best);
    fromGroup = best;
  }
  final parts = <List<int>>[];
  var startGroup = 0;
  for (final cut in [...cuts, groups.length]) {
    final part = <int>[];
    for (var g = startGroup; g < cut; g++) {
      part.addAll(groups[g]);
    }
    if (part.isNotEmpty) parts.add(part);
    startGroup = cut;
  }
  if (parts.isEmpty) return null;

  final maxChars = parts.map((p) => p.length).reduce(math.max).clamp(1, 1000);
  final width = size.width;
  final height = size.height;
  var fontSize = _stageFontSize(
    size,
    LyricsStageStyle.tilt,
    base.fontSize ?? 32,
  );
  fontSize = math.min(
    fontSize,
    (width - 2 * LekisSpacing.lg) / (maxChars * 0.86),
  );
  fontSize = math.min(fontSize, height / (parts.length * 1.7));
  fontSize = math.max(18, fontSize);

  final leanIndex = (_lineRandom(line.startMs, 100) * parts.length)
      .floor()
      .clamp(0, parts.length - 1);
  final placed = <_PlacedToken>[];
  final stageRows = <_StageRow>[];
  final rowHeights = <double>[];
  final rowWidths = <double>[];
  final rowArts = <List<_TokenArt>>[];

  for (var p = 0; p < parts.length; p++) {
    final lean = p == leanIndex;
    final style = base.copyWith(
      fontSize: lean ? fontSize * 1.02 : fontSize,
      fontWeight: lean ? FontWeight.w500 : FontWeight.w700,
      fontStyle: lean ? FontStyle.italic : FontStyle.normal,
      letterSpacing: lean ? fontSize * 0.02 : 0,
      height: lean ? 1.3 : 1.36,
    );
    final color = lean ? tiltAccent : bright;
    final arts = [
      for (final index in parts[p])
        _tokenArt(
          tokens[index],
          style,
          scaler,
          direction,
          locale,
          brightColor: color,
          dimColor: dim,
          glowColor: lean ? tiltAccent : accent,
        ),
    ];
    var rowWidth = 0.0;
    for (var i = 0; i < arts.length; i++) {
      final art = arts[i];
      rowWidth += art.width;
      if (i < arts.length - 1) {
        rowWidth += tokens[parts[p][i]].spaceAfter
            ? fontSize * 0.26
            : fontSize * 0.04;
      }
    }
    rowArts.add(arts);
    rowWidths.add(rowWidth);
    rowHeights.add(fontSize * (lean ? 1.65 : 1.48));
  }

  final totalHeight =
      rowHeights.fold<double>(0, (a, b) => a + b) +
      math.max(0, parts.length - 1) * fontSize * 0.18;
  var rowY = (height - totalHeight) / 2 - fontSize * 0.08;

  for (var p = 0; p < parts.length; p++) {
    final lean = p == leanIndex;
    final rotation = lean
        ? (_lineRandom(line.startMs + p * 37, 70) - 0.5) * 0.18
        : 0.0;
    final rowWidth = rowWidths[p];
    final startX = (width - rowWidth) / 2;
    final rowCenterX = width / 2;
    final rowCenterY = rowY + rowHeights[p] / 2;
    final rect = Rect.fromLTRB(
      startX,
      rowY,
      startX + rowWidth,
      rowY + rowHeights[p],
    );
    stageRows.add(
      _StageRow(
        rect: rect,
        first: placed.length,
        last: placed.length + parts[p].length - 1,
        fromLeft: true,
        slide: 0,
        rotation: rotation,
        lean: lean,
      ),
    );
    var x = startX;
    for (var i = 0; i < rowArts[p].length; i++) {
      final art = rowArts[p][i];
      final token = tokens[parts[p][i]];
      final centerX = x + art.width / 2;
      final alternate = lean
          ? (i.isEven ? -fontSize * 0.055 : fontSize * 0.055)
          : 0.0;
      final centerY =
          rowCenterY +
          (lean ? (centerX - rowCenterX) * math.tan(rotation) : 0) +
          alternate;
      placed.add(
        _PlacedToken(
          art: art,
          rect: Rect.fromCenter(
            center: Offset(centerX, centerY),
            width: art.width,
            height: art.height,
          ),
          rotation: rotation,
          baseScale: lean ? 0.94 : 1.0,
          drift: 0,
          row: p,
          lean: lean,
        ),
      );
      x += art.width;
      if (i < rowArts[p].length - 1) {
        x += token.spaceAfter ? fontSize * 0.26 : fontSize * 0.04;
      }
    }
    rowY += rowHeights[p] + fontSize * 0.18;
  }

  return _StageLineLayout(
    line: line,
    tokens: placed,
    rows: stageRows,
    height: totalHeight,
    fontSize: fontSize,
  );
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
    required this.reduceMotion,
    required this.browsing,
    required this.showLine,
    required this.foreground,
    required this.accent,
    required this.tiltAccent,
    required this.textDirection,
  }) : super(repaint: clock);

  final _StageScene scene;
  final ValueNotifier<int> clock;
  final LyricsStageStyle style;
  final bool sparks;
  final bool reduceMotion;
  final bool browsing;
  final bool showLine;
  final Color foreground;
  final Color accent;
  final Color tiltAccent;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final now = clock.value;
    final active = scene.active;
    if (active == null) return;

    if (!browsing &&
        !reduceMotion &&
        scene.previous != null &&
        now < active.line.startMs + 520) {
      _paintPrevious(canvas, scene.previous!, now, active.line.startMs);
    }
    if (!showLine) return;

    if (browsing || reduceMotion) {
      _paintStatic(canvas, active);
      return;
    }

    final lead = style == LyricsStageStyle.tilt ? _tiltLead : _flowLead;
    for (var r = 0; r < active.rows.length; r++) {
      final row = active.rows[r];
      final first = active.tokens[row.first].art.token;
      final rowSince = now / 1000 - (first.startMs / 1000 - lead);
      if (style == LyricsStageStyle.steps) {
        _paintGuide(canvas, row, rowSince, active.tokens[row.last].art.token);
      }
      for (var i = row.first; i <= row.last; i++) {
        _paintToken(canvas, active, active.tokens[i], r, now, lead);
      }
    }
  }

  void _paintPrevious(
    Canvas canvas,
    _StageLineLayout layout,
    int now,
    int currentStart,
  ) {
    final gone = _clamp01((now - currentStart) / 520);
    if (gone >= 1) return;
    final opacity = 1 - _easeOutCubic(gone);
    canvas.save();
    canvas.translate(0, -8 * gone);
    _paintLayer(canvas, opacity, () {
      for (final placed in layout.tokens) {
        final art = placed.art;
        canvas.save();
        canvas.translate(placed.rect.center.dx, placed.rect.center.dy);
        canvas.rotate(placed.rotation);
        canvas.scale(placed.baseScale);
        art.settled.paint(canvas, Offset(-art.width / 2, -art.height / 2));
        canvas.restore();
      }
    });
    canvas.restore();
  }

  void _paintStatic(Canvas canvas, _StageLineLayout layout) {
    final now = clock.value / 1000;
    for (final placed in layout.tokens) {
      final art = placed.art;
      final token = art.token;
      final sung = browsing || now >= token.startMs / 1000;
      canvas.save();
      canvas.translate(placed.rect.center.dx, placed.rect.center.dy);
      if (!browsing && reduceMotion) {
        // 静态高亮：不旋转、不缩放，只按时间决定明暗。
        canvas.scale(1);
      } else {
        canvas.rotate(placed.rotation);
        canvas.scale(placed.baseScale);
      }
      final offset = Offset(-art.width / 2, -art.height / 2);
      if (!browsing && reduceMotion) {
        final span = math.max(1, token.endMs - token.startMs);
        final fill = _clamp01((clock.value - token.startMs) / span);
        art.dim.paint(canvas, offset);
        if (fill > 0) {
          canvas.save();
          final w = art.width;
          canvas.clipRect(
            textDirection == TextDirection.rtl
                ? Rect.fromLTRB(
                    w / 2 - w * fill,
                    -art.height / 2 - 2,
                    w / 2,
                    art.height / 2 + 2,
                  )
                : Rect.fromLTRB(
                    -w / 2,
                    -art.height / 2 - 2,
                    -w / 2 + w * fill,
                    art.height / 2 + 2,
                  ),
          );
          art.bright.paint(canvas, offset);
          canvas.restore();
        }
      } else {
        (sung ? art.settled : art.dim).paint(canvas, offset);
      }
      canvas.restore();
    }
  }

  void _paintGuide(
    Canvas canvas,
    _StageRow row,
    double since,
    _StageToken last,
  ) {
    final guide = _easeOutCubic(_clamp01(since / .4));
    if (guide <= 0) return;
    final started = since >= 0;
    final done = clock.value >= last.endMs;
    final color = done
        ? foreground.withValues(alpha: 0.18)
        : started
        ? accent.withValues(alpha: 0.8 * guide)
        : foreground.withValues(alpha: 0.12 * guide);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    final bottom = row.rect.bottom + LekisSpacing.md;
    if (row.fromLeft) {
      final x = row.rect.left - LekisSpacing.sm;
      canvas.drawLine(Offset(x, bottom), Offset(x, bottom - 26 * guide), paint);
      canvas.drawLine(
        Offset(x - LekisSpacing.xs, bottom - LekisSpacing.sm),
        Offset(
          x - LekisSpacing.xs + (row.rect.width + 28) * guide,
          bottom - LekisSpacing.sm,
        ),
        paint,
      );
    } else {
      final x = row.rect.right + LekisSpacing.sm;
      canvas.drawLine(Offset(x, bottom), Offset(x, bottom - 26 * guide), paint);
      canvas.drawLine(
        Offset(x + LekisSpacing.xs, bottom - LekisSpacing.sm),
        Offset(
          x + LekisSpacing.xs - (row.rect.width + 28) * guide,
          bottom - LekisSpacing.sm,
        ),
        paint,
      );
    }
  }

  void _paintToken(
    Canvas canvas,
    _StageLineLayout layout,
    _PlacedToken placed,
    int rowIndex,
    int now,
    double lead,
  ) {
    final art = placed.art;
    final token = art.token;
    final row = layout.rows[rowIndex];
    final rowFirst = layout.tokens[row.first].art.token;
    final nowSec = now / 1000;
    final startSec = token.startMs / 1000 - lead;
    final endSec = math.max(token.endMs / 1000, token.startMs / 1000 + .15);
    final since = nowSec - startSec;
    final after = nowSec - endSec;
    final rowSince = nowSec - (rowFirst.startMs / 1000 - lead);
    if (style == LyricsStageStyle.tilt) {
      _paintTiltToken(canvas, placed, row, since, rowSince, nowSec);
      return;
    }

    if (since <= 0) return;
    final singing = math.max(.08, endSec - token.startMs / 1000);
    final seed = token.startMs + token.index * 137;
    final waitAngle = _lineRandom(seed, 1) * math.pi * 2;
    final waitRadius = layout.fontSize * (0.55 + _lineRandom(seed, 2) * 0.7);
    final waitX = placed.rect.center.dx + math.cos(waitAngle) * waitRadius;
    final waitY =
        placed.rect.center.dy + math.sin(waitAngle) * waitRadius * .55;
    final waitRotation = placed.rotation + 0.35 + _lineRandom(seed, 3) * 0.4;
    final e = _springStep(since);
    var x = _lerp(waitX, placed.rect.center.dx, e);
    var y = _lerp(waitY, placed.rect.center.dy, e);
    var scale = _lerp(0.5, placed.baseScale * 1.36, e);
    var rotation = _lerp(waitRotation, placed.rotation, e);
    var opacity = _clamp01(since / .1);
    var blur = 8 * (1 - _clamp01(since / .22));
    var glow = _clamp01(since / math.max(.08, .3 * singing));
    var fill = _clamp01(
      (nowSec - token.startMs / 1000) / (endSec - token.startMs / 1000),
    );

    if (rowSince < .12) {
      final rowE = _springStep(rowSince);
      x += row.slide * (1 - rowE);
      scale *= .9 + .1 * rowE;
      opacity *= _clamp01(rowSince / .12);
    }

    if (after > 0) {
      final q = _easeOutCubic(after / .5);
      scale = _lerp(placed.baseScale * 1.36, placed.baseScale, q);
      // 歌词稳定后用 settled 画笔表达 82% 明度，避免每个词每帧开 layer。
      opacity = 1;
      rotation = placed.rotation + placed.drift * _clamp01(after / 5);
      glow = 1 - _clamp01(after / .9);
      fill = 1;
    }
    if (opacity <= .01) return;

    final center = Offset(x, y);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.scale(scale);

    _paintLayer(canvas, opacity, () {
      final offset = Offset(-art.width / 2, -art.height / 2);
      if (glow > .01) {
        _paintLayer(canvas, glow * .8, () => art.glow.paint(canvas, offset));
      }
      if (blur > .3) {
        _paintLayer(
          canvas,
          (blur / 8) * .65,
          () => art.blur.paint(canvas, offset),
        );
      }
      art.dim.paint(canvas, offset);
      if (fill > 0) {
        canvas.save();
        final w = art.width;
        canvas.clipRect(
          textDirection == TextDirection.rtl
              ? Rect.fromLTRB(
                  w / 2 - w * fill,
                  -art.height / 2 - 2,
                  w / 2,
                  art.height / 2 + 2,
                )
              : Rect.fromLTRB(
                  -w / 2,
                  -art.height / 2 - 2,
                  -w / 2 + w * fill,
                  art.height / 2 + 2,
                ),
        );
        (after > 0 ? art.settled : art.bright).paint(canvas, offset);
        canvas.restore();
      }
    });
    canvas.restore();

    if (token.spark) {
      _paintSparks(canvas, token, center, scale, now);
    }
  }

  void _paintTiltToken(
    Canvas canvas,
    _PlacedToken placed,
    _StageRow row,
    double since,
    double rowSince,
    double nowSec,
  ) {
    final art = placed.art;
    final token = art.token;
    final localIndex = token.index - row.first;
    final entryIn = _easeOutCubic(_clamp01((since - localIndex * .025) / .55));
    final rowIn = _easeOutCubic(_clamp01(rowSince / .55));
    if (rowIn <= 0) return;
    final span = math.max(.2, (token.endMs - token.startMs) / 1000);
    final elapsed = nowSec - token.startMs / 1000;
    final swell = elapsed < 0
        ? 0.0
        : elapsed <= span
        ? math.sin(elapsed / span * math.pi)
        : .25 * _clamp01((elapsed - span) / (span * 1.2));
    final pulse = row.lean ? .18 : .14;
    final scale =
        (row.lean ? .92 + .08 * rowIn : 1.0) *
        (1 + swell * pulse) *
        placed.baseScale;
    final y =
        placed.rect.center.dy -
        (row.lean ? .0 : 20 * (1 - rowIn)) -
        (row.lean ? 0 : 12 * (1 - entryIn));
    final opacity = row.lean ? entryIn : rowIn * entryIn;
    if (opacity <= .01) return;
    final sung = nowSec >= token.startMs / 1000;
    final glow = sung && elapsed < span + .4
        ? _clamp01(1 - math.max(0, elapsed - span) / .4)
        : 0.0;
    final center = Offset(placed.rect.center.dx, y);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(placed.rotation);
    canvas.scale(scale);
    _paintLayer(canvas, opacity, () {
      final offset = Offset(-art.width / 2, -art.height / 2);
      if (glow > .01) {
        _paintLayer(canvas, glow * .55, () => art.glow.paint(canvas, offset));
      }
      (sung ? art.settled : art.dim).paint(canvas, offset);
    });
    canvas.restore();

    if (token.spark) {
      _paintSparks(canvas, token, center, scale, (nowSec * 1000).round());
    }
  }

  void _paintLayer(Canvas canvas, double opacity, VoidCallback paint) {
    if (opacity >= .999) {
      paint();
      return;
    }
    if (opacity <= .001) return;
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: _clamp01(opacity)),
    );
    paint();
    canvas.restore();
  }

  void _paintSparks(
    Canvas canvas,
    _StageToken token,
    Offset center,
    double scale,
    int now,
  ) {
    if (!sparks || reduceMotion) return;
    final duration = token.sparkLast ? _sparkLastTime : _sparkTime;
    final since = (now - token.startMs) / 1000;
    if (since < 0 || since >= duration) return;
    final t = since / duration;
    final out = 1 - math.pow(1 - t, 3).toDouble();
    final fade = (1 - t) * (1 - t);
    final count = token.sparkLast ? 16 : 9;
    final width = math.max(24.0, token.text.length * 16 * scale);
    final height = 28.0 * scale;
    final reach = (token.sparkLast ? 1.25 : .75) * width;
    final hot = Color.lerp(accent, Colors.white, .55 * (1 - t))!;
    final paint = Paint()
      ..strokeWidth = (0.8 + 1.6 * (1 - t)) * scale
      ..strokeCap = StrokeCap.round
      ..color = hot.withValues(alpha: .9 * fade);
    final seed = token.startMs + token.index * 71;
    for (var i = 0; i < count; i++) {
      final angle = math.pi * 2 * (i + _lineRandom(seed, i) * .7) / count;
      final dx = math.cos(angle);
      final dy = math.sin(angle);
      final edge = width / 2 * .7 * dx.abs() + height / 2 * .7 * dy.abs();
      final head = edge + reach * (.55 + .45 * _lineRandom(seed, i + 50)) * out;
      final tail = math.max(edge, head - reach * .3 * (1 - t));
      canvas.drawLine(
        Offset(center.dx + dx * tail, center.dy + dy * tail),
        Offset(center.dx + dx * head, center.dy + dy * head),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) =>
      old.scene != scene ||
      old.style != style ||
      old.sparks != sparks ||
      old.reduceMotion != reduceMotion ||
      old.browsing != browsing ||
      old.showLine != showLine ||
      old.foreground != foreground ||
      old.accent != accent ||
      old.tiltAccent != tiltAccent ||
      old.textDirection != textDirection;
}
