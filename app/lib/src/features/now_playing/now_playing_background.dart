import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
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

/// Logical size of the artwork copy that gets blurred and scaled up: tiny,
/// so the blur costs next to nothing and the upscale adds its own softness.
const double _blurSource = 64;

/// Now Playing background, bottom to top:
/// 1. the cover, heavily blurred ([LekisNowPlaying.blurRadius]) and scaled
///    to fill the window, cross-fading on track change;
/// 2. the palette's flowing gradient (≈24 s loop) drifting over it at
///    [LekisNowPlaying.gradientOpacity];
/// 3. a top-bar protection gradient only – the reference `modern` style has
///    `backgroundProtection = 0`, so the cover is not dimmed globally;
/// 4. a faint static grain against banding in the soft gradients.
///
/// [lowPower] (reduce-motion / battery saver) freezes the gradient at its
/// first frame and drops the cross-fade, so nothing is redrawn per frame.
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

  @override
  void initState() {
    super.initState();
    if (!widget.lowPower) _cycle.repeat();
  }

  @override
  void didUpdateWidget(covariant NowPlayingBackground old) {
    super.didUpdateWidget(old);
    if (widget.lowPower) {
      _cycle.stop();
    } else if (!_cycle.isAnimating) {
      _cycle.repeat();
    }
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
    final crossfade = widget.lowPower
        ? Duration.zero
        : LekisMotion.backgroundCrossfade;

    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: colors.first),
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: crossfade,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              child: artwork == null
                  ? const SizedBox.expand(key: ValueKey('none'))
                  : _BlurredArtwork(
                      key: ValueKey(artwork.hash),
                      hash: artwork.hash,
                    ),
            ),
          ),
          RepaintBoundary(
            child: widget.lowPower
                ? CustomPaint(
                    painter: _FlowingGradientPainter(
                      colors: colors,
                      cycle: const AlwaysStoppedAnimation(0),
                      opacity: artwork == null
                          ? 0.9
                          : LekisNowPlaying.gradientOpacity,
                    ),
                    child: const SizedBox.expand(),
                  )
                : TweenAnimationBuilder<List<Color>>(
                    tween: _ColorListTween(end: colors),
                    duration: crossfade,
                    curve: Curves.easeInOut,
                    builder: (context, value, _) => CustomPaint(
                      painter: _FlowingGradientPainter(
                        colors: value,
                        cycle: _cycle,
                        opacity: artwork == null
                            ? 1
                            : LekisNowPlaying.gradientOpacity,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
          ),
          // The reference modern style only protects the top bar. Everything
          // else keeps the full cover colour and relies on the adaptive
          // foreground / top-bar scrim for legibility.
          if (LekisNowPlaying.topBarProtectionOpacity > 0)
            IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  heightFactor: LekisNowPlaying.topBarProtectionHeight,
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          tint.scene.withValues(
                            alpha: LekisNowPlaying.topBarProtectionOpacity,
                          ),
                          tint.scene.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const RepaintBoundary(child: _Grain()),
        ],
      ),
    );
  }
}

/// The cover blurred at a tiny size, then scaled to cover the window.
class _BlurredArtwork extends StatelessWidget {
  const _BlurredArtwork({super.key, required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final longest = constraints.biggest.longestSide.isFinite
            ? constraints.biggest.longestSide
            : MediaQuery.sizeOf(context).longestSide;
        // Blur happens before the scale-up; convert the on-screen radius
        // to a sigma in source units.
        final scale = math.max(longest / _blurSource, 1.0);
        final sigma = math.max(
          (LekisNowPlaying.blurRadius * 0.57735 + 0.5) / scale,
          2.0,
        );
        return FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox.square(
            dimension: _blurSource,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
              child: ArtworkImage(hash: hash, radius: 0),
            ),
          ),
        );
      },
    );
  }
}

/// Static film grain blended with overlay (keeps average brightness).
class _Grain extends StatefulWidget {
  const _Grain();

  @override
  State<_Grain> createState() => _GrainState();
}

class _GrainState extends State<_Grain> {
  static Future<ui.Image>? _image;

  ui.Image? _loaded;

  static Future<ui.Image> _make() {
    const n = 128;
    final rnd = math.Random(7);
    final px = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      final v = 64 + rnd.nextInt(128);
      px[i * 4] = v;
      px[i * 4 + 1] = v;
      px[i * 4 + 2] = v;
      px[i * 4 + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, n, n, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  @override
  void initState() {
    super.initState();
    (_image ??= _make()).then((img) {
      if (mounted) setState(() => _loaded = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _loaded;
    if (img == null) return const SizedBox.expand();
    return CustomPaint(
      painter: _GrainPainter(img),
      child: const SizedBox.expand(),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        )
        ..color = const Color(0xFFFFFFFF)
            .withValues(alpha: LekisNowPlaying.noiseOpacity)
        ..blendMode = BlendMode.overlay,
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.image != image;
}

class _ColorListTween extends Tween<List<Color>> {
  _ColorListTween({required List<Color> end}) : super(begin: end, end: end);

  @override
  List<Color> lerp(double t) {
    final a = begin!, b = end!;
    if (a.length != b.length) return b;
    return [for (var i = 0; i < b.length; i++) Color.lerp(a[i], b[i], t)!];
  }
}

/// Four soft radial blobs drifting on closed Lissajous paths (integer
/// frequencies, so the loop is seamless).
class _FlowingGradientPainter extends CustomPainter {
  _FlowingGradientPainter({
    required this.colors,
    required this.cycle,
    this.opacity = 1,
  }) : super(repaint: cycle);

  final List<Color> colors;
  final Animation<double> cycle;

  /// Overall opacity (the blurred cover shows through below 1).
  final double opacity;

  static const _fx = [1, 1, 2, 1];
  static const _fy = [1, 2, 1, 1];
  static const _phase = [0.0, 1.7, 3.1, 4.4];
  static const _amplitude = 0.32;
  static const _radius = 0.85;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    Color fade(Color c) => c.withValues(alpha: c.a * opacity);
    canvas.drawRect(rect, Paint()..color = fade(colors.first));
    final t = cycle.value * 2 * math.pi;
    final r = size.longestSide * _radius;
    for (var i = 1; i < colors.length; i++) {
      final k = (i - 1) % _fx.length;
      final c = Offset(
        size.width * (0.5 + _amplitude * math.sin(_fx[k] * t + _phase[k])),
        size.height *
            (0.5 + _amplitude * math.cos(_fy[k] * t + _phase[k] * 0.7)),
      );
      final shader = RadialGradient(
        colors: [fade(colors[i]), colors[i].withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawRect(rect, Paint()..shader = shader);
    }
  }

  @override
  bool shouldRepaint(_FlowingGradientPainter old) =>
      old.colors != colors || old.opacity != opacity;
}
