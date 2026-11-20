// Liquid glass backdrop for floating chrome (tab bar).
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

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

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
