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

import 'package:flutter/physics.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
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
    this.axis = Axis.horizontal,
  });

  final LekisDestination selected;
  final ValueChanged<LekisDestination> onSelected;
  final TabBarStyle style;

  /// Horizontal: the bottom capsule on phones. Vertical: an icon-only
  /// capsule floating on the trailing edge of unfolded foldables / tablets.
  final Axis axis;

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
    if (widget.style.resolved == TabBarStyle.flat) {
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

  bool get _vertical => widget.axis == Axis.vertical;

  /// Thickness of the capsule across its axis.
  static const double _thickness = LekisTabBarTokens.height;

  @override
  Widget build(BuildContext context) {
    final reduced = lekisReduceMotion(context);
    final count = LekisDestination.values.length;
    final bar = widget.style.resolved == TabBarStyle.flat
        ? _flatBar(context, reduced)
        : _liquidBar(context, reduced);
    if (_vertical) {
      return SizedBox(
        width: _thickness,
        height:
            LekisTabBarTokens.verticalSlot * count +
            LekisTabBarTokens.innerInset * 2,
        child: bar,
      );
    }
    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: LekisSizes.miniPlayerMargin),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.lg),
        // A compact capsule centred under the content, not a full-width
        // strip: slots stay a thumb's width apart on any phone.
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  LekisTabBarTokens.maxSlotWidth * count +
                  LekisTabBarTokens.innerInset * 2,
            ),
            child: SizedBox(height: _thickness, child: bar),
          ),
        ),
      ),
    );
  }

  Widget _liquidBar(BuildContext context, bool reduced) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: LekisGlassCapsule(
        key: LekisTabBar.liquidSurfaceKey,
        radius: LekisTabBarTokens.height / 2,
        enableLens: !reduced,
        child: _slots(context, reduced),
      ),
    );
  }

  Widget _flatBar(BuildContext context, bool reduced) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: LekisGlassCapsule(
        key: LekisTabBar.flatSurfaceKey,
        radius: LekisTabBarTokens.height / 2,
        flat: true,
        child: _slots(context, reduced),
      ),
    );
  }

  Widget _slots(BuildContext context, bool reduced) {
    final colors = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final liquid = widget.style.resolved == TabBarStyle.liquid;
    final count = LekisDestination.values.length;
    const inset = LekisTabBarTokens.innerInset;
    final pillInset = liquid ? LekisTabBarTokens.pillInset : LekisSpacing.sm;
    final pillHeight = liquid
        ? LekisTabBarTokens.height - LekisSpacing.sm
        : LekisSizes.touchTargetMin;

    final vertical = _vertical;
    return LayoutBuilder(
      builder: (context, constraints) {
        final main = vertical ? constraints.maxHeight : constraints.maxWidth;
        final slot = (main - inset * 2) / count;
        final items = [
          for (final destination in LekisDestination.values)
            Expanded(
              child: _TabItem(
                key: LekisTabBar.tabKey(destination),
                destination: destination,
                selected: destination == widget.selected,
                style: widget.style.resolved,
                reducedMotion: reduced,
                bounceTrigger: _taps[destination.index],
                showLabel: !vertical,
                onTap: () => _onTap(destination),
              ),
            ),
        ];
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
                // Along the axis the bubble fills its slot (and stretches
                // while travelling); across it, it fills the capsule.
                final along = (slot - pillInset * 2) * (1 + stretch);
                final across = pillHeight - (liquid ? stretch * 6 : 0);
                final center = inset + (_position.value + 0.5) * slot;
                final phase = _position.value % 1.0;
                final direction = _position.velocity >= 0 ? 1.0 : -1.0;
                final sweep = liquid && !reduced
                    ? math.sin(phase * math.pi) * 0.7 * direction
                    : 0.0;
                final pillW = vertical ? across : along;
                final pillH = vertical ? along : across;

                return Positioned(
                  left: vertical
                      ? (_thickness - pillW) / 2
                      : center - pillW / 2,
                  top: vertical ? center - pillH / 2 : (_thickness - pillH) / 2,
                  width: pillW,
                  height: pillH,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: reduced ? _reducedFade.value : 1,
                      child: Container(
                        key: LekisTabBar.selectionKey,
                        clipBehavior: Clip.antiAlias,
                        decoration: liquid
                            ? _liquidSelection(
                                colors,
                                isDark,
                                math.min(pillW, pillH),
                              )
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
              padding: vertical
                  ? const EdgeInsets.symmetric(vertical: inset)
                  : const EdgeInsets.symmetric(horizontal: inset),
              child: Material(
                type: MaterialType.transparency,
                child: vertical
                    ? Column(children: items)
                    : Row(children: items),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The one selection indicator: a soft bubble behind the active tab
  /// (Backdrop / CYL: 10 % white on dark, 6 % black on light, tinted a
  /// little toward the accent). No border, glow or shadow: the icon colour
  /// is the only other cue.
  BoxDecoration _liquidSelection(
    LekisColors colors,
    bool isDark,
    double shortSide,
  ) {
    final base = isDark ? Colors.white : Colors.black;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(shortSide / 2),
      color: Color.alphaBlend(
        colors.accent.withValues(alpha: isDark ? 0.12 : 0.06),
        base.withValues(alpha: isDark ? 0.10 : 0.06),
      ),
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
    this.showLabel = true,
  });

  final LekisDestination destination;
  final bool selected;
  final TabBarStyle style;
  final bool reducedMotion;
  final int bounceTrigger;
  final VoidCallback onTap;
  final bool showLabel;

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

    final itemLabel = destination.labelOf(context);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: itemLabel,
      onTap: onTap,
      excludeSemantics: true,
      // No ripple / highlight box: the travelling bubble is the feedback;
      // a second square flash on top of it read as double emphasis.
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: colors.accent.withValues(alpha: 0.04),
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
            if (showLabel) const SizedBox(height: LekisTabBarTokens.iconGap),
            if (showLabel)
              SizedBox(
                height: LekisTabBarTokens.labelHeight,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: selected ? 1.0 : 0.0),
                  duration: labelDuration,
                  curve: liquid ? Curves.easeOut : Curves.easeOutCubic,
                  // Every tab keeps its label (like iOS 26 / LiquidBottomTabs):
                  // five icon-only slots read as sparse, scattered dots. The
                  // selected label just lifts into full strength.
                  builder: (context, t, child) => Opacity(
                    opacity: 0.8 + 0.2 * t,
                    child: Transform.translate(
                      offset: Offset(
                        0,
                        liquid && !reducedMotion ? (1 - t) * 1.5 : 0,
                      ),
                      child: child,
                    ),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      itemLabel,
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
