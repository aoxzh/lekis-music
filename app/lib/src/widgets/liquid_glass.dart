// Liquid glass backdrop for floating chrome (tab bar, mini player).
//
// The look and its numbers follow CYLTabBarController's Android Liquid Glass
// style, itself a port of Kyant's Backdrop `LiquidBottomTabs`: what is behind
// the capsule is saturated (vibrancy 1.5), lightly blurred, and bent by a
// lens near the rim (24 dp reach, 24 dp bend); a 40 % surface tint and a
// 45° rim light sit on top (drawn by the caller).
//
// The lens needs `ImageFilter.shader`, i.e. Impeller (Android, iOS, macOS).
// Elsewhere (Windows / Linux on Skia, or before the shader has loaded) the
// glass falls back to a heavier blur, which still reads as frosted glass.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'glass.dart';

/// Loads the lens shader once for the whole app.
abstract final class LiquidGlassLens {
  static const _asset = 'shaders/liquid_glass_lens.frag';

  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram?>? _loading;

  /// Whether this backend can run the lens at all.
  static bool get supported => ui.ImageFilter.isShaderFilterSupported;

  static ui.FragmentProgram? get program => _program;

  static Future<ui.FragmentProgram?> load() {
    if (!supported) return Future.value(null);
    return _loading ??= ui.FragmentProgram.fromAsset(_asset)
        .then<ui.FragmentProgram?>((p) => _program = p)
        .catchError((Object _) => null);
  }
}

/// A rounded-rectangle glass surface: [child] is painted on top of the
/// filtered backdrop, clipped to [radius].
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.radius,
    required this.child,
    this.blurSigma = 5,
    this.fallbackBlurSigma = 22,
    this.refractionHeight = 24,
    this.refractionAmount = 24,
    this.enableLens = true,
  });

  final double radius;
  final Widget child;

  /// Blur under the lens (Android's 8 dp blur radius ≈ sigma 5).
  final double blurSigma;

  /// Blur when there is no lens: frosted rather than clear glass.
  final double fallbackBlurSigma;

  /// Lens reach in from the rim and bend, in logical pixels.
  final double refractionHeight;
  final double refractionAmount;

  /// Turn the lens off (reduced motion / low power keeps a plain blur).
  final bool enableLens;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    final program = LiquidGlassLens.program;
    if (program != null) {
      _shader = program.fragmentShader();
    } else if (LiquidGlassLens.supported) {
      LiquidGlassLens.load().then((p) {
        if (!mounted || p == null) return;
        setState(() => _shader = p.fragmentShader());
      });
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lens = widget.enableLens ? _shader : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: _LiquidBackdrop(
        shader: lens,
        radius: widget.radius,
        blurSigma: lens == null ? widget.fallbackBlurSigma : widget.blurSigma,
        refractionHeight: widget.refractionHeight,
        refractionAmount: widget.refractionAmount,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        child: widget.child,
      ),
    );
  }
}

class _LiquidBackdrop extends SingleChildRenderObjectWidget {
  const _LiquidBackdrop({
    required this.shader,
    required this.radius,
    required this.blurSigma,
    required this.refractionHeight,
    required this.refractionAmount,
    required this.devicePixelRatio,
    super.child,
  });

