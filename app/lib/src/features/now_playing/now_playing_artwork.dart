import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Artwork shrinks a little when paused.
const double _pausedScale = 0.84;

/// Share of the cover width a horizontal swipe must cover to skip.
const double _skipFraction = 0.28;

/// Horizontal fling speed (logical px/s) that skips regardless.
const double _skipVelocity = 800;

/// Large Now Playing artwork.
///
/// * springs between playing / paused size, the shadow lifting with it;
/// * corners are a fixed share of the side ([LekisRadius.artworkFraction]),
///   so the cover keeps its shape at every window size;
/// * tap toggles play / pause; swipe left / right skips to the next /
///   previous track (the cover follows the finger, flies out and the new
///   one slides in). Vertical drags are left to the page (drag to close).
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

  @override
  void dispose() {
    _scale.dispose();
    _swipe.dispose();
    super.dispose();
  }

  void _springScale(double target) {
    _scale.animateWith(
      SpringSimulation(
        LekisMotion.springEmphasized,
        _scale.value,
        target,
        _scale.velocity,
      ),
    );
  }

  TickerFuture _springSwipe(double target, double velocity) =>
      _swipe.animateWith(
        SpringSimulation(
          LekisMotion.springStandard,
          _swipe.value,
          target,
          velocity,
          tolerance: const Tolerance(distance: 0.5, velocity: 5),
        ),
      );

  void _onSwipeUpdate(DragUpdateDetails d) {
    _swipe.stop();
    _swipe.value += d.delta.dx;
  }

  void _onSwipeEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final dx = _swipe.value;
    final commit =
        dx.abs() > _width * _skipFraction ||
        (v.abs() > _skipVelocity && v.sign == dx.sign);
    if (!commit) {
      _springSwipe(0, v);
      return;
    }
    final actions = ref.read(playerActionsProvider);
    dx < 0 ? actions.next() : actions.previous();
    final out = dx.sign * _width * 1.1;
    _springSwipe(out, v).whenComplete(() {
      if (!mounted) return;
      _swipe.value = -out * 0.5;
      _springSwipe(0, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      playbackProvider.select((s) => s.isPlaying),
      (_, playing) => _springScale(playing ? 1 : _pausedScale),
    );
    final scrim = context.lekisColors.scrim;
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.maxWidth;
            final radius = LekisRadius.artworkFor(constraints.maxWidth);
            return Semantics(
              image: true,
              label: '封面。轻点播放或暂停，左右滑动切歌',
              onTap: () => ref.read(playerActionsProvider).playPause(),
              child: GestureDetector(
                onTap: () => ref.read(playerActionsProvider).playPause(),
                onHorizontalDragUpdate: _onSwipeUpdate,
                onHorizontalDragEnd: _onSwipeEnd,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_scale, _swipe]),
                  builder: (context, child) {
                    // Shadow grows with the artwork for a sense of lift.
                    final lift =
                        ((_scale.value - _pausedScale) / (1 - _pausedScale))
                            .clamp(0.0, 1.0);
                    final dx = _swipe.value;
                    final away = (dx.abs() / _width).clamp(0.0, 1.0);
                    return Opacity(
                      opacity: 1 - away * 0.6,
                      child: Transform.translate(
                        offset: Offset(dx, 0),
                        child: Transform.rotate(
                          // A slight tilt, like a card being flicked away.
                          angle: dx / _width * 0.06,
                          child: Transform.scale(
                            scale: _scale.value * (1 - away * 0.08),
                            child: Material(
                              elevation:
                                  LekisSpacing.xs + lift * LekisSpacing.xl,
                              shadowColor: scrim,
                              borderRadius: BorderRadius.circular(radius),
                              clipBehavior: Clip.antiAlias,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: CurrentArtwork(radius: radius),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
