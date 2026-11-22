// Loading skeletons: calm placeholders that keep the page's geometry while
// data loads, plus the delayed / cross-fading switch to the real content.
//
// * [LekisShimmer] owns ONE animation for its whole subtree; every
//   [LekisSkeleton] below it paints the same highlight band in the scope's
//   coordinates, so the sweep runs across rows instead of per box. The ticker
//   only runs while at least one skeleton box is on screen, and never under
//   reduced motion (boxes are then a flat surfaceVariant).
// * [LekisLoadingSwitcher] shows nothing for [LekisMotion.skeletonDelay]
//   (fast loads never flash a skeleton), then the skeleton, and cross-fades
//   to the content once it arrives. Content → content updates (provider
//   refreshes) never fade.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/shell/nav_icon.dart' show lekisReduceMotion;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

// ---------------------------------------------------------------------------
// Shimmer scope
// ---------------------------------------------------------------------------

/// One shared shimmer for every [LekisSkeleton] in [child].
///
/// Cheap to wrap around large subtrees (a whole grid whose not-yet-loaded
/// cells are skeletons): the animation only ticks while a skeleton box is
/// attached below it.
class LekisShimmer extends StatefulWidget {
  const LekisShimmer({super.key, required this.child});

  final Widget child;

  @override
  State<LekisShimmer> createState() => _LekisShimmerState();
}

