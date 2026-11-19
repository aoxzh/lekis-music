// Navigation chrome: an icon rail for medium windows and a full sidebar for
// expanded ones. Both use the same destinations and the same active language:
// a soft moonlight block plus a small gold marker.

import 'package:material_ui/material_ui.dart';

import 'package:lekis/src/theme/tokens.dart';

import 'destinations.dart';

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

    return Material(
      color: scheme.surface,
      child: SafeArea(
        right: false,
        bottom: false,
        child: SizedBox(
          width: LekisSizes.desktopSidebarWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LekisSpacing.xl,
                  LekisSpacing.lg,
                  LekisSpacing.xl,
                  LekisSpacing.xxl,
                ),
                child: Row(
                  children: [
                    const _MoonMark(size: 40),
                    const SizedBox(width: LekisSpacing.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Lekis',
                          style: text.titleLarge?.copyWith(
                            color: scheme.onSurface,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          'LOCAL FIRST',
                          style: text.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            letterSpacing: 1.4,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LekisSpacing.xl,
                ),
                child: Text(
                  '浏览',
                  style: text.labelSmall?.copyWith(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: LekisSpacing.md,
                  vertical: LekisSpacing.xs,
                ),
                child: _SidebarItem(
                  destination: LekisDestination.settings,
                  selected: selected == LekisDestination.settings,
                  onTap: () => onSelected(LekisDestination.settings),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LekisSpacing.xl,
                  LekisSpacing.xs,
                  LekisSpacing.xl,
                  LekisSpacing.lg,
                ),
                child: Text(
                  '本地优先 · 无账号',
                  style: text.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
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
    );
  }
}

class _MoonMark extends StatelessWidget {
  const _MoonMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            colors.moon.withValues(alpha: 0.30),
            colors.accentSoft.withValues(alpha: 0.35),
          ],
        ),
        border: Border.all(color: colors.moon.withValues(alpha: 0.35)),
      ),
      child: Icon(
        Icons.nightlight_round,
        size: size * 0.46,
        color: colors.moon,
      ),
    );
  }
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
    final fg = selected ? colors.accent : colors.onSurfaceVariant;
    final radius = BorderRadius.circular(LekisRadius.md);

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          hoverColor: colors.accentSoft.withValues(alpha: 0.55),
          child: AnimatedContainer(
            duration: LekisMotion.fast,
            curve: Curves.easeOut,
            height: 44,
            padding: const EdgeInsets.only(left: LekisSpacing.sm),
            decoration: BoxDecoration(
              color: selected ? colors.accentSoft : Colors.transparent,
              borderRadius: radius,
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: LekisMotion.fast,
                  width: 3,
                  height: selected ? 18 : 0,
                  decoration: BoxDecoration(
                    color: colors.moon,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: LekisSpacing.md),
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 20,
                  color: fg,
                ),
                const SizedBox(width: LekisSpacing.md),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(
                      color: selected ? scheme.onSurface : fg,
                      fontWeight: selected ? FontWeight.w600 : null,
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
    final fg = selected ? colors.accent : colors.onSurfaceVariant;

    return Tooltip(
      message: destination.label,
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(LekisRadius.md),
          onTap: onTap,
          hoverColor: colors.accentSoft.withValues(alpha: 0.55),
          child: AnimatedContainer(
            duration: LekisMotion.fast,
            width: 64,
            padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
            decoration: BoxDecoration(
              color: selected ? colors.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(LekisRadius.md),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 22,
                  color: fg,
                ),
                const SizedBox(height: LekisSpacing.xs),
                Text(
                  destination.label,
                  style: text.labelSmall?.copyWith(
                    color: fg,
                    fontSize: 10,
                    letterSpacing: 0,
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
