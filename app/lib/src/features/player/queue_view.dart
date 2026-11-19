// Queue preview used by the desktop context panel and the mobile bottom sheet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class QueueList extends ConsumerWidget {
  const QueueList({super.key, this.compact = false});

  /// Dense rows for the 320 dp context panel.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(queuePreviewProvider);
    final currentId = ref.watch(playbackProvider.select((s) => s.trackId));
    final colors = context.lekisColors;
    final theme = Theme.of(context);

    return rows.when(
      loading: () => const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Center(
        child: Text(
          '队列加载失败',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              '队列为空',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: LekisSpacing.sm),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: LekisSpacing.xxs),
          itemBuilder: (context, i) {
            final row = items[i];
            final isCurrent = row.id == currentId;
            final artSize = compact ? 36.0 : 44.0;
            return ListTile(
              dense: compact,
              visualDensity: compact ? VisualDensity.compact : null,
              contentPadding: EdgeInsets.symmetric(
                horizontal: compact ? LekisSpacing.sm : LekisSpacing.lg,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LekisRadius.sm),
              ),
              tileColor: isCurrent ? colors.accentSoft : null,
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
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 18,
                      color: colors.accent,
                    ),
                  LovedButton(
                    trackId: row.id,
                    initialLoved: row.loved,
                    size: 18,
                  ),
                  PopupMenuButton<String>(
                    tooltip: '队列操作',
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    padding: EdgeInsets.zero,
                    onSelected: (value) {
                      if (value == 'playlist') {
                        showAddToPlaylistSheet(
                          context,
                          trackId: row.id,
                          trackTitle: row.title,
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'playlist', child: Text('添加到歌单')),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Opens the queue as a bottom sheet (medium / compact windows, or from the
/// desktop player bar).
Future<void> showQueueSheet(BuildContext context) {
  final length = ProviderScope.containerOf(context)
      .read(playbackProvider)
      .queueLength;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.62,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LekisSpacing.xl,
              0,
              LekisSpacing.xl,
              LekisSpacing.sm,
            ),
            child: Row(
              children: [
                Text('播放队列', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: LekisSpacing.sm),
                Text(
                  '$length 首',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.lekisColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const Expanded(child: QueueList()),
        ],
      ),
    ),
  );
}
