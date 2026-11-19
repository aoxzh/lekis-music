import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Share of the card width a horizontal swipe must cover to skip.
const double _skipFraction = 0.25;

/// Horizontal fling speed (logical px/s) that skips regardless.
const double _skipVelocity = 600;

/// Floating compact player shown above the bottom navigation (phones) or
/// under the content (medium windows).
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

  void _onHorizontalUpdate(DragUpdateDetails d) {
    _swipe.stop();
    _swipe.value += d.delta.dx;
  }

  void _onHorizontalEnd(DragEndDetails d) {
    final width = _cardKey.currentContext?.size?.width ?? 1;
    final v = d.primaryVelocity ?? 0;
    final dx = _swipe.value;
    final commit =
        dx.abs() > width * _skipFraction ||
        (v.abs() > _skipVelocity && v.sign == dx.sign);
    if (!commit) {
      _springTo(0, v);
      return;
    }
    final actions = ref.read(playerActionsProvider);
    dx < 0 ? actions.next() : actions.previous();
    // Slide out the way the finger went, come back in from the other side.
    final out = dx.sign * width * 0.5;
    _springTo(out, v).whenComplete(() {
      if (!mounted) return;
      _swipe.value = -out * 0.6;
      _springTo(0, 0);
    });
  }

  TickerFuture _springTo(double target, double velocity) => _swipe.animateWith(
    SpringSimulation(
      LekisMotion.springStandard,
      _swipe.value,
      target,
      velocity,
      tolerance: const Tolerance(distance: 0.5, velocity: 5),
    ),
  );

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
        LekisSpacing.xs,
        LekisSizes.miniPlayerMargin,
        LekisSizes.miniPlayerMargin + edgeInset,
      ),
      child: Semantics(
        container: true,
        button: true,
        label: '迷你播放器，轻点打开正在播放，左右滑动切歌',
        child: GestureDetector(
          key: _cardKey,
          behavior: HitTestBehavior.opaque,
          onTap: () => openNowPlaying(context),
          onVerticalDragUpdate: _onVerticalUpdate,
          onVerticalDragEnd: _onVerticalEnd,
          onVerticalDragCancel: _onVerticalCancel,
          onHorizontalDragUpdate: _onHorizontalUpdate,
          onHorizontalDragEnd: _onHorizontalEnd,
          child: _SwipeContent(swipe: _swipe),
        ),
      ),
    );
  }
}

class _SwipeContent extends StatelessWidget {
  const _SwipeContent({required this.swipe});

  final Animation<double> swipe;

  @override
  Widget build(BuildContext context) {
    return MiniPlayerFace(
      contentBuilder: (content) => LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: swipe,
          builder: (context, child) {
            final width = math.max(constraints.maxWidth, 1.0);
            final dx = swipe.value;
            return Opacity(
              opacity: (1 - dx.abs() / width).clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(dx, 0), child: child),
            );
          },
          child: content,
        ),
      ),
    );
  }
}

/// What the mini player looks like: artwork-tinted card with title, play /
/// next and a hairline progress bar. Also used as the starting frame of the
/// Now Playing container transform.
class MiniPlayerFace extends ConsumerWidget {
  const MiniPlayerFace({super.key, this.contentBuilder});

  /// Wraps the row (not the card) — used for the swipe offset.
  final Widget Function(Widget content)? contentBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final palette = ref.watch(
      currentArtworkProvider.select((a) => a.value?.palette),
    );
    // Adaptive tint: a hint of the cover's colour over the elevated surface.
    final surface = palette == null
        ? colors.surfaceElevated
        : Color.alphaBlend(
            Color(0xFF000000 | (palette.primary & 0xFFFFFF))
                .withValues(alpha: 0.16),
            colors.surfaceElevated,
          );
    final artSize = LekisSizes.miniPlayerHeight - LekisSpacing.sm * 2;

    final Widget row = Padding(
      padding: const EdgeInsets.only(
        left: LekisSpacing.sm,
        right: LekisSpacing.xs,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: artSize,
            child: const CurrentArtwork(radius: LekisRadius.artworkList),
          ),
          const SizedBox(width: LekisSpacing.md),
          const Expanded(child: CurrentTrackText()),
          const PlayPauseButton(),
          const NextButton(),
        ],
      ),
    );

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: surface),
      duration: LekisMotion.backgroundCrossfade,
      builder: (context, color, child) => Material(
        color: color,
        elevation: 3,
        shadowColor: colors.scrim,
        borderRadius: BorderRadius.circular(LekisRadius.miniPlayer),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
      child: SizedBox(
        height: LekisSizes.miniPlayerHeight,
        child: Column(
          children: [
            Expanded(child: contentBuilder?.call(row) ?? row),
            const ThinProgressBar(),
          ],
        ),
      ),
    );
  }
}
