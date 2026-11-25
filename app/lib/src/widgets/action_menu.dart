// Actions for a track or playlist, shared by touch and pointer menus.
import 'package:material_ui/material_ui.dart';

import '../platform/ui_profile.dart';
import '../theme/tokens.dart';
import 'adaptive_panel.dart';

class LekisMenuAction<T> {
  const LekisMenuAction(
    this.value,
    this.icon,
    this.label, {
    this.startsGroup = false,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final bool startsGroup;
  final bool destructive;
  final bool enabled;
  final bool selected;

  Widget _label(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final foreground = !enabled
        ? theme.disabledColor
        : destructive
        ? colors.danger
        : null;
    return Semantics(
      selected: selected ? true : null,
      child: Row(
        children: [
          Icon(
            icon,
            size: LekisSpacing.xl - LekisSpacing.xs,
            color: foreground ?? colors.onSurfaceVariant,
          ),
          const SizedBox(width: LekisSpacing.lg),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
            ),
          ),
          if (selected) ...[
            const SizedBox(width: LekisSpacing.sm),
            Icon(
              Icons.check_rounded,
              color: colors.accent,
              size: LekisSpacing.xl - LekisSpacing.xs,
            ),
          ],
        ],
      ),
    );
  }
}

List<PopupMenuEntry<T>> lekisPopupActions<T>(
  BuildContext context,
  List<LekisMenuAction<T>> actions,
) => [
  for (final (index, action) in actions.indexed) ...[
    if (index > 0 && action.startsGroup) const PopupMenuDivider(),
    PopupMenuItem(
      enabled: action.enabled,
      value: action.value,
      child: action._label(context),
    ),
  ],
];

Future<T?> showLekisActionList<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  Widget? artwork,
  required List<LekisMenuAction<T>> actions,
}) async {
  Future<Object?>? dismissed;
  final selection = await showLekisSheet<T>(
    context,
    heightFactor: null,
    builder: (sheet) {
      dismissed = ModalRoute.of(sheet)?.completed;
      final theme = Theme.of(sheet);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                0,
                LekisSpacing.xl,
                LekisSpacing.md,
              ),
              child: Row(
                children: [
                  if (artwork != null) ...[
                    ExcludeSemantics(
                      child: SizedBox.square(
                        dimension: LekisSizes.listArtwork,
                        child: artwork,
                      ),
                    ),
                    const SizedBox(width: LekisSpacing.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        if (subtitle != null && subtitle.isNotEmpty) ...[
                          const SizedBox(height: LekisSpacing.xxs),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
                children: [
                  for (final (index, action) in actions.indexed) ...[
                    if (index > 0 && action.startsGroup)
                      const Divider(
                        height: LekisSpacing.md,
                        indent: LekisSpacing.xl,
                        endIndent: LekisSpacing.xl,
                      ),
                    Semantics(
                      button: true,
                      enabled: action.enabled,
                      child: InkWell(
                        onTap: action.enabled
                            ? () => Navigator.of(sheet).pop(action.value)
                            : null,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: LekisSizes.touchTargetMin,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LekisSpacing.xl,
                              vertical: LekisSpacing.sm,
                            ),
                            child: action._label(sheet),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  // A selected action can push another modal. Finish closing this surface first.
  await dismissed;
  return selection;
}

class LekisActionMenuButton<T> extends StatelessWidget {
  const LekisActionMenuButton({
    super.key,
    required this.title,
    this.subtitle,
    required this.tooltip,
    required this.actions,
    required this.onSelected,
    this.compact = false,
    this.artwork,
    this.icon = Icons.more_horiz_rounded,
  });
  final String title;
  final String? subtitle;
  final String tooltip;
  final List<LekisMenuAction<T>> Function() actions;
  final ValueChanged<T> onSelected;
  final bool compact;
  final Widget? artwork;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      icon,
      size: compact ? LekisSpacing.xl - LekisSpacing.xs : null,
      color: context.lekisColors.onSurfaceVariant,
    );
    final size = compact
        ? const BoxConstraints.tightFor(width: 36, height: 36)
        : null;
    if (!UiProfile.current.prefersSheets) {
      return PopupMenuButton<T>(
        tooltip: tooltip,
        icon: glyph,
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.all(LekisSpacing.sm),
        iconSize: glyph.size,
        position: PopupMenuPosition.under,
        style: compact
            ? IconButton.styleFrom(
                minimumSize: size!.smallest,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : null,
        itemBuilder: (context) => lekisPopupActions(context, actions()),
        onSelected: onSelected,
      );
    }
    return IconButton(
      tooltip: tooltip,
      icon: glyph,
      constraints: size,
      padding: compact ? EdgeInsets.zero : null,
      onPressed: () async {
        final value = await showLekisActionList(
          context,
          title: title,
          subtitle: subtitle,
          artwork: artwork,
          actions: actions(),
        );
        if (context.mounted && value != null) onSelected(value);
      },
    );
  }
}
