import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
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

enum _TrackMenuAction { addToPlaylist, rate }

/// Fixed-height song row (so long lists can use `itemExtent`).
class TrackTile extends ConsumerWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.leadingNumber,
    this.showArtwork = true,
  });

  /// Height of every row – use as `ListView.itemExtent`.
  static double get extent => LekisSizes.listArtwork + LekisSpacing.sm * 2;

  final TrackRowDto track;
  final VoidCallback onTap;

  /// Shown instead of artwork (album track lists).
  final int? leadingNumber;
  final bool showArtwork;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final isCurrent = ref.watch(
      playbackProvider.select((s) => s.trackId == track.id),
    );
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

    return Semantics(
      button: true,
      label: '${track.title}, ${track.artistLine}',
      child: PressFeedback(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LekisRadius.sm),
          child: SizedBox(
            height: extent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
              child: Row(
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
                            fontWeight: isCurrent ? FontWeight.w600 : null,
                          ),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (track.qualityBadge != null) ...[
                    const SizedBox(width: LekisSpacing.sm),
                    _QualityBadge(label: track.qualityBadge!),
                  ],
                  const SizedBox(width: LekisSpacing.xs),
                  LovedButton(
                    trackId: track.id,
                    initialLoved: track.loved,
                    size: LekisSpacing.lg,
                  ),
                  PopupMenuButton<_TrackMenuAction>(
                    tooltip: '更多操作',
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    onSelected: (action) {
                      switch (action) {
                        case _TrackMenuAction.addToPlaylist:
                          showAddToPlaylistSheet(
                            context,
                            trackId: track.id,
                            trackTitle: track.title,
                          );
                        case _TrackMenuAction.rate:
                          showTrackRatingSheet(
                            context,
                            trackId: track.id,
                            title: track.title,
                          );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: _TrackMenuAction.addToPlaylist,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.playlist_add_rounded),
                          title: Text('添加到歌单'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _TrackMenuAction.rate,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.star_outline_rounded),
                          title: Text('评分'),
                        ),
                      ),
                    ],
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
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(LekisRadius.xs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.xs,
          vertical: LekisSpacing.xxs,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Grey skeleton row while a page is loading.
class TrackTilePlaceholder extends StatelessWidget {
  const TrackTilePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    Widget bar(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: LekisSpacing.md,
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(LekisRadius.xs),
        ),
      ),
    );
    return SizedBox(
      height: TrackTile.extent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        child: Row(
          children: [
            SizedBox.square(
              dimension: LekisSizes.listArtwork,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(LekisRadius.artworkList),
                ),
              ),
            ),
            const SizedBox(width: LekisSpacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(0.5),
                  const SizedBox(height: LekisSpacing.sm),
                  bar(0.3),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