class _LekisShimmerState extends State<LekisShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LekisMotion.shimmerPeriod,
  );
  late final _ShimmerHub _hub = _ShimmerHub(_controller, _anchor);

  RenderBox? _anchor() {
    if (!mounted) return null;
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _hub.setAnimate(!lekisReduceMotion(context));
  }

  @override
  void dispose() {
    _hub.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      hub: _hub,
      animate: _hub.animate,
      // The boxes repaint every frame while sweeping; keep that to this layer.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// Shared state between a [LekisShimmer] and its skeleton boxes.
class _ShimmerHub {
  _ShimmerHub(this._controller, this._anchor);

  final AnimationController _controller;
  final RenderBox? Function() _anchor;
  int _clients = 0;
  bool _disposed = false;
  bool animate = true;

  Animation<double> get animation => _controller;

  /// Sweep position 0 → 1 (eased) within the current period.
  double get progress => Curves.easeInOutSine.transform(_controller.value);

  RenderBox? get anchor => _anchor();

  void setAnimate(bool value) {
    animate = value;
    _sync();
  }

  void addClient() {
    _clients++;
    _sync();
  }

  void removeClient() {
    _clients--;
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final run = animate && _clients > 0;
    if (run && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!run && _controller.isAnimating) {
      _controller.stop();
    }
  }

  void dispose() => _disposed = true;
}

class _ShimmerScope extends InheritedWidget {
  const _ShimmerScope({
    required this.hub,
    required this.animate,
    required super.child,
  });

  final _ShimmerHub hub;
  final bool animate;

  static _ShimmerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShimmerScope>();

  @override
  bool updateShouldNotify(_ShimmerScope old) =>
      old.hub != hub || old.animate != animate;
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// Base and highlight colours of skeleton boxes for the current theme.
(Color, Color) skeletonColors(BuildContext context) {
  final base = context.lekisColors.surfaceVariant;
  final dark = Theme.of(context).brightness == Brightness.dark;
  // Light: a soft paper sheen. Dark: barely lifted, so the sweep reads as a
  // glint instead of a flashing bar on the near-black background.
  final highlight = Color.alphaBlend(
    Colors.white.withValues(alpha: dark ? 0.05 : 0.6),
    base,
  );
  return (base, highlight);
}

enum _SkeletonShape { rect, circle }

/// A placeholder block: box, text line or circle.
///
/// Inside a [LekisShimmer] it carries the shared highlight sweep; on its own
/// it is a static surfaceVariant block.
class LekisSkeleton extends StatelessWidget {
  /// A rounded rectangle; fills the incoming constraints where [width] /
  /// [height] are null.
  const LekisSkeleton({
    super.key,
    this.width,
    this.height,
    this.radius = LekisRadius.xs,
  }) : widthFactor = null,
       _shape = _SkeletonShape.rect;

  /// A text line [height] tall, [width] wide or [widthFactor] of the
  /// available width (start-aligned).
  const LekisSkeleton.line({
    super.key,
    this.width,
    this.widthFactor,
    this.height = LekisSpacing.md,
  }) : radius = LekisRadius.xs,
       _shape = _SkeletonShape.rect;

  /// A circle (avatars).
  const LekisSkeleton.circle({super.key, required double size})
    : width = size,
      height = size,
      widthFactor = null,
      radius = 0,
      _shape = _SkeletonShape.circle;

  final double? width;
  final double? height;
  final double? widthFactor;
  final double radius;
  final _SkeletonShape _shape;

  @override
  Widget build(BuildContext context) {
    final (base, highlight) = skeletonColors(context);
    final scope = _ShimmerScope.maybeOf(context);
    Widget box = SizedBox(
      width: width ?? (widthFactor == null ? null : double.infinity),
      height: height,
      child: _SkeletonPaint(
        hub: scope?.hub,
        animate: scope?.animate ?? false,
        base: base,
        highlight: highlight,
        radius: radius,
        shape: _shape,
        rtl: Directionality.maybeOf(context) == TextDirection.rtl,
      ),
    );
    if (widthFactor != null) {
      box = FractionallySizedBox(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: widthFactor,
        child: box,
      );
    }
    return box;
  }
}

class _SkeletonPaint extends LeafRenderObjectWidget {
  const _SkeletonPaint({
    required this.hub,
    required this.animate,
    required this.base,
    required this.highlight,
    required this.radius,
    required this.shape,
    required this.rtl,
  });

  final _ShimmerHub? hub;
  final bool animate;
  final Color base;
  final Color highlight;
  final double radius;
  final _SkeletonShape shape;
  final bool rtl;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSkeleton(
    hub: hub,
    animate: animate,
    base: base,
    highlight: highlight,
    radius: radius,
    shape: shape,
    rtl: rtl,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSkeleton renderObject) {
    renderObject
      ..hub = hub
      ..animate = animate
      ..base = base
      ..highlight = highlight
      ..radius = radius
      ..shape = shape
      ..rtl = rtl;
  }
}

class _RenderSkeleton extends RenderBox {
  _RenderSkeleton({
    required this._hub,
    required this._animate,
    required this._base,
    required this._highlight,
    required this._radius,
    required this._shape,
    required this._rtl,
  });

  _ShimmerHub? _hub;
  set hub(_ShimmerHub? value) {
    if (value == _hub) return;
    if (attached) _unlisten();
    _hub = value;
    if (attached) _listen();
    markNeedsPaint();
  }

  bool _animate;
  set animate(bool value) {
    if (value == _animate) return;
    _animate = value;
    markNeedsPaint();
  }

  Color _base;
  set base(Color value) {
    if (value == _base) return;
    _base = value;
    markNeedsPaint();
  }

  Color _highlight;
  set highlight(Color value) {
    if (value == _highlight) return;
    _highlight = value;
    markNeedsPaint();
  }

  double _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  _SkeletonShape _shape;
  set shape(_SkeletonShape value) {
    if (value == _shape) return;
    _shape = value;
    markNeedsPaint();
  }

  bool _rtl;
  set rtl(bool value) {
    if (value == _rtl) return;
    _rtl = value;
    markNeedsPaint();
  }

  void _listen() {
    _hub?.addClient();
    _hub?.animation.addListener(markNeedsPaint);
  }

  void _unlisten() {
    _hub?.animation.removeListener(markNeedsPaint);
    _hub?.removeClient();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final w = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final h = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.minHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final rect = offset & size;
    final paint = Paint()..color = _base;
    final hub = _hub;
    if (hub != null && _animate) {
      // Place the band in the scope's coordinates so every box shows the
      // same slice of one sweep.
      var originX = 0.0;
      var width = size.width;
      final anchor = hub.anchor;
      if (anchor != null && anchor != this) {
        originX = MatrixUtils.transformPoint(
          getTransformTo(anchor),
          Offset.zero,
        ).dx;
        width = anchor.size.width;
      }
      final band = math.max(width * 0.4, 120.0);
      var t = hub.progress;
      if (_rtl) t = 1 - t;
      final center = -band + t * (width + band * 2);
      final start = offset.dx + center - band / 2 - originX;
      paint.shader = ui.Gradient.linear(
        Offset(start, 0),
        Offset(start + band, 0),
        [_base, _highlight, _base],
        const [0, 0.5, 1],
      );
    }
    final canvas = context.canvas;
    if (_shape == _SkeletonShape.circle) {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(_radius)),
        paint,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Delayed visibility + cross-fade
// ---------------------------------------------------------------------------

enum _LoadPhase { pending, skeleton, content }

/// Switches from [skeleton] to [child] once [loading] turns false.
///
/// * Data within [delay]: the skeleton is never shown and [child] appears
///   directly (no flash, no fade).
/// * Otherwise the skeleton fades in after [delay] and cross-fades to
///   [child] over [LekisMotion.contentFade].
/// * Updates of an already shown [child] (provider refreshes) never fade.
///
/// [skeleton] is wrapped in a [LekisShimmer]; [child] is ignored while
/// [loading].
class LekisLoadingSwitcher extends StatefulWidget {
  const LekisLoadingSwitcher({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.child,
    this.delay = LekisMotion.skeletonDelay,
  });

  final bool loading;
  final Widget skeleton;
  final Widget child;
  final Duration delay;

  @override
  State<LekisLoadingSwitcher> createState() => _LekisLoadingSwitcherState();
}

class _LekisLoadingSwitcherState extends State<LekisLoadingSwitcher> {
  static const _contentKey = ValueKey('lekis-content');
  static const _skeletonKey = ValueKey('lekis-skeleton');
  static const _pendingKey = ValueKey('lekis-pending');

  late _LoadPhase _phase;
  Timer? _timer;
  Duration _fade = LekisMotion.contentFade;

  /// Content shown while a later load waits out [LekisLoadingSwitcher.delay].
  Widget? _lastContent;

  @override
  void initState() {
    super.initState();
    if (widget.loading) {
      _phase = _LoadPhase.pending;
      // The blank placeholder leaves instantly when fast data arrives.
      _fade = Duration.zero;
      _arm();
    } else {
      _phase = _LoadPhase.content;
    }
  }

  @override
  void didUpdateWidget(LekisLoadingSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading) {
      if (_phase == _LoadPhase.content) {
        _phase = _LoadPhase.pending;
        _arm();
      }
    } else if (_phase != _LoadPhase.content) {
      _timer?.cancel();
      _fade = _phase == _LoadPhase.skeleton
          ? LekisMotion.contentFade
          : Duration.zero;
      _phase = _LoadPhase.content;
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(widget.delay, () {
      if (!mounted) return;
      setState(() {
        _phase = _LoadPhase.skeleton;
        _fade = LekisMotion.contentFade;
        _lastContent = null;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget current;
    switch (_phase) {
      case _LoadPhase.content:
        _lastContent = widget.child;
        current = KeyedSubtree(key: _contentKey, child: widget.child);
      case _LoadPhase.pending:
        final last = _lastContent;
        current = last == null
            ? const SizedBox.shrink(key: _pendingKey)
            : KeyedSubtree(key: _contentKey, child: last);
      case _LoadPhase.skeleton:
        current = KeyedSubtree(
          key: _skeletonKey,
          child: Semantics(
            label: context.l10n.pick('正在加载', 'Loading'),
            child: ExcludeSemantics(
              child: IgnorePointer(child: LekisShimmer(child: widget.skeleton)),
            ),
          ),
        );
    }
    return AnimatedSwitcher(
      duration: _fade,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: _layout,
      child: current,
    );
  }

  // Keep the parent's constraints (a page body stays full size) and anchor
  // top-start like the content itself, instead of centring.
  static Widget _layout(Widget? current, List<Widget> previous) => Stack(
    fit: StackFit.passthrough,
    alignment: AlignmentDirectional.topStart,
    children: [...previous, ?current],
  );
}

/// A skeleton that only appears if loading takes longer than
/// [LekisMotion.skeletonDelay], fading in. For loading branches that cannot
/// wrap their content in a [LekisLoadingSwitcher] (e.g. one sliver of a
/// larger list).
class LekisDelayedSkeleton extends StatelessWidget {
  const LekisDelayedSkeleton({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LekisLoadingSwitcher(
    loading: true,
    skeleton: child,
    child: const SizedBox.shrink(),
  );
}

/// [AsyncValue.when] with a skeleton loading state.
extension LekisAsyncSkeleton<T> on AsyncValue<T> {
  /// Like [when] (same skip rules: a refresh keeps showing data), but the
  /// loading state is [skeleton] behind a [LekisLoadingSwitcher].
  ///
  /// [waitFor]: other data the page needs for its first layout is still
  /// pending; keep the skeleton up instead of popping in sections later.
  Widget whenSkeleton({
    required Widget skeleton,
    required Widget Function(T data) data,
    required Widget Function(Object error, StackTrace stackTrace) error,
    bool waitFor = false,
  }) {
    final content = when<Widget?>(
      data: (value) => waitFor ? null : data(value),
      error: error,
      loading: () => null,
    );
    return LekisLoadingSwitcher(
      loading: content == null,
      skeleton: skeleton,
      child: content ?? const SizedBox.shrink(),
    );
  }
}

// ---------------------------------------------------------------------------
// Composites matching real widgets
// ---------------------------------------------------------------------------

/// Pseudo-random but stable line widths, so a list of skeleton rows reads
/// like text rather than a barcode.
double _lineFactor(int index, {double min = 0.35, double max = 0.7}) {
  const steps = [0.62, 0.41, 0.78, 0.53, 0.69, 0.47, 0.84, 0.58];
  return min + (max - min) * steps[index % steps.length];
}

/// Height of one line box of [style] at the current text scale.
double _lineBox(BuildContext context, TextStyle? style) {
  final size = style?.fontSize ?? 14;
  return MediaQuery.textScalerOf(context).scale(size) * (style?.height ?? 1.3);
}

/// A text-line skeleton vertically centred in the line box of [style].
class _TextLine extends StatelessWidget {
  const _TextLine({required this.style, required this.widthFactor});

  final TextStyle? style;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    final box = _lineBox(context, style);
    final glyph = MediaQuery.textScalerOf(context)
        .scale((style?.fontSize ?? 14) * 0.72);
    return SizedBox(
      height: box,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: LekisSkeleton.line(
          widthFactor: widthFactor,
          height: math.min(glyph, box),
        ),
      ),
    );
  }
}

/// Skeleton of a [TrackTile]: same fixed height, padding and artwork slot.
class SkeletonTrackTile extends StatelessWidget {
  const SkeletonTrackTile({
    super.key,
    this.index = 0,
    this.showArtwork = true,
    this.numbered = false,
  });

  /// Row index; varies the line widths.
  final int index;
  final bool showArtwork;

  /// Album / playlist rows: a track number instead of artwork.
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget leading;
    if (numbered) {
      leading = const SizedBox(
        width: LekisSizes.listArtwork,
        child: Center(child: LekisSkeleton.line(width: LekisSpacing.lg)),
      );
    } else if (showArtwork) {
      leading = const LekisSkeleton(
        width: LekisSizes.listArtwork,
        height: LekisSizes.listArtwork,
        radius: LekisRadius.artworkList,
      );
    } else {
      leading = const SizedBox.shrink();
    }
    return SizedBox(
      height: TrackTile.extent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        child: Row(
          children: [
            leading,
            const SizedBox(width: LekisSpacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TextLine(
                    style: theme.textTheme.bodyLarge,
                    widthFactor: _lineFactor(index, min: 0.4, max: 0.75),
                  ),
                  _TextLine(
                    style: theme.textTheme.bodySmall,
                    widthFactor: _lineFactor(index + 3, min: 0.25, max: 0.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: LekisSpacing.md),
            const LekisSkeleton.line(width: LekisSpacing.xxl, height: 10),
          ],
        ),
      ),
    );
  }
}

/// [count] [SkeletonTrackTile]s in a column (for a box inside a sliver
/// list, e.g. below a detail header).
class SkeletonTrackList extends StatelessWidget {
  const SkeletonTrackList({
    super.key,
    this.count = 8,
    this.numbered = false,
    this.padding = EdgeInsets.zero,
  });

  final int count;
  final bool numbered;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          SkeletonTrackTile(index: i, numbered: numbered),
      ],
    ),
  );
}

/// A page-filling, non-scrolling list of [SkeletonTrackTile]s with the
/// standard track list insets (gutter − sm).
class SkeletonTrackListView extends StatelessWidget {
  const SkeletonTrackListView({
    super.key,
    this.top = 0,
    this.header,
    this.numbered = false,
  });

  final double top;
  final Widget? header;

  /// Album / playlist rows (see [SkeletonTrackTile.numbered]).
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        if (header != null) SliverToBoxAdapter(child: header),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter - LekisSpacing.sm,
            top,
            gutter - LekisSpacing.sm,
            0,
          ),
          sliver: SliverFixedExtentList.builder(
            itemExtent: TrackTile.extent,
            itemCount: 40,
            itemBuilder: (context, i) =>
                SkeletonTrackTile(index: i, numbered: numbered),
          ),
        ),
      ],
    );
  }
}

