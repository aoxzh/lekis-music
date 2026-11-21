import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_backdrop.dart';
import 'package:lekis/src/features/now_playing/now_playing_route.dart';
import 'package:lekis/src/features/now_playing/now_playing_tint.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

Color _rgb(int v) => Color(0xFF000000 | (v & 0xFFFFFF));

/// The [LekisNowPlaying.gradientColors] background colors for [palette]
/// (chosen by the core), padded from primary/secondary if short; theme
/// colors when there is no palette.
List<Color> gradientColorsFor(PaletteDto? palette, BuildContext context) {
  final n = LekisNowPlaying.gradientColors;
  if (palette == null) {
    final c = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    return [c.accentSoft, scheme.surface, c.surfaceVariant, c.accentSoft];
  }
  final src = [
    for (final v in palette.gradient) _rgb(v),
    _rgb(palette.primary),
    _rgb(palette.secondary),
  ];
  return [for (var i = 0; i < n; i++) src[i % src.length]];
}

/// Now Playing background, bottom to top:
/// 1. the cover, heavily blurred ([LekisNowPlaying.blurRadius]) and scaled
///    to fill the window, cross-fading on track change;
/// 2. the palette's flowing gradient (≈24 s loop) drifting over it at
///    [LekisNowPlaying.gradientOpacity];
/// 3. a top-bar protection gradient only – the reference `modern` style has
///    `backgroundProtection = 0`, so the cover is not dimmed globally;
/// 4. a faint static grain against banding in the soft gradients.
///
/// [NowPlayingBackdrop] draws all four from baked textures; see that file for
/// why nothing here is a live blur / gradient / shader any more.
///
/// [lowPower] (reduce-motion / battery saver) freezes the drift at its first
/// frame and drops the cross-fade, so nothing is redrawn per frame.
class NowPlayingBackground extends ConsumerStatefulWidget {
  const NowPlayingBackground({super.key, required this.lowPower});

  final bool lowPower;

  @override
  ConsumerState<NowPlayingBackground> createState() =>
      _NowPlayingBackgroundState();
}

class _NowPlayingBackgroundState extends ConsumerState<NowPlayingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle = AnimationController(
    vsync: this,
    duration: LekisNowPlaying.gradientCycle,
  );

  /// False while the Now Playing route is still opening / closing.
  bool _settled = true;

  /// The gradient drifts, and the grain is drawn, only when they can be seen
  /// at rest: not in low-power mode and not while the page flies in or out.
  void _syncCycle() {
    if (widget.lowPower || !_settled) {
      _cycle.stop();
    } else if (!_cycle.isAnimating) {
      _cycle.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settled = NowPlayingMotion.settledOf(context);
    _syncCycle();
  }

  @override
  void didUpdateWidget(covariant NowPlayingBackground old) {
    super.didUpdateWidget(old);
    _syncCycle();
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artwork = ref.watch(currentArtworkProvider).value;
    // Covers without artwork use the placeholder's deterministic colours, so
    // the background matches the gradient tile instead of the brand accent.
    final palette = ref.watch(
      nowPlayingPaletteProvider(Theme.of(context).brightness),
    );
    final colors = gradientColorsFor(palette, context);
    final tint = NowPlayingTint.resolve(palette, Theme.of(context).colorScheme);
    // Without a cover the gradient is the only thing over the flat colour, so
    // it is drawn stronger.
    final gradientOpacity = artwork == null
        ? (widget.lowPower ? 0.9 : 1.0)
        : LekisNowPlaying.gradientOpacity;

    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: colors.first),
          NowPlayingBackdrop(
            hash: artwork?.hash,
            colors: colors,
            opacity: gradientOpacity,
            scrim: tint.scene,
            protectionOpacity: tint.protectionOpacity,
            cycle: widget.lowPower ? const AlwaysStoppedAnimation(0) : _cycle,
            grain: _settled,
            crossfade: widget.lowPower
                ? Duration.zero
                : LekisMotion.backgroundCrossfade,
          ),
        ],
      ),
    );
  }
}
