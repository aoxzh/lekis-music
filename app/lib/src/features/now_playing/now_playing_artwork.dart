import 'package:flutter/physics.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/now_playing/now_playing_layout.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Artwork shrinks a little when paused.
const double _pausedScale = 0.92;

/// Share of the cover width a horizontal swipe must cover to skip.
const double _skipFraction = 0.28;

/// Horizontal fling speed (logical px/s) that skips regardless.
const double _skipVelocity = 800;

/// How far the outgoing / incoming cover travels during a track change,
/// as a share of the cover side.
const double _changeSlide = 0.16;

/// Large Now Playing artwork.
///
/// * corners are a fixed share of the side ([LekisRadius.artworkFraction]),
///   so the cover keeps its shape at every window size;
/// * tap toggles play / pause, swipe left / right skips to the next /
///   previous track, long press opens the queue;
/// * on a track change the old cover slides out and the new one slides in
///   from the side the queue is moving towards (6% rounded corners, no
///   drop shadow, matching the reference `modern` style);
/// * vertical drags are left to the page (drag to close).
class NowPlayingArtwork extends ConsumerStatefulWidget {
  const NowPlayingArtwork({super.key});

  @override
  ConsumerState<NowPlayingArtwork> createState() => _NowPlayingArtworkState();
}