/// Skeleton of an album / artwork card ([ArtworkCardFrame] + square cover):
/// square cover, then title and subtitle lines in their real line boxes.
class SkeletonAlbumCard extends StatelessWidget {
  const SkeletonAlbumCard({super.key, this.index = 0});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const AspectRatio(
          aspectRatio: 1,
          child: LekisSkeleton(radius: LekisRadius.artworkGrid),
        ),
        const SizedBox(height: LekisSpacing.sm),
        _TextLine(
          style: theme.textTheme.titleSmall,
          widthFactor: _lineFactor(index, min: 0.55, max: 0.9),
        ),
        _TextLine(
          style: theme.textTheme.bodySmall,
          widthFactor: _lineFactor(index + 5, min: 0.35, max: 0.65),
        ),
      ],
    );
  }
}

/// Skeleton of an [ArtworkShelf]: same title row, card width and height.
class SkeletonShelf extends StatelessWidget {
  const SkeletonShelf({super.key, this.titleWidth = 96});

  final double titleWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final safe = MediaQuery.paddingOf(context);
    final startPad = gutter + safe.left;
    final endPad = gutter + safe.right;
    final theme = Theme.of(context);
    final textBlock =
        LekisSpacing.sm +
        _lineBox(context, theme.textTheme.titleSmall) +
        _lineBox(context, theme.textTheme.bodySmall) +
        LekisSpacing.xxs;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - startPad - endPad;
        final width = shelfCardWidth(available);
        final count = available.isFinite
            ? (available / (width + LekisSpacing.lg)).ceil() + 1
            : 3;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                startPad,
                LekisSpacing.xl,
                endPad,
                LekisSpacing.sm,
              ),
              child: SizedBox(
                height: LekisSizes.touchTargetMin,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: LekisSkeleton.line(
                    width: titleWidth,
                    height: LekisSpacing.lg + LekisSpacing.xxs,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: width + textBlock,
              child: ClipRect(
                child: OverflowBox(
                  alignment: AlignmentDirectional.topStart,
                  maxWidth: double.infinity,
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(start: startPad),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < count; i++) ...[
                          if (i > 0) const SizedBox(width: LekisSpacing.lg),
                          SizedBox(
                            width: width,
                            child: SkeletonAlbumCard(index: i),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A generic two-line list row: square / circle leading, title and
/// subtitle lines (playlists, podcasts, artists, stats).
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({
    super.key,
    this.index = 0,
    this.height = 72,
    this.leadingSize = LekisSizes.listArtwork,
    this.circle = false,
    this.subtitle = true,
    this.padding = const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
  });

  final int index;
  final double height;
  final double leadingSize;
  final bool circle;
  final bool subtitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            if (circle)
              LekisSkeleton.circle(size: leadingSize)
            else
              LekisSkeleton(
                width: leadingSize,
                height: leadingSize,
                radius: LekisRadius.artworkList,
              ),
            const SizedBox(width: LekisSpacing.lg),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TextLine(
                    style: theme.textTheme.bodyLarge,
                    widthFactor: _lineFactor(index, min: 0.35, max: 0.7),
                  ),
                  if (subtitle)
                    _TextLine(
                      style: theme.textTheme.bodyMedium,
                      widthFactor: _lineFactor(index + 3, min: 0.25, max: 0.5),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A page-filling, non-scrolling column of [SkeletonListTile]s.
class SkeletonListView extends StatelessWidget {
  const SkeletonListView({
    super.key,
    this.padding = EdgeInsets.zero,
    this.itemHeight = 72,
    this.circle = false,
    this.subtitle = true,
  });

  final EdgeInsetsGeometry padding;
  final double itemHeight;
  final bool circle;
  final bool subtitle;

  @override
  Widget build(BuildContext context) => ListView.builder(
    physics: const NeverScrollableScrollPhysics(),
    padding: padding,
    itemExtent: itemHeight,
    itemCount: 30,
    itemBuilder: (context, i) => SkeletonListTile(
      index: i,
      height: itemHeight,
      circle: circle,
      subtitle: subtitle,
    ),
  );
}
