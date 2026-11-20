// Two visual choices for the bottom tab bar, with a miniature preview of
// each material so the setting is understandable without leaving Settings.

import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'strings.dart';

class TabBarStylePicker extends StatelessWidget {
  const TabBarStylePicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final TabBarStyle selected;
  final ValueChanged<TabBarStyle> onChanged;

  static Key styleKey(TabBarStyle style) =>
      ValueKey('lekis.tabbar.style.${style.name}');

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StyleChoice(
              key: styleKey(TabBarStyle.liquid),
              style: TabBarStyle.liquid,
              label: SettingsStrings.tabBarLiquid,
              hint: SettingsStrings.tabBarLiquidHint,
              selected: selected == TabBarStyle.liquid,
              onTap: () => onChanged(TabBarStyle.liquid),
            ),
          ),
          const SizedBox(width: LekisSpacing.md),
          Expanded(
            child: _StyleChoice(
              key: styleKey(TabBarStyle.flat),
              style: TabBarStyle.flat,
              label: SettingsStrings.tabBarFlat,
              hint: SettingsStrings.tabBarFlatHint,
              selected: selected == TabBarStyle.flat,
              onTap: () => onChanged(TabBarStyle.flat),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleChoice extends StatelessWidget {
  const _StyleChoice({
    super.key,
    required this.style,
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final TabBarStyle style;
  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(LekisRadius.md);

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: '$label，$hint',
      onTap: onTap,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: LekisMotion.fast,
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? colors.accentSoft.withValues(alpha: 0.55)
              : scheme.surface,
          borderRadius: radius,
          border: Border.all(color: selected ? colors.accent : colors.outline),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.all(LekisSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MiniTabBar(style: style),
                  const SizedBox(height: LekisSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelLarge?.copyWith(
                            color: selected ? colors.accent : scheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: LekisSpacing.lg,
                          color: colors.accent,
                        ),
                    ],
                  ),
                  const SizedBox(height: LekisSpacing.xxs),
                  Text(
                    hint,
                    maxLines: 2,
                    softWrap: true,
                    style: text.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
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

/// The preview bar is the real bar at half height.
const double _miniBarHeight = LekisTabBarTokens.height / 2;

/// Selection pill inside the preview bar.
const double _miniPillSize = _miniBarHeight - LekisSpacing.sm;

/// A tiny five-slot bar: enough to show the material difference at a glance.
class _MiniTabBar extends StatelessWidget {
  const _MiniTabBar({required this.style});

  final TabBarStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final liquid = style == TabBarStyle.liquid;
    final radius = BorderRadius.circular(LekisRadius.pill);

    return SizedBox(
      height: _miniBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: liquid ? null : colors.surfaceElevated,
          gradient: liquid
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                      colors.accent.withValues(alpha: 0.10),
                      colors.surfaceElevated,
                    ),
                    colors.surfaceVariant,
                  ],
                )
              : null,
          border: Border.all(
            color: liquid
                ? colors.outline.withValues(alpha: 0.9)
                : colors.outline,
          ),
          boxShadow: liquid
              ? [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: 0.12),
                    blurRadius: LekisSpacing.sm,
                    offset: const Offset(0, LekisSpacing.xxs),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 5; i++)
                    Container(
                      width: LekisSpacing.xs,
                      height: LekisSpacing.xs,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              Align(
                alignment: const Alignment(-0.5, 0),
                child: Container(
                  width: _miniPillSize,
                  height: _miniPillSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      liquid ? LekisRadius.pill : LekisRadius.xs,
                    ),
                    color: liquid ? null : colors.accentSoft,
                    gradient: liquid
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.alphaBlend(
                                colors.accent.withValues(alpha: 0.30),
                                colors.surfaceElevated,
                              ),
                              colors.accentSoft,
                            ],
                          )
                        : null,
                    border: liquid
                        ? Border.all(
                            color: colors.accent.withValues(alpha: 0.35),
                          )
                        : null,
                    boxShadow: liquid
                        ? [
                            BoxShadow(
                              color: colors.accent.withValues(alpha: 0.18),
                              blurRadius: LekisSpacing.sm,
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Container(
                      width: LekisSpacing.xs,
                      height: LekisSpacing.xs,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
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
