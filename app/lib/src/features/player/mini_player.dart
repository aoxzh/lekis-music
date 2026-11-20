import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:material_ui/material_ui.dart';

/// Share of the card width a horizontal swipe must cover to skip.
const double _skipFraction = 0.25;

/// Horizontal fling speed (logical px/s) that skips regardless.
const double _skipVelocity = 600;

/// Floating compact player shown above the bottom navigation (phones) or
/// under the content (medium windows).
///
/// It is a slimmer twin of the floating tab bar: the same capsule material
/// ([LekisGlassCapsule], liquid or flat per [tabBarStyleProvider]), fully
/// rounded ends, 8 dp margins and a hairline adaptive progress line.
///
/// * tap → opens Now Playing, growing out of this card;
/// * drag up → pulls Now Playing open under the finger;
/// * swipe left / right → next / previous track.
///
/// When [atBottomEdge] is set the card sits on the window's bottom edge and
/// keeps clear of the system gesture / home-indicator area itself; when
/// nothing is playing it still reserves that inset so content above never
/// runs into the gesture area.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, this.atBottomEdge = false});

  final bool atBottomEdge;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer>
    with SingleTickerProviderStateMixin {
  final _cardKey = GlobalKey(debugLabel: 'MiniPlayer.card');

  /// Horizontal swipe offset of the card content (logical px).
  late final AnimationController _swipe = AnimationController.unbounded(
    vsync: this,
  );

  NowPlayingRoute? _expanding;

  @override
  void initState() {
    super.initState();
    NowPlayingOrigin.register(_cardKey, (_) => const MiniPlayerFace());
  }

  @override
  void dispose() {
    NowPlayingOrigin.unregister(_cardKey);
    _swipe.dispose();
    super.dispose();
  }

  // ---- Drag up to expand ----

  void _onVerticalUpdate(DragUpdateDetails d) {
    var route = _expanding;
    if (route == null) {
      // Only an upward drag starts the expansion.
      if (d.delta.dy >= 0 || NowPlayingRoute.current != null) return;
      route = NowPlayingRoute();
      Navigator.of(context, rootNavigator: true).push(route);
      route.beginDrag(MediaQuery.sizeOf(context));
      _expanding = route;
    }
    route.dragBy(d.delta.dy);
  }

  void _onVerticalEnd(DragEndDetails d) {
    final route = _expanding;
    _expanding = null;
    if (route != null) {
      route.endDrag(d.primaryVelocity ?? 0);
    } else if ((d.primaryVelocity ?? 0) < -LekisNowPlaying.dragCommitVelocity) {
      openNowPlaying(context);
    }
  }

  void _onVerticalCancel() {
    _expanding?.endDrag(0);
    _expanding = null;
  }

  // ---- Swipe to skip ----

  void _onHorizontalStart(DragStartDetails d) => _swipe.stop();

  void _onHorizontalUpdate(DragUpdateDetails d) {
    _swipe.stop();
    _swipe.value += d.delta.dx;
  }

  void _onHorizontalEnd(DragEndDetails d) {
    final width = _cardKey.currentContext?.size?.width ?? 1;
    final v = d.primaryVelocity ?? 0;
    final dx = _swipe.value;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final commit =
        dx.abs() > width * _skipFraction ||
        (v.abs() > _skipVelocity && v.sign == dx.sign);
    final state = ref.read(playbackProvider);
    final canSkip = dx < 0 ? state.canGoNext : state.canGoPrevious;
    if (!commit || !canSkip) {
      _springTo(0, v, animate: !reducedMotion);
      return;
    }
    HapticFeedback.selectionClick();
    final actions = ref.read(playerActionsProvider);
    dx < 0 ? actions.next() : actions.previous();
    if (reducedMotion) {
      _swipe.value = 0;
      return;
    }
    // Slide out the way the finger went, come back in from the other side
    // with the new track's cover already cross-fading in.
    final out = dx.sign * width * 0.5;
    _springTo(out, v).whenComplete(() {
      if (!mounted) return;
      _swipe.value = -out * 0.6;
      _springTo(0, 0);
    });
  }

  TickerFuture _springTo(
    double target,
    double velocity, {
    bool animate = true,
  }) {
    if (!animate) {
      _swipe.value = target;
      return TickerFuture.complete();
    }
    return _swipe.animateWith(
      SpringSimulation(
        LekisMotion.springStandard,
        _swipe.value,
        target,
        velocity,
        tolerance: const Tolerance(distance: 0.5, velocity: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final mq = MediaQuery.of(context);
    // Keep clear of the home indicator / gesture handle even where the
    // system reports no padding for it (hidden gesture hint).
    final edgeInset = widget.atBottomEdge
        ? math.max(mq.padding.bottom, mq.systemGestureInsets.bottom)
        : 0.0;
    if (!hasTrack) return SizedBox(height: edgeInset);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        LekisSizes.miniPlayerMargin,
        0,
        LekisSizes.miniPlayerMargin,
        LekisSizes.miniPlayerMargin + edgeInset,
      ),
      child: Semantics(
        key: const ValueKey('mini-player.semantics'),
        container: true,
        button: true,
        label: '迷你播放器，轻点打开正在播放，左右滑动切歌',
        onTap: () => openNowPlaying(context),
        customSemanticsActions: {
          const CustomSemanticsAction(label: '上一首'): () =>
              ref.read(playerActionsProvider).previous(),
          const CustomSemanticsAction(label: '下一首'): () =>
              ref.read(playerActionsProvider).next(),
        },
        child: GestureDetector(
          key: _cardKey,
          behavior: HitTestBehavior.opaque,
          onTap: () => openNowPlaying(context),
          onVerticalDragUpdate: _onVerticalUpdate,
          onVerticalDragEnd: _onVerticalEnd,
          onVerticalDragCancel: _onVerticalCancel,
          onHorizontalDragStart: _onHorizontalStart,
          onHorizontalDragUpdate: _onHorizontalUpdate,
          onHorizontalDragEnd: _onHorizontalEnd,
          child: _SwipeContent(swipe: _swipe),
        ),
      ),
    );
  }
}

class _SwipeContent extends ConsumerWidget {
  const _SwipeContent({required this.swipe});

  final Animation<double> swipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tint = NowPlayingTint.resolve(
      ref.watch(nowPlayingPaletteProvider(Theme.of(context).brightness)),
      Theme.of(context).colorScheme,
    );
    final hintColor = readableAccent(
      tint.primary,
      context.lekisColors.surfaceElevated,
    );
    return MiniPlayerFace(
      contentBuilder: (content) => LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: swipe,
          child: content,
          builder: (context, child) {
            final width = math.max(constraints.maxWidth, 1.0);
            final dx = swipe.value;
            final reveal = (dx.abs() / width * 3).clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                // The skip direction peeks out from under the sliding row.
                Align(
                  alignment: dx < 0
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.lg,
                    ),
                    child: Opacity(
                      opacity: reveal * 0.9,
                      child: Icon(
                        dx < 0
                            ? Icons.skip_next_rounded
                            : Icons.skip_previous_rounded,
                        size: LekisSpacing.xl,
                        color: hintColor,
                      ),
                    ),
                  ),
                ),
                Opacity(
                  opacity: (1 - dx.abs() / width).clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What the mini player looks like: the tab bar's own capsule (liquid glass
/// or flat, following the tab bar style setting) holding artwork, title,
/// play / next and a hairline progress line. Also used as the starting frame
/// of the Now Playing container transform.
class MiniPlayerFace extends ConsumerWidget {
  const MiniPlayerFace({super.key, this.contentBuilder});

  /// Wraps the row (not the card) — used for the swipe offset.
  final Widget Function(Widget content)? contentBuilder;

  /// The capsule surface. Exposed for widget tests.
  static const Key cardKey = ValueKey('mini-player.card');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final flat = ref.watch(tabBarStyleProvider) == TabBarStyle.flat;
    final tint = NowPlayingTint.resolve(
      ref.watch(nowPlayingPaletteProvider(Theme.of(context).brightness)),
      Theme.of(context).colorScheme,
    );
    // Only the hairline progress picks up the cover colour; the surface is
    // the same neutral glass as the tab bar.
    final progressColor = readableAccent(tint.primary, colors.surfaceElevated);
    const artSize = LekisSizes.miniPlayerHeight - LekisSpacing.sm * 2;

    final Widget row = Padding(
      // Capsule ends: keep the artwork and the last button inside the curve.
      padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: artSize,
            // Concentric with the capsule: an inner circle-ish cover.
            child: CurrentArtwork(
              radius: LekisRadius.miniPlayer - LekisSpacing.sm,
            ),
          ),
          const SizedBox(width: LekisSpacing.md),
          const Expanded(child: CurrentTrackText()),
          const PlayPauseButton(),
          const NextButton(),
        ],
      ),
    );

    return LekisGlassCapsule(
      key: cardKey,
      radius: LekisRadius.miniPlayer,
      flat: flat,
      enableLens: !MediaQuery.disableAnimationsOf(context),
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          height: LekisSizes.miniPlayerHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              contentBuilder?.call(row) ?? row,
              // Along the straight bottom edge only, clear of the round ends.
              Positioned(
                left: LekisRadius.miniPlayer,
                right: LekisRadius.miniPlayer,
                bottom: 0,
                child: _MiniProgressBar(color: progressColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// progressStyle 2: a hairline, adaptive-colour progress line at the card's
/// bottom edge. Non-interactive; seeking lives in the full player.
class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(progressProvider);
    final colors = context.lekisColors;
    return Semantics(
      label: '播放进度',
      value: '${(progress * 100).round()}%',
      child: SizedBox(
        height: LekisSpacing.xxs,
        child: LinearProgressIndicator(
          value: progress,
          minHeight: LekisSpacing.xxs,
          color: color,
          backgroundColor: colors.outline.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(LekisRadius.pill),
        ),
      ),
    );
  }
}
