import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Where the active line sits, as a fraction of the viewport height.
const double _activeLineAnchor = 0.3;

/// Inactive lines further than this from the active one skip the blur layer
/// (they are off screen or nearly so; saves a saveLayer each).
const int _blurWindow = 6;

/// After the user scrolls by hand, auto-follow resumes after this pause.
const Duration _resumeFollowAfter = Duration(seconds: 3);

/// Lyrics for [trackId]: synced (active line follows playback, tap to seek)
/// or plain text, or an empty-state message.
class LyricsView extends ConsumerWidget {
  const LyricsView({
    super.key,
    required this.trackId,
    this.compact = false,
    this.lowPower = false,
  });

  final int trackId;

  /// Smaller type for narrow windows.
  final bool compact;

  /// Skip the per-line blur (reduce-motion / low-power).
  final bool lowPower;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider(trackId));
    final theme = Theme.of(context);
    final Widget body = lyrics.when(
      // An online lookup can take a few seconds; local ones are instant, so
      // the searching state only appears after a short pause.
      loading: () => const _Searching(key: ValueKey('loading')),
      error: (e, _) => _Message(
        key: const ValueKey('error'),
        icon: Icons.lyrics_outlined,
        title: '暂无歌词',
        detail: '查找歌词时出了点问题',
        onRetry: () => ref.invalidate(lyricsProvider(trackId)),
      ),
      data: (parsed) {
        if (parsed == null) {
          return const _Message(
            key: ValueKey('empty'),
            icon: Icons.lyrics_outlined,
            title: '暂无歌词',
            detail: '本地文件和在线都没有找到这首歌的歌词',
          );
        }
        final base = LekisText.lyricsActive.copyWith(
          color: theme.colorScheme.onSurface,
        );
        final style = compact
            ? base.copyWith(fontSize: (base.fontSize ?? 30) * 0.8)
            : base;
        if (!parsed.synced) {
          return _PlainLyrics(
            key: const ValueKey('plain'),
            lyrics: parsed,
            style: style.copyWith(fontWeight: FontWeight.w600),
          );
        }
        return _SyncedLyrics(
          key: ValueKey(trackId),
          lyrics: parsed,
          style: style,
          lowPower: lowPower,
        );
      },
    );
    // Searching → lyrics / empty cross-fades instead of popping in.
    return AnimatedSwitcher(
      duration: LekisMotion.normal,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: body,
    );
  }
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

/// Shown while the core looks for lyrics (sidecar, tags, then online).
class _Searching extends StatefulWidget {
  const _Searching({super.key});

  @override
  State<_Searching> createState() => _SearchingState();
}

class _SearchingState extends State<_Searching> {
  /// Below this, a spinner would only flicker.
  static const _delay = Duration(milliseconds: 350);

  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: LekisMotion.normal,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: LekisSpacing.xl,
              child: CircularProgressIndicator(
                strokeWidth: LekisSpacing.xxs,
                color: fg.withValues(
                  alpha: LekisType.lyricsInactiveOpacity * 2,
                ),
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            Text(
              '正在查找歌词…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg.withValues(
                  alpha: LekisType.lyricsInactiveOpacity * 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final muted = fg.withValues(alpha: LekisType.lyricsInactiveOpacity * 2);
    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(LekisSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: LekisSpacing.xxxl,
              color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
            ),
            const SizedBox(height: LekisSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(color: muted),
            ),
            if (detail != null) ...[
              const SizedBox(height: LekisSpacing.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fg.withValues(alpha: LekisType.lyricsInactiveOpacity),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: LekisSpacing.md),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: fg),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Unsynced lyrics: static, selectable, a little smaller than synced ones.
class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({super.key, required this.lyrics, required this.style});
  final ParsedLyrics lyrics;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _edgeFade(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.xl,
          vertical: LekisSpacing.xxxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '歌词未与播放同步',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: LekisType.lyricsInactiveOpacity,
                ),
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            SelectableText(
              lyrics.lines.map((l) => l.text).join('\n'),
              style: style.copyWith(
                fontSize: (style.fontSize ?? 30) * 0.75,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// A gap at least this long before the first line (or on an empty
/// "instrumental" line) shows the breathing-dots interlude.
const int _interludeMinMs = 3000;

/// Widest a lyric line gets; longer text wraps so wide panes stay readable.
const double _maxLineWidth = 680;

/// Opacity for a line [distance] lines away from the active one
/// (negative = already sung).
double _lineOpacity(int distance) => switch (distance) {
  0 => 1,
  1 => 0.55,
  -1 => 0.4,
  _ => LekisType.lyricsInactiveOpacity * 0.85,
};

/// Blur for a line [distance] lines away: neighbours stay sharp, the rest
/// soften gradually so the eye lands on the active line.
double _lineBlur(int distance) {
  final d = distance.abs();
  if (d <= 1) return 0;
  return ((d - 1) * 0.8).clamp(0.0, LekisType.lyricsInactiveBlur * 2);
}

class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({
    super.key,
    required this.lyrics,
    required this.style,
    required this.lowPower,
  });

  final ParsedLyrics lyrics;
  final TextStyle style;
  final bool lowPower;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics>
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

  @override
  void didUpdateWidget(covariant _SyncedLyrics old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) _lineKeys = _keysFor(widget.lyrics);
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
                left: LekisSpacing.lg,
                right: LekisSpacing.lg,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxLineWidth),
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
                          onTap: () => actions.seek(lyrics.lines[i].startMs),
                        ),
                    ],
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
    required this.onTap,
  });

  final LyricLine line;
  final int? nextStartMs;
  final TextStyle style;

  /// Line index minus the active index (0 = playing now).
  final int distance;
  final bool blur;
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
    Widget child = translation == null
        ? Text(line.text, style: style)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(line.text, style: style),
              const SizedBox(height: LekisSpacing.xs),
              Text(
                translation,
                style: style.copyWith(
                  fontSize: (style.fontSize ?? 32) * 0.62,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  letterSpacing: 0,
                ),
              ),
            ],
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
    final fg = Theme.of(context).colorScheme.onSurface;
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
            duration: LekisMotion.settleDuration(LekisMotion.springStandard),
            curve: LekisSpringCurve(LekisMotion.springStandard),
            child: AnimatedOpacity(
              opacity: _lineOpacity(distance),
              duration: LekisMotion.slow,
              curve: Curves.easeOutCubic,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
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
