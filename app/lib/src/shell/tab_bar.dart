// Floating bottom tab bar for compact windows.
//
// Two selectable looks share the same interaction language (inspired by
// CYLTabBarController, ideas only):
//  * liquid glass: blurred translucent capsule, film grain, an accent glow,
//    a spring selection pill that stretches/morphs while travelling, a
//    moving specular sheen, icon squash/lift and label slide/fade;
//  * flat: an opaque hairline capsule, a plain rounded selection block that
//    eases in 170 ms, and icon scale/fade only.
//
// Both keep a selection haptic and an ink ripple. Reduced motion (and
// platforms that report animations disabled for low power/accessibility)
// jumps to the destination and uses a 150 ms fade.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/physics.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'destinations.dart';
import 'nav_icon.dart';
import 'tab_bar_style.dart';

class LekisTabBar extends StatefulWidget {
  const LekisTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.style = TabBarStyle.liquid,
  });

  final LekisDestination selected;
  final ValueChanged<LekisDestination> onSelected;
  final TabBarStyle style;

  /// The moving selection indicator. Exposed for widget tests.
  static const Key selectionKey = ValueKey('lekis.tabbar.selection');

  /// Stable finders for tests and accessibility tooling.
  static const Key liquidSurfaceKey = ValueKey('lekis.tabbar.liquid');
  static const Key flatSurfaceKey = ValueKey('lekis.tabbar.flat');

  static Key tabKey(LekisDestination destination) =>
      ValueKey('lekis.tabbar.${destination.name}');

  @override
  State<LekisTabBar> createState() => _LekisTabBarState();
}

