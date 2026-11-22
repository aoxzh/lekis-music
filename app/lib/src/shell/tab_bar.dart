// Floating bottom tab bar for compact windows.
//
// The selection language follows Telegram Android's glass tabs (ideas only):
// each slot owns its selected backdrop instead of one pill travelling across
// the bar. The backdrop is a light accent wash that fades and scales in place
// (320 ms, decelerate, no shadow), while the icon colours cross-fade and the
// active label gains weight. On a narrow phone a stretching, grey-looking
// pill read as a moving shadow; an in-place tint stays calm.
//
// Two selectable looks share the same interaction:
//  * liquid glass: blurred translucent capsule, film grain, a rim light, and
//    an accent-tinted selection block;
//  * flat: an opaque hairline capsule and a plain tinted selection block.
//
// Both keep a selection haptic and an ink ripple. Reduced motion (and
// platforms that report animations disabled for low power/accessibility)
// jumps to the destination and uses a short fade.

import 'dart:math' as math;

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

  /// The active slot's selection backdrop. Exposed for widget tests.
  static const Key selectionKey = ValueKey('lekis.tabbar.selection');

  /// Stable finders for tests and accessibility tooling.
  static const Key liquidSurfaceKey = ValueKey('lekis.tabbar.liquid');
  static const Key flatSurfaceKey = ValueKey('lekis.tabbar.flat');

  static Key tabKey(LekisDestination destination) =>
      ValueKey('lekis.tabbar.${destination.name}');

  @override
  State<LekisTabBar> createState() => _LekisTabBarState();
}

class _LekisTabBarState extends State<LekisTabBar> {
  final List<int> _taps = List<int>.filled(
    LekisDestination.values.length,
    0,
    growable: false,
  );

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
    final vertical = _vertical;
    const inset = LekisTabBarTokens.innerInset;
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
    return Padding(
      padding: vertical
          ? const EdgeInsets.symmetric(vertical: inset)
          : const EdgeInsets.symmetric(horizontal: inset),
      child: Material(
        type: MaterialType.transparency,
        child: vertical ? Column(children: items) : Row(children: items),
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
    final liquid = style == TabBarStyle.liquid;
    final activeColor = lekisNavForeground(context);
    final labelDuration = reducedMotion
        ? LekisMotion.fast
        : (liquid ? LekisMotion.navSelection : LekisMotion.navFlat);

    final itemLabel = destination.labelOf(context);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: itemLabel,
      onTap: onTap,
      excludeSemantics: true,
      // No ripple / highlight box: the selection backdrop is the feedback;
      // a second square flash on top of it read as double emphasis.
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: colors.accent.withValues(alpha: 0.04),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Telegram-style selection: one subtle tint per slot, fading and
            // scaling in place. No travelling pill, no shadow.
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(LekisTabBarTokens.pillInset),
                child: _SelectionBackdrop(
                  selected: selected,
                  style: style,
                  reducedMotion: reducedMotion,
                ),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LekisNavIcon(
                  destination: destination,
                  selected: selected,
                  reducedMotion: reducedMotion,
                  bounceTrigger: bounceTrigger,
                  motion: liquid
                      ? NavIconMotion.bounce
                      : NavIconMotion.fadeScale,
                ),
                if (showLabel)
                  const SizedBox(height: LekisTabBarTokens.iconGap),
                if (showLabel)
                  SizedBox(
                    height: LekisTabBarTokens.labelHeight,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: selected ? 1.0 : 0.0),
                      duration: labelDuration,
                      curve: liquid ? Curves.easeOut : Curves.easeOutCubic,
                      // Every tab keeps its label (like iOS 26 / LiquidBottomTabs):
                      // icon-only slots read as sparse, scattered dots. The
                      // selected label lifts into full strength and weight.
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
                            color: selected
                                ? activeColor
                                : colors.onSurfaceVariant,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The active slot's tinted block. It cross-fades in place: no travelling
/// pill and no shadow, so the bar reads as one calm surface while the icon
/// and label carry the selection.
class _SelectionBackdrop extends StatelessWidget {
  const _SelectionBackdrop({
    required this.selected,
    required this.style,
    required this.reducedMotion,
  });

  final bool selected;
  final TabBarStyle style;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final liquid = style == TabBarStyle.liquid;
    final duration = reducedMotion
        ? LekisMotion.fast
        : (liquid ? LekisMotion.navSelection : LekisMotion.navFlat);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: selected ? 1.0 : 0.0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        // Telegram's glass tabs grow the block from 60 % as it fades in.
        final scale = liquid && !reducedMotion ? 0.6 + 0.4 * t : 1.0;
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: scale,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final shortSide = math.min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return Container(
                  key: selected ? LekisTabBar.selectionKey : null,
                  decoration: BoxDecoration(
                    color: liquid
                        ? colors.accent.withValues(
                            alpha: isDark
                                ? LekisTabBarTokens.selectionTintDark
                                : LekisTabBarTokens.selectionTintLight,
                          )
                        : colors.accentSoft,
                    borderRadius: BorderRadius.circular(shortSide / 2),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