  final ui.FragmentShader? shader;
  final double radius;
  final double blurSigma;
  final double refractionHeight;
  final double refractionAmount;
  final double devicePixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLiquidBackdrop()
        ..shader = shader
        ..radius = radius
        ..blurSigma = blurSigma
        ..refractionHeight = refractionHeight
        ..refractionAmount = refractionAmount
        ..devicePixelRatio = devicePixelRatio;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLiquidBackdrop renderObject,
  ) {
    renderObject
      ..shader = shader
      ..radius = radius
      ..blurSigma = blurSigma
      ..refractionHeight = refractionHeight
      ..refractionAmount = refractionAmount
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _RenderLiquidBackdrop extends RenderProxyBox {
  ui.FragmentShader? _shader;
  set shader(ui.FragmentShader? value) {
    if (identical(value, _shader)) return;
    _shader = value;
    markNeedsPaint();
  }

  double _radius = 0;
  set radius(double value) => _set(_radius, value, (v) => _radius = v);

  double _blurSigma = 0;
  set blurSigma(double value) => _set(_blurSigma, value, (v) => _blurSigma = v);

  double _refractionHeight = 0;
  set refractionHeight(double value) =>
      _set(_refractionHeight, value, (v) => _refractionHeight = v);

  double _refractionAmount = 0;
  set refractionAmount(double value) =>
      _set(_refractionAmount, value, (v) => _refractionAmount = v);

  double _dpr = 1;
  set devicePixelRatio(double value) => _set(_dpr, value, (v) => _dpr = v);

  void _set(double old, double value, void Function(double) assign) {
    if (old == value) return;
    assign(value);
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    final frost = lekisGlassFilter(_blurSigma);
    ui.ImageFilter filter = frost;
    final shader = _shader;
    if (shader != null && !size.isEmpty) {
      // The backdrop texture is in physical pixels of the enclosing pass
      // (the window), so give the lens its shape in those coordinates.
      final origin = localToGlobal(Offset.zero) * _dpr;
      shader
        ..setFloat(2, origin.dx)
        ..setFloat(3, origin.dy)
        ..setFloat(4, size.width * _dpr)
        ..setFloat(5, size.height * _dpr)
        ..setFloat(6, _radius * _dpr)
        ..setFloat(7, _refractionHeight * _dpr)
        ..setFloat(8, _refractionAmount * _dpr);
      // Lens on the sharp backdrop, then vibrancy + blur on top.
      filter = ui.ImageFilter.compose(
        outer: frost,
        inner: ui.ImageFilter.shader(shader, filterQuality: FilterQuality.low),
      );
    }
    layer ??= BackdropFilterLayer();
    layer!.filter = filter;
    context.pushLayer(layer!, super.paint, offset);
  }
}

/// The one surface for floating chrome: the bottom tab bar, the side tab
/// capsule and the mini player all paint exactly this, so they always read
/// as the same material.
///
/// * liquid ([flat] false): saturated, blurred (lens-bent where supported)
///   backdrop, a 40 % surface tint, a top-lit body with a touch of accent /
///   moonlight, film grain, a 45 degree rim light and a soft outside-only
///   shadow;
/// * flat: an opaque elevated surface with a 1 px outline, no blur.
///
/// [child] is clipped to the rounded rectangle of [radius].
class LekisGlassCapsule extends StatelessWidget {
  const LekisGlassCapsule({
    super.key,
    required this.radius,
    required this.child,
    this.flat = false,
    this.enableLens = true,
  });

  final double radius;
  final Widget child;
  final bool flat;

  /// Turn the lens off (reduced motion / low power keeps a plain blur).
  final bool enableLens;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final shape = BorderRadius.circular(radius);
    if (flat) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: shape,
          border: Border.all(color: colors.outline),
        ),
        child: ClipRRect(borderRadius: shape, child: child),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Glass only reads as glass when what is behind it shows through: keep
    // the tint light, blur hard and boost saturation (vibrancy) so content
    // scrolling underneath turns into soft colour, not a grey slab.
    final tint = colors.surfaceElevated.withValues(
      alpha: isDark
          ? LekisTabBarTokens.glassTintDark
          : LekisTabBarTokens.glassTintLight,
    );
    return DecoratedBox(
      // Backdrop's default shadow, drawn outside the capsule only: under
      // translucent glass a filled shadow would show through as a slab.
      decoration: _OutsideShadowDecoration(radius: shape, isDark: isDark),
      child: DecoratedBox(
        decoration: _GlassRimDecoration(radius: shape, isDark: isDark),
        position: DecorationPosition.foreground,
        child: LiquidGlass(
          radius: radius,
          enableLens: enableLens,
          blurSigma: LekisTabBarTokens.lensBlurSigma,
          fallbackBlurSigma: LekisTabBarTokens.blurSigma,
          refractionHeight: LekisTabBarTokens.refractionHeight,
          refractionAmount: LekisTabBarTokens.refractionAmount,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: ColoredBox(color: tint)),
              // Top-lit body: a little brighter at the top edge, a touch of
              // accent / moonlight across the capsule.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: isDark ? 0.07 : 0.30),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colors.accent.withValues(alpha: isDark ? 0.10 : 0.06),
                        Colors.transparent,
                        colors.moon.withValues(alpha: isDark ? 0.06 : 0.04),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned.fill(child: _GlassNoise(isDark: isDark)),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Static film grain. Fixed seed, so it never shimmers while things move.
class _GlassNoise extends StatelessWidget {
  const _GlassNoise({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _NoisePainter(color: isDark ? Colors.white : Colors.black),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _NoisePainter extends CustomPainter {
  const _NoisePainter({required this.color});

  final Color color;

  static final List<_Speck> _specks = _makeSpecks();

  static List<_Speck> _makeSpecks() {
    final random = math.Random(2211);
    return List<_Speck>.unmodifiable([
      for (var i = 0; i < 640; i++)
        _Speck(
          x: random.nextDouble(),
          y: random.nextDouble(),
          strength: 0.35 + random.nextDouble() * 0.65,
        ),
    ]);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final speck in _specks) {
      paint.color = color.withValues(
        alpha: LekisTabBarTokens.noiseOpacity * speck.strength,
      );
      canvas.drawRect(
        Rect.fromLTWH(speck.x * size.width, speck.y * size.height, 1, 1),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_NoisePainter old) => old.color != color;
}

class _Speck {
  const _Speck({required this.x, required this.y, required this.strength});

  final double x;
  final double y;
  final double strength;
}

/// Glass edge: a bright specular rim along the top fading to a faint one at
/// the bottom, the way light catches the lip of a glass capsule.
class _GlassRimDecoration extends Decoration {
  const _GlassRimDecoration({required this.radius, required this.isDark});

  final BorderRadius radius;
  final bool isDark;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _GlassRimPainter(this);
}

class _GlassRimPainter extends BoxPainter {
  _GlassRimPainter(this.decoration);

  final _GlassRimDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = (offset & size).deflate(0.5);
    final rrect = decoration.radius.toRRect(rect);
    final isDark = decoration.isDark;
    // Backdrop's `Highlight.Default`: a thin rim, brightest where the edge
    // faces 45 degrees (top-left / bottom-right), added over the glass.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..blendMode = BlendMode.plus
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.42 : 0.70),
          Colors.white.withValues(alpha: isDark ? 0.05 : 0.15),
          Colors.white.withValues(alpha: isDark ? 0.05 : 0.15),
          Colors.white.withValues(alpha: isDark ? 0.30 : 0.55),
        ],
        stops: const [0, 0.35, 0.65, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }
}

/// Soft drop shadow (12 dp blur, 4 dp down) painted only outside [radius]'s
/// rounded rectangle.
class _OutsideShadowDecoration extends Decoration {
  const _OutsideShadowDecoration({required this.radius, required this.isDark});

  final BorderRadius radius;
  final bool isDark;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _OutsideShadowPainter(this);
}

class _OutsideShadowPainter extends BoxPainter {
  _OutsideShadowPainter(this.decoration);

  final _OutsideShadowDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rrect = decoration.radius.toRRect(offset & size);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((offset & size).inflate(48))
      ..addRRect(rrect);
    canvas
      ..save()
      ..clipPath(outside)
      ..drawRRect(
        rrect.shift(const Offset(0, 4)),
        Paint()
          ..color = Colors.black.withValues(
            alpha: decoration.isDark ? 0.25 : 0.10,
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      )
      ..restore();
  }
}
