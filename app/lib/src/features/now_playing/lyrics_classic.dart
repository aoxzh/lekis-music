// 经典歌词：Apple Music 式的逐行滚动视图（默认视图）。
//
// 当前句固定在视口 30% 的位置，上下相邻句按距离淡出 / 轻微模糊；用户手动
// 滚动后暂停自动跟随 3 秒，点按某句跳到该句。只有当前句会做逐字高亮
// （增强 LRC 带逐字时间时），其余行就是普通 Text，静止时不产生额外开销。
//
// 这个文件从最早的实现移植而来，刻意保持自包含：解析结果、文字样式和
// 低电量开关都从外面传进来，文件内不读歌词数据源。
//
// 性能：整个列表只在当前句变化时重建；逐字填充由 [LyricsClock] 驱动一个
// 独立的 painter（外推播放位置，按屏幕刷新率走，不触发重建 / 重新排版）；
// 行的明暗写进文字颜色而不是 Opacity 图层；模糊只给当前句附近的几行，
// 低电量和手动浏览时完全关闭；内容整体包在 RepaintBoundary 里，弹簧滚动
// 时只移动图层、不重绘文字。

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Where the active line sits, as a fraction of the viewport height.
const double _activeLineAnchor = 0.3;

/// Inactive lines further than this from the active one skip the blur layer
/// (they have faded to the inactive opacity anyway; every blurred line is
/// one more offscreen layer per frame while the list springs).
const int _blurWindow = 4;

/// After the user scrolls by hand, auto-follow resumes after this pause.
const Duration _resumeFollowAfter = Duration(seconds: 3);

/// A gap at least this long before the first line (or on a blank
/// "instrumental" line) shows the breathing-dots interlude.
const int _interludeMinMs = 3000;

/// Widest a lyric line gets in the roomy layout; longer text wraps so wide
/// panes stay readable.
const double _maxLineWidth = 680;

/// Narrow windows (the split Now Playing pane) get a tighter column.
const double _compactMaxLineWidth = 560;

/// Opacity for a line [distance] lines away from the active one
/// (negative = already sung). The far lines stay clearly below the active
/// one but readable: at 0.3 they disappeared into a bright cover.
double _lineOpacity(int distance) => switch (distance) {
  0 => 1,
  1 => 0.62,
  -1 => 0.45,
  _ => 0.38,
};

/// Blur for a line [distance] lines away: neighbours stay sharp, the rest
/// soften gradually so the eye lands on the active line.
double _lineBlur(int distance) {
  final d = distance.abs();
  if (d <= 1) return 0;
  return ((d - 1) * 0.8).clamp(0.0, LekisType.lyricsInactiveBlur * 2);
}

/// Soft top / bottom fade so lines dissolve into the edges.
Widget _edgeFade({required Widget child}) => ShaderMask(
  shaderCallback: (rect) => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Alpha-only mask; the hue is irrelevant.
    colors: [
      Color(0x00000000),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0x00000000),
    ],
    stops: [0, 0.12, 0.85, 1],
  ).createShader(rect),
  blendMode: BlendMode.dstIn,
  child: child,
);

/// 经典（Apple Music 风格）歌词：当前句停留在视口上部，其余句子按距离
/// 淡出，点按任意一句跳转。
///
/// 所有行始终参与布局和绘制，因此暂停（播放位置不再更新）时当前句仍然
/// 留在屏幕上、保持高亮。
class ClassicLyrics extends ConsumerStatefulWidget {
  const ClassicLyrics({
    super.key,
    required this.lyrics,
    required this.style,
    this.compact = false,
    this.lowPower = false,
  });

  final ParsedLyrics lyrics;
  final TextStyle style;

  /// 窄窗口：行宽和左右留白收紧一点。
  final bool compact;

  /// 减少动态 / 低电量：不做逐行模糊。
  final bool lowPower;

  @override
  ConsumerState<ClassicLyrics> createState() => _ClassicLyricsState();
}

