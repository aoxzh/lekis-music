// Compact queue preview used by the mobile bottom sheet. Wide windows use
// the full, paged QueuePanel instead.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

class QueueList extends ConsumerWidget {
  const QueueList({super.key, this.compact = false});

  /// Dense rows for the 320 dp context panel.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(queuePreviewProvider);
    final playback = ref.watch(
      playbackProvider.select(
        (s) => (
          trackId: s.trackId,
          queueIndex: s.queueIndex,
          queueLength: s.queueLength,
        ),
      ),
    );
    final start = queuePreviewStart(playback.queueLength, playback.queueIndex);
    final actions = ref.read(playerActionsProvider);
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    // Phone-width sheets: tighter insets so the title keeps its room next to
    // the heart, menu and drag handle.
    final narrow = compact || MediaQuery.sizeOf(context).width < 560;

    return rows.when(
      loading: () => const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Center(
        child: Text(
          context.l10n.pick('队列加载失败', 'Failed to load queue'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              context.l10n.pick('队列为空', 'Queue is empty'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          );
        }
        return ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            color: colors.surfaceElevated,
            borderRadius: BorderRadius.circular(LekisRadius.sm),
            child: child,
          ),
          onReorderItem: (oldIndex, newIndex) {
            if (oldIndex == newIndex) return;
            actions.moveQueueItem(start + oldIndex, start + newIndex);
          },
          itemCount: items.length,
          itemBuilder: (context, i) {
            final row = items[i];
            final actualIndex = start + i;
            final isCurrent = playback.queueIndex != null
                ? actualIndex == playback.queueIndex
                : row.id == playback.trackId;
            final artSize = compact ? 36.0 : 44.0;
            return Padding(
              key: ValueKey('queue-row-$actualIndex-${row.id}'),
              padding: const EdgeInsets.symmetric(
                vertical: LekisSpacing.xxs / 2,
              ),
              child: ListTile(
                dense: compact,
                visualDensity: compact ? VisualDensity.compact : null,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: narrow ? LekisSpacing.sm : LekisSpacing.lg,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(LekisRadius.sm),
                ),
                tileColor: isCurrent ? colors.accentSoft : null,
                onTap: () => actions.playQueueAt(actualIndex),
                leading: SizedBox.square(
                  dimension: artSize,
                  child: TrackArtwork(
                    trackId: row.id,
                    hasArtwork: row.artworkId != null,
                    radius: LekisRadius.artworkList,
                    placeholderLabel: row.title,
                  ),
                ),
                title: Text(
                  row.title.isEmpty ? '（已删除）' : row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isCurrent ? colors.accent : null,
                    fontWeight: isCurrent ? FontWeight.w600 : null,
                  ),
                ),
                subtitle: row.artistLine.isEmpty
                    ? null
                    : Text(
                        row.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCurrent)
                      Padding(
                        padding: const EdgeInsets.only(right: LekisSpacing.xs),
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          size: 18,
                          color: colors.accent,
                        ),
                      ),
                    if (!compact)
                      LovedButton(
                        trackId: row.id,
                        initialLoved: row.loved,
                        size: 18,
                      ),
                    PopupMenuButton<String>(
                      tooltip: context.l10n.pick('队列操作', 'Queue actions'),
                      padding: EdgeInsets.zero,
                      onSelected: (value) {
                        switch (value) {
                          case 'playlist':
                            showAddToPlaylistSheet(
                              context,
                              trackId: row.id,
                              trackTitle: row.title,
                            );
                          case 'remove':
                            actions.removeQueueAt(actualIndex);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'playlist',
                          child: Text(
                            context.l10n.pick('添加到歌单', 'Add to Playlist'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(
                            context.l10n.pick('从队列移除', 'Remove from Queue'),
                          ),
                        ),
                      ],
                      // A 36 dp row action, matching the heart.
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LekisSpacing.xs,
                          vertical: LekisSpacing.sm,
                        ),
                        child: Icon(
                          Icons.drag_handle_rounded,
                          size: 20,
                          color: colors.onSurfaceVariant,
                          semanticLabel: '拖动排序',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Opens the queue: a right-hand side panel on expanded / wide windows and
/// on every desktop window, the familiar bottom sheet on medium / compact
/// phones and tablets.
Future<void> showQueueSheet(BuildContext context) {
  if (usesQueueSidePanel(context)) return showQueueSidePanel(context);
  return _showQueueBottomSheet(context);
}

Future<void> _showQueueBottomSheet(BuildContext context) {
  return showLekisSheet<void>(
    context,
    heightFactor: 0.62,
    builder: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.xl,
            0,
            LekisSpacing.xl,
            LekisSpacing.sm,
          ),
          child: Consumer(
            builder: (context, ref, _) {
              final length = ref.watch(
                playbackProvider.select((s) => s.queueLength),
              );
              return Row(
                children: [
                  Text(
                    context.l10n.queue,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  Text(
                    context.l10n.pick('$length 首', '$length tracks'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.lekisColors.onSurfaceVariant),
                  ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        const Expanded(child: QueueList()),
      ],
    ),
  );
}
