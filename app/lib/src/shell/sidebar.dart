// Navigation chrome: an icon rail for medium windows and a full sidebar for
// expanded ones. Both use the same destinations and the same active language:
// a soft accent block plus a small accent marker (the same accent the
// settings list and the player use, so there is one selection colour).
//
// On desktop the sidebar uses [LekisDesktopType], the scale every desktop
// pane shares (14 px entries, 12 px muted group labels).

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/brand_mark.dart';

import 'destinations.dart';
import 'nav_icon.dart';

/// Desktop-style navigation column.
class LekisSidebar extends StatelessWidget {
  const LekisSidebar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LekisDestination selected;
  final ValueChanged<LekisDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final desktop = UiProfile.current.isDesktop
        ? LekisDesktopText.of(context)
        : null;

    return Material(
      color: scheme.surface,
      child: SafeArea(
        right: false,
        bottom: false,
        child: SizedBox(
          width: LekisSizes.desktopSidebarWidth,
          child: _FillOrScroll(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LekisSpacing.xl,
                    LekisSpacing.lg,
                    LekisSpacing.xl,
                    LekisSpacing.xl,
                  ),
                  child: Row(
                    children: [
                      const _MoonMark(size: 36),
                      const SizedBox(width: LekisSpacing.md),
                      Expanded(
                        child: Text(
                          context.l10n.brandShort,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleLarge?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.xl,
                  ),
                  child: Text(
                    context.l10n.pick('浏览', 'BROWSE'),
                    style:
                        desktop?.sectionHeader ??
                        text.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          letterSpacing: 1.2,
                        ),
                  ),
                ),
                const SizedBox(height: LekisSpacing.sm),
                for (final d in LekisDestination.values)
                  if (d != LekisDestination.settings)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LekisSpacing.md,
                        vertical: 1,
                      ),
                      child: _SidebarItem(
                        destination: d,
                        selected: d == selected,
                        onTap: () => onSelected(d),
                      ),
                    ),
                const Spacer(),
                Divider(color: colors.outline, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LekisSpacing.md,
                    LekisSpacing.xs,
                    LekisSpacing.md,
                    LekisSpacing.md,
                  ),
                  child: _SidebarItem(
                    destination: LekisDestination.settings,
                    selected: selected == LekisDestination.settings,
                    onTap: () => onSelected(LekisDestination.settings),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon-only navigation column for medium windows.
class LekisNavRail extends StatelessWidget {
  const LekisNavRail({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LekisDestination selected;
  final ValueChanged<LekisDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        right: false,
        bottom: false,
        child: SizedBox(
          width: 84,
          // Short windows (phone landscape, split screen) scroll the rail
          // instead of pushing Settings off the bottom edge.
          child: _FillOrScroll(
            child: Column(
              children: [
                const SizedBox(height: LekisSpacing.md),
                const _MoonMark(size: 40),
                const SizedBox(height: LekisSpacing.xl),
                for (final d in LekisDestination.values)
                  if (d != LekisDestination.settings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LekisSpacing.xs),
                      child: _RailItem(
                        destination: d,
                        selected: d == selected,
                        onTap: () => onSelected(d),
                      ),
                    ),
                const Spacer(),
                _RailItem(
                  destination: LekisDestination.settings,
                  selected: selected == LekisDestination.settings,
                  onTap: () => onSelected(LekisDestination.settings),
                ),
                const SizedBox(height: LekisSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays [child] out at least as tall as the viewport (so a Spacer inside
/// still pushes items apart) and scrolls when it does not fit.
class _FillOrScroll extends StatelessWidget {
  const _FillOrScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      primary: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: IntrinsicHeight(child: child),
      ),
    ),
  );
}

class _MoonMark extends StatelessWidget {
  const _MoonMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => LekisBrandMark(size: size, glow: true);
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final LekisDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final reduce = lekisReduceMotion(context);
    final fg = selected ? lekisNavForeground(context) : colors.onSurfaceVariant;
    final radius = BorderRadius.circular(LekisRadius.md);
    final desktop = UiProfile.current.isDesktop
        ? LekisDesktopText.of(context)
        : null;
    final label =
        (selected ? desktop?.itemSelected : desktop?.item) ??
        (text.bodyLarge ?? const TextStyle()).copyWith(
          color: selected ? scheme.onSurface : fg,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );

    final itemLabel = destination.labelOf(context);
    return Semantics(
      container: true,
      selected: selected,
      button: true,
      label: itemLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            lekisSelectionHaptic();
            onTap();
          },
          // A neutral hover, so a hovered entry never reads as a second
          // selected one next to the accent block.
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          child: AnimatedContainer(
            duration: reduce ? LekisMotion.fast : LekisMotion.normal,
            curve: Curves.easeOut,
            height: desktop != null
                ? LekisSpacing.xxl + LekisSpacing.sm
                : LekisSizes.touchTargetMin,
            padding: const EdgeInsets.only(left: LekisSpacing.sm),
            decoration: BoxDecoration(
              color: selected ? colors.accentSoft : Colors.transparent,
              borderRadius: radius,
            ),
            child: Row(
              children: [
                _SidebarMarker(selected: selected, reduce: reduce),
                const SizedBox(width: LekisSpacing.md),
                LekisNavIcon(
                  destination: destination,
                  selected: selected,
                  size: 20,
                  reducedMotion: reduce,
                ),
                const SizedBox(width: LekisSpacing.md),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: LekisMotion.fast,
                    curve: Curves.easeOut,
                    style: label,
                    child: Text(
                      itemLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Accent presence marker, grown with the standard spring so the sidebar uses
/// the same motion language as the bottom bar.
class _SidebarMarker extends StatelessWidget {
  const _SidebarMarker({required this.selected, required this.reduce});

  final bool selected;
  final bool reduce;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return SizedBox(
      width: 3,
      height: 18,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selected ? 1.0 : 0.0),
        duration: reduce
            ? LekisMotion.fast
            : LekisMotion.settleDuration(LekisMotion.springStandard),
        curve: reduce
            ? Curves.easeOut
            : LekisSpringCurve(LekisMotion.springStandard),
        builder: (context, t, _) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scaleY: t.clamp(0.0, 1.12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final LekisDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final text = Theme.of(context).textTheme;
    final reduce = lekisReduceMotion(context);
    final fg = selected ? lekisNavForeground(context) : colors.onSurfaceVariant;

    final itemLabel = destination.labelOf(context);
    return Semantics(
      container: true,
      selected: selected,
      button: true,
      label: itemLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: itemLabel,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(LekisRadius.md),
            onTap: () {
              lekisSelectionHaptic();
              onTap();
            },
            hoverColor: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.05),
            child: AnimatedContainer(
              duration: reduce ? LekisMotion.fast : LekisMotion.normal,
              curve: Curves.easeOut,
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
              decoration: BoxDecoration(
                color: selected ? colors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(LekisRadius.md),
                border: Border.all(
                  color: selected
                      ? colors.accent.withValues(alpha: 0.18)
                      : Colors.transparent,
                ),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: colors.accent.withValues(alpha: 0.10),
                          blurRadius: 14,
                          spreadRadius: -4,
                        ),
                      ]
                    : const [],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LekisNavIcon(
                    destination: destination,
                    selected: selected,
                    size: 22,
                    reducedMotion: reduce,
                  ),
                  const SizedBox(height: LekisSpacing.xs),
                  AnimatedDefaultTextStyle(
                    duration: LekisMotion.fast,
                    curve: Curves.easeOut,
                    style: (text.labelSmall ?? const TextStyle()).copyWith(
                      color: fg,
                      fontSize: 10,
                      letterSpacing: 0,
                    ),
                    child: Text(itemLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