class _ClassicLyricsState extends ConsumerState<ClassicLyrics>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _contentKey = GlobalKey();
  final _introKey = GlobalKey();
  late List<GlobalKey> _lineKeys = _keysFor(widget.lyrics);
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
  )..addListener(_onSpringTick);

  /// Active item: -1 = intro dots (or nothing yet), otherwise a line index.
  int? _active;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  static List<GlobalKey> _keysFor(ParsedLyrics l) =>
      List.generate(l.lines.length, (_) => GlobalKey());

  bool get _hasIntro =>
      widget.lyrics.lines.isNotEmpty &&
      widget.lyrics.lines.first.startMs >= _interludeMinMs;

  double get _lineWidth =>
      widget.compact ? _compactMaxLineWidth : _maxLineWidth;

  double get _horizontalPadding =>
      widget.compact ? LekisSpacing.md : LekisSpacing.lg;

  @override
  void didUpdateWidget(covariant ClassicLyrics old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _lineKeys = _keysFor(widget.lyrics);
      // 换了一份歌词（例如在线补全 / 手动编辑）：下一帧重新跟随当前句，
      // 否则会停在旧歌词的滚动位置。
      _active = null;
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _spring.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSpringTick() {
    if (!_scroll.hasClients || _userScrolling) return;
    final pos = _scroll.position;
    _scroll.jumpTo(
      _spring.value.clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// Spring-scroll so item [index] (-1 = intro) sits at [_activeLineAnchor].
  void _follow(int index, {bool animate = true}) {
    if (_userScrolling || !_scroll.hasClients) return;
    final key = index < 0
        ? _introKey
        : (index < _lineKeys.length ? _lineKeys[index] : null);
    final itemBox = key?.currentContext?.findRenderObject() as RenderBox?;
    final contentBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    final pos = _scroll.position;
    double target;
    if (itemBox == null || contentBox == null || !itemBox.attached) {
      if (index >= 0) return;
      target = pos.minScrollExtent; // no intro widget: rest at the top
    } else {
      // The scroll view's top padding already equals the anchor
      // (viewport * _activeLineAnchor), so scrolling by the item's offset
      // inside the content column puts it exactly on the anchor.
      target = itemBox.localToGlobal(Offset.zero, ancestor: contentBox).dy;
    }
    target = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (!animate) {
      _spring.stop();
      _scroll.jumpTo(target);
      return;
    }
    final velocity = _spring.isAnimating ? _spring.velocity : 0.0;
    _spring.value = pos.pixels;
    _spring.animateWith(
      SpringSimulation(
        LekisMotion.springLyricsScroll,
        pos.pixels,
        target,
        velocity,
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _spring.stop();
      _resumeTimer?.cancel();
      // Browsing by hand: drop the depth blur so every line is readable.
      if (!_userScrolling) setState(() => _userScrolling = true);
    } else if (n is ScrollEndNotification && _userScrolling) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(_resumeFollowAfter, () {
        if (!mounted) return;
        setState(() => _userScrolling = false);
        _follow(_active ?? -1);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    // Rebuilds only when the active line index changes, not every tick.
    // Paused playback stops ticking but keeps its position, so the current
    // line stays selected (and painted) while paused.
    final active = ref.watch(positionProvider.select(lyrics.indexAt));
    if (active != _active) {
      final first = _active == null;
      _active = active;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => mounted ? _follow(active, animate: !first) : null,
      );
    }

    final actions = ref.read(playerActionsProvider);
    final blurOn = !widget.lowPower && !_userScrolling;

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: _edgeFade(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.only(
                top: h * _activeLineAnchor,
                bottom: h * (1 - _activeLineAnchor),
                left: _horizontalPadding,
                right: _horizontalPadding,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: _lineWidth),
                  // 弹簧滚动每帧只改偏移：内容自成一层，不必重绘。
                  child: RepaintBoundary(
                    child: Column(
                      key: _contentKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_hasIntro)
                          _InterludeDots(
                            key: _introKey,
                            style: widget.style,
                            active: active < 0,
                            startMs: 0,
                            endMs: lyrics.lines.first.startMs,
                          ),
                        for (var i = 0; i < lyrics.lines.length; i++)
                          _LyricLineTile(
                            key: _lineKeys[i],
                            line: lyrics.lines[i],
                            nextStartMs: i + 1 < lyrics.lines.length
                                ? lyrics.lines[i + 1].startMs
                                : null,
                            style: widget.style,
                            // Before the first line, distances count from the
                            // intro so the opening lines read as "upcoming".
                            distance: i - active,
                            blur: blurOn,
                            lowPower: widget.lowPower,
                            onTap: () => actions.seek(lyrics.lines[i].startMs),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.nextStartMs,
    required this.style,
    required this.distance,
    required this.blur,
    required this.lowPower,
    required this.onTap,
  });

  final LyricLine line;
  final int? nextStartMs;
  final TextStyle style;

  /// Line index minus the active index (0 = playing now).
  final int distance;
  final bool blur;
  final bool lowPower;
  final VoidCallback onTap;

  bool get active => distance == 0;

  @override
  Widget build(BuildContext context) {
    // Empty lines mark instrumental breaks: breathing dots when long enough.
    if (line.isInstrumental) {
      final end = nextStartMs;
      if (end == null || end - line.startMs < _interludeMinMs) {
        return const SizedBox(height: LekisSpacing.lg);
      }
      return _InterludeDots(
        style: style,
        active: active,
        startMs: line.startMs,
        endMs: end,
      );
    }

    final translation = line.translation;
    final fg =
        style.color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFFFFFFFF);
    final translationStyle = style.copyWith(
      fontSize: (style.fontSize ?? 32) * 0.62,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: 0,
    );

    // 透明度直接写进文字颜色，而不是包一层 Opacity：Opacity 介于 0 和 1
    // 之间时每行都要 saveLayer，几十行歌词滚动时就是几十个离屏层。颜色
    // 变化只触发重绘、不触发重新排版。
    Widget content(double opacity) {
      // Only the active line gets a word-by-word wipe; everything else is a
      // plain Text, so resting lines cost nothing extra per playback tick.
      final primary = active && line.hasWordTimings
          ? _KaraokeLine(line: line, style: style, lowPower: lowPower)
          : Text(
              line.text,
              style: style.copyWith(
                color: fg.withValues(alpha: fg.a * opacity),
              ),
            );
      if (translation == null) return primary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          primary,
          const SizedBox(height: LekisSpacing.xs),
          Text(
            translation,
            style: translationStyle.copyWith(
              color: fg.withValues(alpha: fg.a * opacity * 0.85),
            ),
          ),
        ],
      );
    }

    Widget child = TweenAnimationBuilder<double>(
      tween: Tween(end: _lineOpacity(distance)),
      duration: lowPower ? Duration.zero : LekisMotion.slow,
      curve: Curves.easeOutCubic,
      builder: (context, opacity, _) => content(opacity),
    );
    final sigma = blur && distance.abs() <= _blurWindow
        ? _lineBlur(distance)
        : 0.0;
    child = TweenAnimationBuilder<double>(
      tween: Tween(end: sigma),
      duration: LekisMotion.slow,
      curve: Curves.easeOutCubic,
      builder: (context, s, child) => s < 0.05
          ? child!
          : ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: s, sigmaY: s),
              child: child,
            ),
      child: child,
    );
    return Semantics(
      button: true,
      selected: active,
      label: translation == null ? line.text : '${line.text}，$translation',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LekisRadius.md),
        splashColor: fg.withValues(alpha: 0.06),
        highlightColor: fg.withValues(alpha: 0.05),
        hoverColor: fg.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LekisSpacing.sm,
            vertical: LekisSpacing.md,
          ),
          child: AnimatedScale(
            scale: active ? 1 : 0.96,
            alignment: Alignment.centerLeft,
            duration: lowPower
                ? Duration.zero
                : LekisMotion.settleDuration(LekisMotion.springStandard),
            curve: LekisSpringCurve(LekisMotion.springStandard),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 播放时钟。核心大约每 200ms 推一次播放位置；两次推送之间按真实流逝的
/// 时间外推，让逐字填充和歌词舞台按屏幕刷新率平滑地走，而不是 5fps 地跳。
///
/// 只有 [animate] 为 true 且正在播放时才跑 Ticker；其余时候只在位置推送
/// 到来（或调用 [refresh]）时通知一次。监听者通常是一个 `CustomPainter`
/// 的 `repaint`，所以每帧只有那一块画布重绘，不会重建任何 widget。
class LyricsClock extends ChangeNotifier implements ValueListenable<double> {
  LyricsClock(TickerProvider vsync) {
    _ticker = vsync.createTicker((_) => _update());
  }

  late final Ticker _ticker;
  final Stopwatch _watch = Stopwatch()..start();

  double _anchorMs = 0;
  Duration _anchorAt = Duration.zero;
  int? _reportedMs;
  bool _playing = false;
  bool _animate = false;
  double _value = 0;

  /// 当前（外推后的）播放位置，毫秒。
  @override
  double get value => _value;

  bool get playing => _playing;

  /// 是否需要逐帧推进（例如正在填充一个词、弹簧还没停）。
  bool get animate => _animate;
  set animate(bool value) {
    if (_animate == value) return;
    _animate = value;
    _syncTicker();
  }

  double _estimate() {
    if (!_playing) return _anchorMs;
    final elapsed = (_watch.elapsed - _anchorAt).inMicroseconds / 1000;
    // 外推最多走一秒：应用从后台回来时不会在旧锚点上跳得太远。
    return _anchorMs + elapsed.clamp(0.0, 1000.0);
  }

  /// 喂入核心推来的位置和播放状态。
  void sync(int positionMs, bool playing) {
    if (playing != _playing) {
      _anchorMs = _estimate();
      _anchorAt = _watch.elapsed;
      _playing = playing;
    }
    if (positionMs != _reportedMs) {
      final before = _estimate();
      _reportedMs = positionMs;
      _anchorMs = positionMs.toDouble();
      _anchorAt = _watch.elapsed;
      // 外推稍稍跑在核心前面（一次推送间隔以内）时保持单调，不让填充
      // 往回抖；差得多（拖动进度、切歌）就直接跳过去。
      if (_playing && before > _anchorMs && before - _anchorMs < 250) {
        _anchorMs = before;
      }
    }
    _syncTicker();
    _update();
  }

  /// 不等位置推送，按当前时间重新外推一次。
  void refresh() => _update();

  void _syncTicker() {
    final run = _animate && _playing;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _update() {
    final v = _estimate();
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// Active line with enhanced-LRC word timings.
///
/// Listens to the position itself (no rebuilds): a [LyricsClock] drives a
/// painter, so the fill moves at display refresh rate while the rest of the
/// list stays still. Ordinary lines never reach this widget.
class _KaraokeLine extends ConsumerStatefulWidget {
  const _KaraokeLine({
    required this.line,
    required this.style,
    required this.lowPower,
  });

  final LyricLine line;
  final TextStyle style;
  final bool lowPower;

  @override
  ConsumerState<_KaraokeLine> createState() => _KaraokeLineState();
}

class _KaraokeLineState extends ConsumerState<_KaraokeLine>
    with SingleTickerProviderStateMixin {
  late final LyricsClock _clock = LyricsClock(this)..addListener(_onClock);
  _KaraokeArt? _art;
  bool _reduceMotion = false;

  int get _endMs {
    final last = widget.line.words!.last.endMs;
    return last > widget.line.startMs ? last : widget.line.startMs;
  }

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
    _reduceMotion = widget.lowPower || MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _KaraokeLine old) {
    super.didUpdateWidget(old);
    _reduceMotion = widget.lowPower || MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  void _sync() {
    _clock.sync(
      ref.read(positionProvider),
      ref.read(playbackProvider.select((s) => s.isPlaying)),
    );
    _onClock();
  }

  void _onClock() {
    // 低电量：不逐帧推进，填充跟着 200ms 的位置推送一步一步走。
    _clock.animate =
        !_reduceMotion &&
        _clock.value >= widget.line.startMs - 400 &&
        _clock.value <= _endMs + 50;
  }

  @override
  void dispose() {
    _clock.dispose();
    _art?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final fg =
        style.color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFFFFFFFF);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    var art = _art;
    if (art == null ||
        !art.matches(widget.line, style, fg, scaler, direction, locale)) {
      final old = art;
      art = _art = _KaraokeArt(
        line: widget.line,
        style: style,
        sungColor: fg,
        // Unsung words stay readable but recede until the wipe reaches them.
        unsungColor: fg.withValues(alpha: fg.a * 0.5),
        textScaler: scaler,
        textDirection: direction,
        locale: locale,
      );
      // 旧 painter 这一帧可能还在用，下一帧再释放。
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    return Stack(
      children: [
        // Only establishes the wrapped height. The visible glyphs are drawn
        // by the painter below so their fill can move inside a line.
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(widget.line.text, style: style, textScaler: scaler),
          ),
        ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _KaraokePainter(art: art, clock: _clock),
            ),
          ),
        ),
      ],
    );
  }
}

/// 逐字填充用到的两份排版（暗 / 亮）和每个词的字框，按宽度缓存：每帧
/// 只拼一条裁剪路径，不再重新排版。
class _KaraokeArt {
  _KaraokeArt({
    required this.line,
    required this.style,
    required this.sungColor,
    required this.unsungColor,
    required this.textScaler,
    required this.textDirection,
    required this.locale,
  });

  final LyricLine line;
  final TextStyle style;
  final Color sungColor;
  final Color unsungColor;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;

  double? _width;
  TextPainter? _base;
  TextPainter? _bright;
  List<List<Rect>> _boxes = const [];

  bool matches(
    LyricLine line,
    TextStyle style,
    Color fg,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
  ) =>
      identical(line, this.line) &&
      style == this.style &&
      fg == sungColor &&
      scaler == textScaler &&
      direction == textDirection &&
      locale == this.locale;

  TextPainter _layout(Color color, double width) => TextPainter(
    text: TextSpan(
      text: line.text,
      style: style.copyWith(color: color),
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  )..layout(maxWidth: width);

  void _ensure(double width) {
    if (_width == width && _base != null) return;
    _base?.dispose();
    _bright?.dispose();
    _width = width;
    final base = _base = _layout(unsungColor, width);
    _bright = _layout(sungColor, width);
    final boxes = <List<Rect>>[];
    var offset = 0;
    for (final word in line.words!) {
      final start = offset;
      final end = offset + word.text.length;
      offset = end;
      boxes.add(
        start >= end
            ? const []
            : [
                for (final box in base.getBoxesForSelection(
                  TextSelection(baseOffset: start, extentOffset: end),
                ))
                  if (!box.toRect().isEmpty) box.toRect(),
              ],
      );
    }
    _boxes = boxes;
  }

  void paint(Canvas canvas, Size size, double positionMs) {
    _ensure(size.width);
    _base!.paint(canvas, Offset.zero);
    final words = line.words!;
    if (words.isEmpty || positionMs < words.first.startMs) return;
    final sung = Path();
    var any = false;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final span = word.endMs - word.startMs;
      final progress = span <= 0
          ? (positionMs >= word.endMs ? 1.0 : 0.0)
          : ((positionMs - word.startMs) / span).clamp(0.0, 1.0);
      if (progress <= 0) break; // 后面的词更晚，不用再看。
      for (final rect in _boxes[i]) {
        // RTL lyrics fill from the right edge of each word box; LTR from
        // the left. Either way progress moves inside the active line.
        final Rect filled;
        if (progress >= 1) {
          filled = rect;
        } else if (textDirection == TextDirection.rtl) {
          filled = Rect.fromLTRB(
            rect.right - rect.width * progress,
            rect.top,
            rect.right,
            rect.bottom,
          );
        } else {
          filled = Rect.fromLTRB(
            rect.left,
            rect.top,
            rect.left + rect.width * progress,
            rect.bottom,
          );
        }
        if (filled.isEmpty) continue;
        // A hair of vertical slack keeps anti-aliased glyph edges intact.
        sung.addRect(
          Rect.fromLTRB(
            filled.left,
            filled.top - 0.5,
            filled.right,
            filled.bottom + 0.5,
          ),
        );
        any = true;
      }
    }
    if (!any) return;
    canvas.save();
    canvas.clipPath(sung);
    _bright!.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void dispose() {
    _base?.dispose();
    _base = null;
    _bright?.dispose();
    _bright = null;
  }
}

class _KaraokePainter extends CustomPainter {
  _KaraokePainter({required this.art, required this.clock})
    : super(repaint: clock);

  final _KaraokeArt art;
  final LyricsClock clock;

  @override
  void paint(Canvas canvas, Size size) => art.paint(canvas, size, clock.value);

  @override
  bool shouldRepaint(covariant _KaraokePainter old) =>
      old.art != art || old.clock != clock;
}

/// Three breathing dots for the intro and long instrumental breaks. While
/// active they fill one by one as the break runs out, then shrink away.
class _InterludeDots extends ConsumerStatefulWidget {
  const _InterludeDots({
    super.key,
    required this.style,
    required this.active,
    required this.startMs,
    required this.endMs,
  });

  final TextStyle style;
  final bool active;
  final int startMs;
  final int endMs;

  @override
  ConsumerState<_InterludeDots> createState() => _InterludeDotsState();
}

class _InterludeDotsState extends ConsumerState<_InterludeDots>
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
  void didUpdateWidget(covariant _InterludeDots old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final animate = widget.active && !MediaQuery.disableAnimationsOf(context);
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
    final dot = (widget.style.fontSize ?? 32) * 0.36;
    // Only the active interlude follows the clock.
    final progress = widget.active
        ? ref.watch(
            positionProvider.select((p) {
              final span = widget.endMs - widget.startMs;
              if (span <= 0) return 1.0;
              // Quantised so this rebuilds a few dozen times per break.
              final f = ((p - widget.startMs) / span).clamp(0.0, 1.0);
              return (f * 60).floorToDouble() / 60;
            }),
          )
        : 0.0;
    // Last 8% of the break: the dots shrink away as the next line arrives.
    final exit = widget.active && progress > 0.92
        ? (1 - (progress - 0.92) / 0.08).clamp(0.0, 1.0)
        : 1.0;

    Widget dots = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var k = 0; k < 3; k++) ...[
          if (k > 0) SizedBox(width: dot * 0.7),
          TweenAnimationBuilder<double>(
            tween: Tween(
              end: widget.active ? (progress * 3 - k).clamp(0.0, 1.0) : 0.0,
            ),
            duration: LekisMotion.normal,
            builder: (context, fill, _) => Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fg.withValues(alpha: 0.3 + 0.7 * fill),
              ),
            ),
          ),
        ],
      ],
    );
    dots = AnimatedBuilder(
      animation: _breath,
      builder: (context, child) => Transform.scale(
        scale:
            (widget.active
                ? 0.92 + 0.12 * Curves.easeInOut.transform(_breath.value)
                : 0.85) *
            exit,
        alignment: Alignment.centerLeft,
        child: child,
      ),
      child: dots,
    );
    return AnimatedOpacity(
      opacity: widget.active ? 1 : 0.35,
      duration: LekisMotion.slow,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.sm,
          vertical: LekisSpacing.lg,
        ),
        child: Align(alignment: Alignment.centerLeft, child: dots),
      ),
    );
  }
}
