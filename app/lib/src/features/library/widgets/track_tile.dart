import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/tag_editor_dialog.dart';
import 'package:lekis/src/features/library/track_sources_sheet.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/features/library/widgets/press_feedback.dart';
import 'package:material_ui/material_ui.dart';

String formatDuration(int ms) {
  if (ms < 0) ms = 0;
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// "FLAC 16/44.1" → "FLAC" for narrow rows; labels without a space stay whole.
String _compactQualityLabel(String label) {
  final space = label.indexOf(' ');
  return space > 0 ? label.substring(0, space) : label;
}

enum _TrackMenuAction {
  playNext,
  addToQueue,
  addToPlaylist,
  rate,
  editTags,
  enrich,
  artwork,
  sources,
  download,
}

/// Fixed-height song row (so long lists can use `itemExtent`).
class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.onLongPress,
    this.leadingNumber,
    this.showArtwork = true,
    this.selected = false,
  });

  /// Height of every row – use as `ListView.itemExtent`. 56 dp: the 48 dp
  /// artwork with a slim margin, so the library reads denser than Home while
  /// the row and its buttons stay 48 dp touch targets.
  static double get extent => LekisSizes.listArtwork + LekisSpacing.sm;

  final TrackRowDto track;
  final VoidCallback onTap;

  /// 批量选择：长按进入选择模式。
  final VoidCallback? onLongPress;

  /// Shown instead of artwork (album track lists).
  final int? leadingNumber;
  final bool showArtwork;

  /// 批量选择时高亮。
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final isCurrent = ref.watch(
      playbackProvider.select((s) => s.trackId == track.id),
    );
    final downloadState = ref.watch(downloadStateProvider(track.id));
    final subtitle = [
      track.artistLine,
      if (track.albumTitle != null && leadingNumber == null) track.albumTitle!,
    ].where((s) => s.isNotEmpty).join(' · ');

    Widget leading;
    if (leadingNumber != null) {
      leading = SizedBox(
        width: LekisSizes.listArtwork,
        child: Center(
          child: isCurrent
              ? Icon(Icons.graphic_eq_rounded, color: colors.accent)
              : Text(
                  '$leadingNumber',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
      );
    } else if (showArtwork) {
      leading = SizedBox.square(
        dimension: LekisSizes.listArtwork,
        child: TrackArtwork(
          trackId: track.id,
          hasArtwork: track.artworkId != null,
          placeholderLabel: track.title,
        ),
      );
    } else {
      leading = const SizedBox.shrink();
    }
    if (selected) {
      leading = Stack(
        alignment: Alignment.center,
        children: [
          leading,
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(LekisRadius.artworkList),
              ),
              child: Icon(
                Icons.check_rounded,
                color: colors.onAccent,
                size: 24,
              ),
            ),
          ),
        ],
      );
    }

    void onMenu(_TrackMenuAction action) {
      switch (action) {
        case _TrackMenuAction.playNext:
          queueTracks(context, [track.id], where: QueuePlacement.next);
        case _TrackMenuAction.addToQueue:
          queueTracks(context, [track.id], where: QueuePlacement.end);
        case _TrackMenuAction.addToPlaylist:
          showAddToPlaylistSheet(
            context,
            trackId: track.id,
            trackTitle: track.title,
          );
        case _TrackMenuAction.rate:
          showTrackRatingSheet(context, trackId: track.id, title: track.title);
        case _TrackMenuAction.editTags:
          showTrackTagEditor(
            context,
            trackId: track.id,
            trackTitle: track.title,
          );
        case _TrackMenuAction.enrich:
          enrichTracksFlow(context, [track.id]);
        case _TrackMenuAction.artwork:
          changeArtworkFlow(context, trackIds: [track.id]);
        case _TrackMenuAction.sources:
          showTrackSourcesSheet(
            context,
            trackId: track.id,
            trackTitle: track.title,
          );
        case _TrackMenuAction.download:
          runDownloadMenuAction(context, ref, track.id, downloadState);
      }
    }

    List<PopupMenuEntry<_TrackMenuAction>> menuItems() => [
      const PopupMenuItem(
        value: _TrackMenuAction.playNext,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.queue_play_next_rounded),
          title: Text(QueueStrings.playNext),
        ),
      ),
      const PopupMenuItem(
        value: _TrackMenuAction.addToQueue,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.add_to_queue_rounded),
          title: Text(QueueStrings.addToQueue),
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _TrackMenuAction.addToPlaylist,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.playlist_add_rounded),
          title: Text('添加到歌单'),
        ),
      ),
      const PopupMenuItem(
        value: _TrackMenuAction.rate,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.star_outline_rounded),
          title: Text('评分'),
        ),
      ),
      const PopupMenuItem(
        value: _TrackMenuAction.editTags,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.edit_note_rounded),
          title: Text('编辑标签'),
        ),
      ),
      PopupMenuItem(
        value: _TrackMenuAction.enrich,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.auto_fix_high_rounded),
          title: Text(EnrichActionStrings.action),
        ),
      ),
      const PopupMenuItem(
        value: _TrackMenuAction.artwork,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.image_outlined),
          title: Text(ArtworkActionStrings.change),
        ),
      ),
      PopupMenuItem(
        value: _TrackMenuAction.sources,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.layers_outlined),
          title: Text(UnifiedStrings.menuTitle),
        ),
      ),
      if (!track.isLocal || downloadState != null)
        PopupMenuItem(
          value: _TrackMenuAction.download,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              downloadState == null
                  ? Icons.download_for_offline_outlined
                  : downloadState == OfflineStateDto.ready
                  ? Icons.delete_outline_rounded
                  : downloadState == OfflineStateDto.failed
                  ? Icons.refresh_rounded
                  : Icons.download_done_rounded,
            ),
            title: Text(downloadMenuLabel(downloadState)),
          ),
        ),
    ];

    // Right-click (mouse, trackpad, stylus button) opens the same menu at
    // the pointer, like every desktop music app.
    Future<void> openContextMenu(Offset position) async {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final action = await showMenu<_TrackMenuAction>(
        context: context,
        position: RelativeRect.fromRect(
          position & Size.zero,
          Offset.zero & overlay.size,
        ),
        items: menuItems(),
      );
      if (action != null && context.mounted) onMenu(action);
    }

    return Semantics(
      button: true,
      selected: selected,
      label: '${track.title}, ${track.artistLine}',
      child: PressFeedback(
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapUp: (details) =>
              openContextMenu(details.globalPosition),
          borderRadius: BorderRadius.circular(LekisRadius.sm),
          child: ColoredBox(
            color: selected ? colors.accentSoft : Colors.transparent,
            child: SizedBox(
              height: extent,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LekisSpacing.sm,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Metadata is secondary: on phones show just the codec,
                    // never a full-width badge that squeezes the title.
                    final compact = constraints.maxWidth < 560;
                    final quality = track.qualityBadge;
                    final qualityLabel = quality == null
                        ? null
                        : compact
                        ? _compactQualityLabel(quality)
                        : quality;
                    final hasSubtitle = subtitle.isNotEmpty;
                    return Row(
                      children: [
                        leading,
                        const SizedBox(width: LekisSpacing.md),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: isCurrent ? colors.accent : null,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : null,
                                ),
                              ),
                              if (hasSubtitle || qualityLabel != null)
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                    if (qualityLabel != null) ...[
                                      const SizedBox(width: LekisSpacing.xs),
                                      _QualityBadge(label: qualityLabel),
                                    ],
                                  ],
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: LekisSpacing.xs),
                        CompactDownloadProgress(trackId: track.id),
                        LovedButton(
                          trackId: track.id,
                          initialLoved: track.loved,
                          size: LekisSpacing.lg,
                        ),
                        PopupMenuButton<_TrackMenuAction>(
                          tooltip: '更多操作',
                          padding: EdgeInsets.zero,
                          onSelected: onMenu,
                          itemBuilder: (_) => menuItems(),
                          // A 36 dp row action, matching the heart; the same
                          // menu still opens from a long press.
                          child: const SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(Icons.more_horiz_rounded, size: 20),
                          ),
                        ),
                        const SizedBox(width: LekisSpacing.xs),
                        Text(
                          formatDuration(track.durationMs.toInt()),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    // A quiet filled chip, not an outlined tag: the title and artist stay
    // primary and the codec reads as a footnote.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(LekisRadius.xs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.xs,
          vertical: 1,
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.onSurfaceVariant.withValues(alpha: 0.85),
            fontSize: 10,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