class _LekisTabBarState extends State<LekisTabBar>
    with TickerProviderStateMixin {
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selected.index.toDouble(),
  );

  /// 0 → 1 fade used instead of motion when motion is disabled. Keep the
  /// explicit 150 ms fallback even when the framework would otherwise
  /// compress controller durations to a single frame.
  late final AnimationController _reducedFade = AnimationController(
    vsync: this,
    duration: LekisMotion.fast,
    value: 1,
    animationBehavior: AnimationBehavior.preserve,
  );

  final List<int> _taps = List<int>.filled(
    LekisDestination.values.length,
    0,
    growable: false,
  );

  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = lekisReduceMotion(context);
    if (reduced != _reducedMotion) {
      _reducedMotion = reduced;
      if (reduced) {
        _position.stop();
        _position.value = widget.selected.index.toDouble();
        _reducedFade.value = 1;
      }
    }
  }

  @override
  void didUpdateWidget(LekisTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = lekisReduceMotion(context);
    _reducedMotion = reduced;

    if (widget.selected != oldWidget.selected) {
      _moveTo(widget.selected.index.toDouble(), reduced);
    } else if (widget.style != oldWidget.style) {
      // Restyle in place; finish any in-flight travel using the new motion.
      _moveTo(widget.selected.index.toDouble(), reduced, fade: false);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _reducedFade.dispose();
    super.dispose();
  }

  void _moveTo(double target, bool reduced, {bool fade = true}) {
    if (reduced) {
      _position.stop();
      _position.value = target;
      if (fade) _reducedFade.forward(from: 0);
      return;
    }

    _reducedFade.value = 1;
    if (widget.style == TabBarStyle.flat) {
      _position.animateTo(
        target,
        duration: LekisMotion.navFlat,
        curve: Curves.easeOutCubic,
      );
    } else {
      _position.animateWith(
        SpringSimulation(
          LekisMotion.springStandard,
          _position.value,
          target,
          _position.velocity,
          tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
        ),
      );
    }
  }

  void _onTap(LekisDestination destination) {
    lekisSelectionHaptic();
    if (destination == widget.selected) {
      setState(() => _taps[destination.index]++);
    }
    widget.onSelected(destination);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = lekisReduceMotion(context);
    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: LekisSizes.miniPlayerMargin),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LekisSpacing.lg,
          LekisSpacing.xs,
          LekisSpacing.lg,
          0,
        ),
        child: SizedBox(
          height: LekisTabBarTokens.height,
          child: widget.style == TabBarStyle.flat
              ? _flatBar(context, reduced)
              : _liquidBar(context, reduced),
        ),
      ),
    );
  }

  Widget _liquidBar(BuildContext context, bool reduced) {
    final colors = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(LekisTabBarTokens.height / 2);
    final tint = colors.surfaceElevated.withValues(alpha: isDark ? 0.72 : 0.84);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: Container(
        key: LekisTabBar.liquidSurfaceKey,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: colors.scrim.withValues(alpha: isDark ? 0.45 : 0.16),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: colors.accent.withValues(alpha: isDark ? 0.10 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: colors.outline.withValues(alpha: 0.9)),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: LekisTabBarTokens.blurSigma,
              sigmaY: LekisTabBarTokens.blurSigma,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: tint),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colors.accent.withValues(alpha: isDark ? 0.12 : 0.07),
                        Colors.transparent,
                        colors.moon.withValues(alpha: isDark ? 0.07 : 0.045),
                      ],
                    ),
                  ),
                ),
                _SelectionGlow(animation: _position, color: colors.accent),
                _BarNoise(isDark: isDark),
                _slots(context, reduced),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _flatBar(BuildContext context, bool reduced) {
    final colors = context.lekisColors;
    final radius = BorderRadius.circular(LekisTabBarTokens.height / 2);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: Container(
        key: LekisTabBar.flatSurfaceKey,
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: radius,
          border: Border.all(color: colors.outline),
        ),
        child: ClipRRect(borderRadius: radius, child: _slots(context, reduced)),
      ),
    );
  }

  Widget _slots(BuildContext context, bool reduced) {
    final colors = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final liquid = widget.style == TabBarStyle.liquid;
    final count = LekisDestination.values.length;
    const inset = LekisTabBarTokens.innerInset;
    final pillInset = liquid ? LekisTabBarTokens.pillInset : LekisSpacing.sm;
    final pillHeight = liquid
        ? LekisTabBarTokens.height - LekisSpacing.sm
        : LekisSizes.touchTargetMin;

    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = (constraints.maxWidth - inset * 2) / count;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([_position, _reducedFade]),
              builder: (context, _) {
                final stretch = liquid && !reduced
                    ? (_position.velocity.abs() * 0.02)
                          .clamp(0.0, LekisTabBarTokens.maxPillStretch)
                          .toDouble()
                    : 0.0;
                final width = (slot - pillInset * 2) * (1 + stretch);
                final height = pillHeight - (liquid ? stretch * 6 : 0);
                final center = inset + (_position.value + 0.5) * slot;
                final phase = _position.value % 1.0;
                final direction = _position.velocity >= 0 ? 1.0 : -1.0;
                final sweep = liquid && !reduced
                    ? math.sin(phase * math.pi) * 0.7 * direction
                    : 0.0;

                return Positioned(
                  left: center - width / 2,
                  top: (LekisTabBarTokens.height - height) / 2,
                  width: width,
                  height: height,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: reduced ? _reducedFade.value : 1,
                      child: Container(
                        key: LekisTabBar.selectionKey,
                        clipBehavior: Clip.antiAlias,
                        decoration: liquid
                            ? _liquidSelection(colors, isDark, height)
                            : BoxDecoration(
                                color: colors.accentSoft,
                                borderRadius: BorderRadius.circular(
                                  LekisRadius.md,
                                ),
                              ),
                        child: liquid
                            ? _SpecularSheen(isDark: isDark, sweep: sweep)
                            : null,
                      ),
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: inset),
              child: Material(
                type: MaterialType.transparency,
                child: Row(
                  children: [
                    for (final destination in LekisDestination.values)
                      Expanded(
                        child: _TabItem(
                          key: LekisTabBar.tabKey(destination),
                          destination: destination,
                          selected: destination == widget.selected,
                          style: widget.style,
                          reducedMotion: reduced,
                          bounceTrigger: _taps[destination.index],
                          onTap: () => _onTap(destination),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  BoxDecoration _liquidSelection(
    LekisColors colors,
    bool isDark,
    double height,
  ) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(height / 2),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            colors.accent.withValues(alpha: isDark ? 0.30 : 0.16),
            colors.surfaceElevated,
          ),
          Color.alphaBlend(
            colors.accent.withValues(alpha: isDark ? 0.18 : 0.08),
            colors.surfaceVariant,
          ),
        ],
      ),
      border: Border.all(
        color: colors.accent.withValues(alpha: isDark ? 0.35 : 0.22),
      ),
      boxShadow: [
        BoxShadow(
          color: colors.accent.withValues(alpha: isDark ? 0.18 : 0.12),
          blurRadius: 14,
          spreadRadius: -2,
        ),
      ],
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.style,
    required this.reducedMotion,
    required this.bounceTrigger,
    required this.onTap,
  });

  final LekisDestination destination;
  final bool selected;
  final TabBarStyle style;
  final bool reducedMotion;
  final int bounceTrigger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final labelColor = selected
        ? lekisNavForeground(context)
        : colors.onSurfaceVariant;
    final liquid = style == TabBarStyle.liquid;
    final labelDuration = reducedMotion
        ? LekisMotion.fast
        : (liquid ? LekisMotion.fast : LekisMotion.navFlat);

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: destination.label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LekisRadius.lg),
        splashColor: colors.accent.withValues(alpha: 0.10),
        highlightColor: colors.accent.withValues(alpha: 0.05),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LekisNavIcon(
              destination: destination,
              selected: selected,
              reducedMotion: reducedMotion,
              bounceTrigger: bounceTrigger,
              motion: liquid ? NavIconMotion.bounce : NavIconMotion.fadeScale,
            ),
            const SizedBox(height: LekisTabBarTokens.iconGap),
            SizedBox(
              height: LekisTabBarTokens.labelHeight,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: selected ? 1.0 : 0.0),
                duration: labelDuration,
                curve: liquid ? Curves.easeOut : Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(
                      0,
                      liquid && !reducedMotion ? (1 - t) * 4 : 0,
                    ),
                    child: child,
                  ),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    softWrap: false,
                    style: text.labelSmall?.copyWith(
                      color: labelColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A diagonal specular band that sweeps across the pill while it travels.
class _SpecularSheen extends StatelessWidget {
  const _SpecularSheen({required this.isDark, required this.sweep});

  final bool isDark;
  final double sweep;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1.4 + sweep, -1),
          end: Alignment(-0.2 + sweep, 1),
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.14 : 0.42),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: isDark ? 0.04 : 0.10),
          ],
          stops: const [0, 0.5, 1],
        ),
      ),
    );
  }
}

/// Soft accent light under the selection pill; it travels with the pill so
/// the capsule picks up a little of the dynamic colour language.
class _SelectionGlow extends StatelessWidget {
  const _SelectionGlow({required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SelectionGlowPainter(animation: animation, color: color),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SelectionGlowPainter extends CustomPainter {
  _SelectionGlowPainter({required this.animation, required this.color})
    : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final count = LekisDestination.values.length;
    const inset = LekisTabBarTokens.innerInset;
    final slot = (size.width - inset * 2) / count;
    final center = Offset(
      inset + (animation.value + 0.5) * slot,
      size.height / 2,
    );
    final radius = size.height * 1.45;
    final shader = RadialGradient(
      colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0)],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_SelectionGlowPainter old) => old.color != color;
}

/// Static film grain. Fixed seed, so it never shimmers while the pill moves.
class _BarNoise extends StatelessWidget {
  const _BarNoise({required this.isDark});

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
