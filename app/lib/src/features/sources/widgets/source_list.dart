// 音源列表。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../rust/api/dto.dart';
import '../../../theme/tokens.dart';
import '../../library/widgets/empty_state.dart';
import '../../library/widgets/page_gutter.dart';
import '../../radio/radio_page.dart';
import '../common.dart';
import '../source_kind_info.dart';
import '../sources_providers.dart';
import '../strings.dart';
import 'source_status.dart';

class SourceList extends ConsumerWidget {
  const SourceList({
    super.key,
    required this.onOpen,
    required this.onAdd,
    this.selectedId,
    this.bottomClearance = 0,
  });

  final ValueChanged<int> onOpen;
  final VoidCallback onAdd;
  final int? selectedId;

  /// Extra room after the last row (e.g. for a floating action button).
  final double bottomClearance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider);
    return sources.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message(
        icon: Icons.error_outline,
        title: SourcesStrings.loadFailed,
        body: describeCoreError(e),
        actionLabel: SourcesStrings.retry,
        actionIcon: Icons.refresh,
        onAction: () => ref.read(sourcesProvider.notifier).reload(),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Message(
            icon: Icons.library_music_outlined,
            title: SourcesStrings.emptyTitle,
            body: SourcesStrings.emptyBody,
            actionLabel: SourcesStrings.addSource,
            actionIcon: Icons.add,
            onAction: onAdd,
            secondaryLabel: '网络电台',
            secondaryIcon: Icons.radio_rounded,
            onSecondary: () =>
                Navigator.of(context).push<void>(RadioPage.route()),
          );
        }
        // Same gutter as the library: rows inset by `sm` so the badge lines
        // up with the page title while the selection highlight keeps a margin.
        final gutter = pageGutterOf(context);
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            gutter - LekisSpacing.sm,
            0,
            gutter - LekisSpacing.sm,
            scrollEndPadding(context) + bottomClearance,
          ),
          itemCount: list.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return _RadioEntryTile(
                onTap: () =>
                    Navigator.of(context).push<void>(RadioPage.route()),
              );
            }
            final source = list[i - 1];
            final id = source.id;
            return SourceTile(
              source: source,
              selected: id != null && id == selectedId,
              onTap: id == null ? null : () => onOpen(id),
            );
          },
        );
      },
    );
  }
}

class SourceTile extends ConsumerWidget {
  const SourceTile({
    super.key,
    required this.source,
    required this.selected,
    this.onTap,
  });

  final SourceConfigDto source;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = source.id;
    final runtime = id == null
        ? const SourceRuntime()
        : ref.watch(sourceRuntimeProvider.select((m) => m[id])) ??
              const SourceRuntime();
    final colors = context.lekisColors;
    final theme = Theme.of(context);

    final Widget subtitle = runtime.scanning
        ? Padding(
            padding: const EdgeInsets.only(top: LekisSpacing.xs),
            child: ScanProgressView(runtime: runtime, dense: true),
          )
        : Row(
            children: [
              ReachabilityDot(
                reachable: source.enabled ? runtime.reachable : null,
              ),
              const SizedBox(width: LekisSpacing.xs),
              Flexible(
                child: Text(
                  '${reachabilityLabel(source, runtime)} · ${lastScanLabel(runtime)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
      minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      selected: selected,
      selectedTileColor: colors.accentSoft,
      leading: SourceKindBadge(icon: source.kind.icon),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: DefaultTextStyle.merge(
        style: TextStyle(color: colors.onSurfaceVariant),
        child: subtitle,
      ),
      trailing: id == null || runtime.scanning
          ? null
          : _RescanButton(sourceId: id),
      onTap: onTap,
    );
  }
}

/// 「音源」页顶部的网络电台入口，不占一个真实音源。
class _RadioEntryTile extends StatelessWidget {
  const _RadioEntryTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    // Same row metrics as [SourceTile] so the entry lines up with the sources.
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
      minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LekisRadius.md),
      ),
      leading: const SourceKindBadge(icon: Icons.radio_rounded),
      title: Text(
        '网络电台',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text(
        '搜索 Radio Browser，管理收藏和自定义流',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.onSurfaceVariant),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: colors.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}

class _RescanButton extends ConsumerWidget {
  const _RescanButton({required this.sourceId});
  final int sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: SourcesStrings.rescan,
    constraints: const BoxConstraints(
      minWidth: LekisSizes.touchTargetMin,
      minHeight: LekisSizes.touchTargetMin,
    ),
    icon: const Icon(Icons.refresh),
    onPressed: () => rescanWithFeedback(context, ref, sourceId),
  );
}

/// 重新扫描并在失败时提示。
Future<void> rescanWithFeedback(
  BuildContext context,
  WidgetRef ref,
  int sourceId,
) async {
  try {
    await ref.read(sourceActionsProvider).rescan(sourceId);
  } catch (e) {
    if (context.mounted) showFeatureSnack(context, describeCoreError(e));
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.secondaryLabel,
    this.secondaryIcon,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final IconData? secondaryIcon;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return LekisEmptyState(
      eyebrow: '音源',
      title: title,
      message: body,
      maxWidth: featureMaxContentWidth / 2,
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, LekisSizes.touchTargetMin),
            ),
            onPressed: onAction,
            icon: Icon(actionIcon),
            label: Text(actionLabel),
          ),
          if (secondaryLabel != null && onSecondary != null) ...[
            const SizedBox(height: LekisSpacing.sm),
            TextButton.icon(
              onPressed: onSecondary,
              icon: Icon(secondaryIcon ?? Icons.radio_rounded),
              label: Text(secondaryLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
