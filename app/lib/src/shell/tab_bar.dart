// Floating, translucent bottom tab bar for compact windows.
//
// Interaction language (inspired by CYLTabBarController, ideas only):
//  * the selection pill springs between five equal slots and stretches a
//    little while travelling, then settles;
//  * the active icon squashes, lifts and settles;
//  * its label fades and slides up while inactive labels stay hidden;
//  * a selection haptic and an ink ripple confirm every tap;
//  * a radial accent glow and a whisper of film grain keep the blurred
//    capsule from looking flat.
//
// The capsule floats 16 dp in from each side (safe-area aware) and never
// spans edge to edge, matching the reference app's floating toolbar.
//
// Reduced motion (and platforms that report animations disabled for low
// power / accessibility) jumps to the destination and uses a 150 ms fade.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/physics.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'destinations.dart';
import 'nav_icon.dart';

class LekisTabBar extends StatefulWidget {
  const LekisTabBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LekisDestination selected;
  final ValueChanged<LekisDestination> onSelected;

  /// The moving pill. Exposed so widget tests can check reduced motion.
  static const Key selectionKey = ValueKey('lekis.tabbar.selection');

  /// Stable finder for one destination.
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

  /// 0 → 1 fade used instead of the spring when motion is disabled. Keep
  /// the explicit 150 ms fallback even when the framework would normally
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
    if (widget.selected == oldWidget.selected) return;

    final target = widget.selected.index.toDouble();
    final reduced = lekisReduceMotion(context);
    _reducedMotion = reduced;
    if (reduced) {
      _position.stop();
      _position.value = target;
      _reducedFade.forward(from: 0);
    } else {
      _reducedFade.value = 1;
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

  @override
  void dispose() {
    _position.dispose();
    _reducedFade.dispose();
    super.dispose();
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
          child: _bar(context, reduced),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, bool reduced) {
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

  Widget _slots(BuildContext context, bool reduced) {
    final colors = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final count = LekisDestination.values.length;
    const inset = LekisTabBarTokens.innerInset;
    const pillInset = LekisTabBarTokens.pillInset;
    final pillHeight = LekisTabBarTokens.height - LekisSpacing.sm;

    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = (constraints.maxWidth - inset * 2) / count;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([_position, _reducedFade]),
              builder: (context, _) {
                final stretch = reduced
                    ? 0.0
                    : (_position.velocity.abs() * 0.02)
                          .clamp(0.0, LekisTabBarTokens.maxPillStretch)
                          .toDouble();
                final width = (slot - pillInset * 2) * (1 + stretch);
                final center = inset + (_position.value + 0.5) * slot;
                return Positioned(
                  left: center - width / 2,
                  top: (LekisTabBarTokens.height - pillHeight) / 2,
                  width: width,
                  height: pillHeight,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: reduced ? _reducedFade.value : 1,
                      child: Container(
                        key: LekisTabBar.selectionKey,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(pillHeight / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(
                                colors.accent.withValues(
                                  alpha: isDark ? 0.30 : 0.16,
                                ),
                                colors.surfaceElevated,
                              ),
                              Color.alphaBlend(
                                colors.accent.withValues(
                                  alpha: isDark ? 0.18 : 0.08,
                                ),
                                colors.surfaceVariant,
                              ),
                            ],
                          ),
                          border: Border.all(
                            color: colors.accent.withValues(
                              alpha: isDark ? 0.35 : 0.22,
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: colors.accent.withValues(
                                alpha: isDark ? 0.18 : 0.12,
                              ),
                              blurRadius: 14,
                              spreadRadius: -2,
                            ),
                          ],
                        ),
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
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.reducedMotion,
    required this.bounceTrigger,
    required this.onTap,
  });

  final LekisDestination destination;
  final bool selected;
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
            ),
            const SizedBox(height: LekisTabBarTokens.iconGap),
            SizedBox(
              height: LekisTabBarTokens.labelHeight,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: selected ? 1.0 : 0.0),
                duration: LekisMotion.fast,
                curve: Curves.easeOut,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, reducedMotion ? 0 : (1 - t) * 4),
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