class _NowPlayingArtworkState extends ConsumerState<NowPlayingArtwork>
    with TickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: ref.read(playbackProvider).isPlaying ? 1 : _pausedScale,
  );

  /// Horizontal swipe offset (logical px).
  late final AnimationController _swipe = AnimationController.unbounded(
    vsync: this,
  );

  double _width = 1;

  /// +1: the new cover enters from the right (next track); -1: from the
  /// left (previous track). 0: no known direction, cross-fade only.
  int _direction = 0;

  @override
  void dispose() {
    _scale.dispose();
    _swipe.dispose();
    super.dispose();
  }

  void _springScale(double target, {required bool animate}) {
    if (!animate) {
      _scale.value = target;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        LekisMotion.springEmphasized,
        _scale.value,
        target,
        _scale.velocity,
      ),
    );
  }

  TickerFuture _springSwipe(
    double target,
    double velocity, {
    required bool animate,
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

  void _onSwipeUpdate(DragUpdateDetails d) {
    _swipe.stop();
    _swipe.value += d.delta.dx;
  }

  void _openQueue() {
    if (usesNowPlayingSidePanels(context)) {
      ref.read(nowPlayingPaneProvider.notifier).set(NowPlayingPane.queue);
    } else {
      showQueueSheet(context);
    }
  }

  void _onSwipeEnd(DragEndDetails d, {required bool reducedMotion}) {
    final v = d.primaryVelocity ?? 0;
    final dx = _swipe.value;
    final commit =
        dx.abs() > _width * _skipFraction ||
        (v.abs() > _skipVelocity && v.sign == dx.sign);
    final state = ref.read(playbackProvider);
    final canSkip = dx < 0 ? state.canGoNext : state.canGoPrevious;
    if (!commit || !canSkip) {
      _springSwipe(0, v, animate: !reducedMotion);
      return;
    }
    // 向左滑 = 下一首（新封面从右侧进入），向右滑 = 上一首。
    _direction = dx < 0 ? 1 : -1;
    HapticFeedback.selectionClick();
    final actions = ref.read(playerActionsProvider);
    dx < 0 ? actions.next() : actions.previous();
    // The deck itself performs the outgoing / incoming slide; the card
    // simply settles back rather than flying off-screen.
    _springSwipe(0, v, animate: !reducedMotion);
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    ref.listen<bool>(
      playbackProvider.select((s) => s.isPlaying),
      (_, playing) =>
          _springScale(playing ? 1 : _pausedScale, animate: !reducedMotion),
    );

    // External next / previous (buttons, media keys) still pick a slide
    // direction from the queue cursor.
    ref.listen<int?>(playbackProvider.select((s) => s.queueIndex), (
      previous,
      next,
    ) {
      if (previous == null || next == null || previous == next) return;
      _direction = next > previous ? 1 : -1;
    });

    final track = ref.watch(currentTrackProvider).value;
    final artwork = ref.watch(currentArtworkProvider).value;
    final spec = _CoverSpec(
      trackId: track?.id,
      hash: artwork?.hash,
      seed: track?.id.hashCode ?? 0,
      label: track?.title,
    );
    final actions = ref.read(playerActionsProvider);
    final title = track == null
        ? '封面'
        : '${track.title}${track.artists.isEmpty ? '' : ' — ${track.artists.join(' / ')}'} 的封面';

    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.maxWidth;
            final side = constraints.maxWidth;
            final radius = LekisRadius.artworkFor(side);
            final borderRadius = BorderRadius.circular(radius);
            return Semantics(
              key: const ValueKey('now-playing.artwork'),
              image: true,
              label: title,
              hint: '轻点播放或暂停，左右滑动切歌，长按打开播放队列',
              onTap: actions.playPause,
              customSemanticsActions: {
                const CustomSemanticsAction(label: '上一首'): actions.previous,
                const CustomSemanticsAction(label: '下一首'): actions.next,
                const CustomSemanticsAction(label: '播放队列'): _openQueue,
              },
              child: ExcludeSemantics(
                child: GestureDetector(
                  onTap: actions.playPause,
                  onLongPress: _openQueue,
                  onHorizontalDragUpdate: _onSwipeUpdate,
                  onHorizontalDragEnd: (d) =>
                      _onSwipeEnd(d, reducedMotion: reducedMotion),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_scale, _swipe]),
                    builder: (context, child) {
                      final dx = _swipe.value;
                      final away = (dx / _width).abs().clamp(0.0, 1.0);
                      return Opacity(
                        opacity: (1 - away * 0.55).clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(dx, 0),
                          child: Transform.rotate(
                            // A slight tilt, like a card being flicked.
                            angle: dx / _width * 0.06,
                            child: Transform.scale(
                              scale: _scale.value * (1 - away * 0.06),
                              child: ClipRRect(
                                borderRadius: borderRadius,
                                clipBehavior: Clip.antiAlias,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: _CoverDeck(
                      spec: spec,
                      direction: _direction,
                      reducedMotion: reducedMotion,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

@immutable
class _CoverSpec {
  const _CoverSpec({this.trackId, this.hash, this.seed = 0, this.label});

  final Object? trackId;
  final String? hash;
  final int seed;
  final String? label;
}

/// Two stacked covers: the outgoing one leaves opposite to the incoming
/// one, clipped inside the rounded card. A rapid skip simply replaces the
/// previous outgoing frame.
class _CoverDeck extends StatefulWidget {
  const _CoverDeck({
    required this.spec,
    required this.direction,
    required this.reducedMotion,
  });

  final _CoverSpec spec;
  final int direction;
  final bool reducedMotion;

  @override
  State<_CoverDeck> createState() => _CoverDeckState();
}

class _CoverDeckState extends State<_CoverDeck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _change = AnimationController(
    vsync: this,
    duration: LekisMotion.slow,
    value: 1,
  );

  _CoverSpec? _current;
  _CoverSpec? _outgoing;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _current = widget.spec;
    _change.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _outgoing = null);
      }
    });
  }

  @override
  void dispose() {
    _change.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CoverDeck old) {
    super.didUpdateWidget(old);
    if (widget.spec.trackId == old.spec.trackId) {
      // Same track (e.g. artwork finished loading): update in place.
      _current = widget.spec;
      _outgoing = null;
      return;
    }
    _outgoing = _current;
    _current = widget.spec;
    _direction = old.spec.trackId == null ? 0 : widget.direction;
    if (widget.reducedMotion) {
      _outgoing = null;
      _change.value = 1;
    } else {
      _change.forward(from: 0);
    }
  }

  Widget _art(_CoverSpec spec) => ArtworkImage(
    hash: spec.hash,
    // The outer card clips to the 6% radius; each slide layer stays square
    // so no rounded corner peeks through during the transition.
    radius: 0,
    placeholderSeed: spec.seed,
    placeholderLabel: spec.label,
  );

  @override
  Widget build(BuildContext context) {
    final outgoing = _outgoing;
    final current = _current;
    if (outgoing == null || current == null || _change.isCompleted) {
      return _art(current ?? widget.spec);
    }
    final dir = _direction.toDouble();
    final outgoingArt = _art(outgoing);
    final incomingArt = _art(current);
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _change,
            child: outgoingArt,
            builder: (context, child) {
              final t = Curves.easeInCubic.transform(_change.value);
              return Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                child: FractionalTranslation(
                  translation: Offset(-dir * _changeSlide * t, 0),
                  child: Transform.scale(scale: 1 - 0.03 * t, child: child),
                ),
              );
            },
          ),
          AnimatedBuilder(
            animation: _change,
            child: incomingArt,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_change.value);
              return Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: FractionalTranslation(
                  translation: Offset(dir * _changeSlide * (1 - t), 0),
                  child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
