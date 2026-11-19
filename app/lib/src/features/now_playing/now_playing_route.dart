// Full-screen Now Playing route.
//
// The page grows out of the floating mini player (a container transform:
// bounds, corner radius and content cross-fade together) and shrinks back
// into it. The transition is driven by springs, and either end can be taken
// over by a finger: dragging the mini player up pulls the page open, and
// dragging the page down pushes it back into the mini player.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:lekis/src/features/now_playing/now_playing_page.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Opens Now Playing full screen over the whole shell (root navigator).
/// Does nothing if it is already open, so the mini player, the player bar
/// and feature code can all call it safely.
Future<void> openNowPlaying(BuildContext context) async {
  if (NowPlayingRoute.current != null) return;
  await Navigator.of(context, rootNavigator: true).push(NowPlayingRoute());
}

/// Where Now Playing grows from and shrinks back into: the mounted mini
/// player registers itself here. Without one the page rises from the bottom
/// edge instead.
abstract final class NowPlayingOrigin {
  static final List<(GlobalKey, WidgetBuilder)> _entries = [];

  /// Registers [key]'s box as the origin and [face] as a replica of what it
  /// shows (faded out as the page grows).
  static void register(GlobalKey key, WidgetBuilder face) =>
      _entries.add((key, face));

  static void unregister(GlobalKey key) =>
      _entries.removeWhere((e) => identical(e.$1, key));

  /// Window-space bounds and face of the most recently mounted visible
  /// origin.
  static (Rect, WidgetBuilder)? resolve() {
    for (final (key, face) in _entries.reversed) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.isEmpty) continue;
      return (box.localToGlobal(Offset.zero) & box.size, face);
    }
    return null;
  }
}

class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute()
    : super(settings: const RouteSettings(name: '/now-playing'));

  /// The route currently shown (not popping), if any.
  static NowPlayingRoute? get current => _current;
  static NowPlayingRoute? _current;

  /// Nearest [NowPlayingRoute] above [context], if any.
  static NowPlayingRoute? of(BuildContext context) {
    final route = ModalRoute.of(context);
    return route is NowPlayingRoute ? route : null;
  }

  final GlobalKey _pageKey = GlobalKey(debugLabel: 'NowPlayingRoute.page');

  /// Release velocity (route progress per second) for the next simulation.
  double _velocity = 0;
  bool _dragging = false;

  /// Finger travel (logical px) between closed and open, measured when a
  /// drag starts.
  double _travel = 1;

  @override
  Duration get transitionDuration =>
      LekisMotion.settleDuration(LekisMotion.springEmphasized);

  @override
  Duration get reverseTransitionDuration =>
      LekisMotion.settleDuration(LekisMotion.springStandard);

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Simulation? createSimulation({required bool forward}) {
    final from = controller?.value ?? (forward ? 0.0 : 1.0);
    final v = _velocity;
    _velocity = 0;
    return SpringSimulation(
      forward ? LekisMotion.springEmphasized : LekisMotion.springStandard,
      from,
      forward ? 1 : 0,
      v,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
    );
  }

  @override
  void install() {
    _current = this;
    super.install();
  }

  @override
  bool didPop(void result) {
    if (identical(_current, this)) _current = null;
    _endUserGesture();
    return super.didPop(result);
  }

  @override
  void dispose() {
    if (identical(_current, this)) _current = null;
    super.dispose();
  }

  // ---- Interactive control (mini player drag-up, page drag-down) ----

  /// Distance the page top travels between closed and open.
  double _travelFor(Size window) {
    final top = NowPlayingOrigin.resolve()?.$1.top ?? window.height;
    return math.max(top, window.height * 0.4);
  }

  /// Takes the transition over from its spring (or from rest).
  void beginDrag(Size window) {
    final c = controller;
    if (c == null || !isActive) return;
    c.stop();
    _travel = _travelFor(window);
    if (!_dragging) {
      _dragging = true;
      navigator?.didStartUserGesture();
    }
  }

  /// Moves the page by [dy] logical pixels (positive = down, towards closed).
  void dragBy(double dy) {
    final c = controller;
    if (c == null || !_dragging) return;
    c.value = (c.value - dy / _travel).clamp(0.0, 1.0);
  }

  /// Lets go: springs open or closed depending on position and fling speed
  /// ([velocityY] in logical px/s, positive = down).
  void endDrag(double velocityY) {
    final c = controller;
    if (c == null || !_dragging) return;
    final v = -velocityY / _travel;
    final open = velocityY.abs() > LekisNowPlaying.dragCommitVelocity
        ? velocityY < 0
        : c.value > 1 - LekisNowPlaying.dragCommitFraction ||
              (c.value > LekisNowPlaying.dragCommitFraction && velocityY < 0);
    _velocity = v;
    if (open) {
      _endUserGesture();
      c.animateWith(createSimulation(forward: true)!);
    } else {
      // didPop ends the gesture and runs the closing spring from here.
      navigator?.pop();
    }
  }

  void _endUserGesture() {
    if (!_dragging) return;
    _dragging = false;
    navigator?.didStopUserGesture();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const NowPlayingPage();

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _ContainerTransform(
      animation: animation,
      child: KeyedSubtree(key: _pageKey, child: child),
    );
  }
}

/// Lerps the page between the origin's bounds and the full window.
class _ContainerTransform extends AnimatedWidget {
  const _ContainerTransform({
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final Widget child;

  Animation<double> get _t => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final colors = context.lekisColors;
    final t = _t.value.clamp(0.0, 1.0);
    final settled = t >= 1;

    final resolved = NowPlayingOrigin.resolve();
    final face = resolved?.$2;
    final origin =
        resolved?.$1 ??
        Rect.fromLTWH(
          LekisSizes.miniPlayerMargin,
          size.height,
          size.width - LekisSizes.miniPlayerMargin * 2,
          LekisSizes.miniPlayerHeight,
        );
    final bounds = Rect.lerp(origin, Offset.zero & size, t)!;
    final radius = lerpDouble(LekisRadius.miniPlayer, 0, t)!;
    // The page fades in over the first part; the origin face fades out
    // faster, so the two never read as stacked.
    final pageOpacity = const Interval(0.05, 0.5).transform(t);
    final faceOpacity = 1 - const Interval(0, 0.3).transform(t);

    return Stack(
      children: [
        // Dims what is underneath as the page takes over.
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: colors.scrim.withValues(alpha: colors.scrim.a * t),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: bounds,
          child: ClipRRect(
            clipBehavior: settled ? Clip.none : Clip.antiAlias,
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Kept in the tree when settled so the page never moves.
                ColoredBox(
                  color: settled
                      ? const Color(0x00000000)
                      : colors.surfaceElevated,
                ),
                OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: size.width,
                  maxWidth: size.width,
                  minHeight: size.height,
                  maxHeight: size.height,
                  child: Opacity(opacity: pageOpacity, child: child),
                ),
                if (face != null && faceOpacity > 0)
                  Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: origin.width,
                      height: origin.height,
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: faceOpacity,
                          child: face(context),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
