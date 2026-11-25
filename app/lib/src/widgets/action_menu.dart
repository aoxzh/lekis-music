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
    this.description,
    this.startsGroup = false,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? description;
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
                ),
                if (description != null)
                  Text(
                    description!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground ?? colors.onSurfaceVariant,
                    ),
                  ),
              ],
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

List<PopupMenuEntry<T>> _popupActions<T>(
  List<LekisMenuAction<T>> actions, {
  ValueChanged<Future<Object?>>? onRoute,
}) => [
  for (final (index, action) in actions.indexed) ...[
    if (index > 0 && action.startsGroup) const PopupMenuDivider(),
    PopupMenuItem(
      enabled: action.enabled,
      value: action.value,
      child: Builder(
        builder: (entry) {
          onRoute?.call(ModalRoute.of(entry)!.completed);
          return action._label(entry);
        },
      ),
    ),
  ],
];

Future<T?> showLekisActionList<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  Widget? artwork,
  required List<LekisMenuAction<T>> actions,
}) => showLekisSheet<T>(
  context,
  heightFactor: null,
  builder: (sheet) {
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
                          maxLines: 2,
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

/// A pointer-triggered menu, anchored in the navigator overlay's coordinates.
Future<T?> showLekisPointerMenu<T>(
  BuildContext context,
  Offset position,
  List<LekisMenuAction<T>> actions,
) => _showPopup(
  context,
  actions,
  (overlay) => overlay.globalToLocal(position) & Size.zero,
);

Future<T?> _showPopup<T>(
  BuildContext context,
  List<LekisMenuAction<T>> actions,
  Rect Function(RenderBox) anchor,
) async {
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  Future<Object?>? dismissed;
  final position = RelativeRect.fromRect(
    anchor(overlay),
    Offset.zero & overlay.size,
  );
  final value = await showMenu<T>(
    context: context,
    positionBuilder: (_, _) => context.mounted && overlay.attached
        ? RelativeRect.fromRect(anchor(overlay), Offset.zero & overlay.size)
        : position,
    popUpAnimationStyle: lekisPanelMotion(context),
    items: _popupActions(actions, onRoute: (future) => dismissed = future),
  );
  await dismissed;
  return value;
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
    this.child,
    this.triggerIcon,
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
  final Widget? child;
  final Widget? triggerIcon;

  @override
  Widget build(BuildContext context) {
    final glyph =
        triggerIcon ??
        Icon(
          icon,
          size: compact ? LekisSpacing.xl - LekisSpacing.xs : null,
          color: context.lekisColors.onSurfaceVariant,
        );
    final size = compact && !UiProfile.current.prefersSheets
        ? const BoxConstraints.tightFor(width: 36, height: 36)
        : null;
    Future<void> open() async {
      final items = actions();
      if (items.isEmpty) return;
      // A focused search box must not reclaim the keyboard between two sheets.
      if (UiProfile.current.prefersSheets &&
          MediaQuery.viewInsetsOf(context).bottom > 0) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
      final button = context.findRenderObject()! as RenderBox;
      final value = UiProfile.current.prefersSheets
          ? await showLekisActionList(
              context,
              title: title,
              subtitle: subtitle,
              artwork: artwork,
              actions: items,
            )
          : await _showPopup(context, items, (overlay) {
              final bottom = button.localToGlobal(
                Offset(0, button.size.height),
                ancestor: overlay,
              );
              return bottom & Size(button.size.width, 0);
            });
      if (context.mounted && value != null) onSelected(value);
    }

    if (child != null) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: open,
          borderRadius: BorderRadius.circular(LekisRadius.sm),
          child: child,
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      icon: glyph,
      constraints: size,
      padding: compact ? EdgeInsets.zero : null,
      onPressed: open,
    );
  }
}
