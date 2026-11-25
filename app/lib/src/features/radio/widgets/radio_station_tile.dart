// 一个网络电台的列表行：图标、名称、国家 / 语言、编码 / 码率、收藏。

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

class RadioStationTile extends StatelessWidget {
  const RadioStationTile({
    super.key,
    required this.station,
    required this.playing,
    required this.favorite,
    required this.onPlay,
    required this.onToggleFavorite,
    this.onDelete,
  });

  final RadioStationDto station;
  final bool playing;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final meta = _metaLine(station);
    final quality = _qualityLabel(station);

    // Same row metrics as the source list: the list is inset by the page
    // gutter minus `sm`, the row adds `sm`, so the icon sits on the gutter.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.md),
        ),
        selected: playing,
        selectedTileColor: colors.accentSoft,
        onTap: onPlay,
        leading: _StationIcon(station: station, playing: playing),
        title: Row(
          children: [
            Expanded(
              child: Text(
                station.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: playing ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (playing) ...[
              const SizedBox(width: LekisSpacing.sm),
              Icon(
                Icons.graphic_eq_rounded,
                size: 18,
                color: colors.accent,
                semanticLabel: context.l10n.pick('正在播放', 'Now playing'),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (meta.isNotEmpty)
              Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (quality != null || station.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    if (quality != null) _Badge(text: quality, highlight: true),
                    if (quality != null && station.tags.isNotEmpty)
                      const SizedBox(width: LekisSpacing.xs),
                    if (station.tags.isNotEmpty)
                      Expanded(
                        child: Text(
                          station.tags.take(3).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 36 dp row actions (like track rows) so custom stations keep
            // room for the name on phones.
            IconButton(
              tooltip: favorite
                  ? context.l10n.pick('取消收藏', 'Remove from favorites')
                  : context.l10n.pick('收藏', 'Favorite'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              icon: Icon(
                favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: favorite ? colors.accent : colors.onSurfaceVariant,
              ),
              onPressed: onToggleFavorite,
            ),
            if (onDelete != null)
              LekisActionMenuButton<String>(
                title: station.name,
                compact: true,

                tooltip: context.l10n.pick('更多', 'More'),
                onSelected: (value) {
                  if (value == 'delete') onDelete!();
                },
                actions: () => [
                  LekisMenuAction(
                    'delete',
                    Icons.delete_outline_rounded,
                    context.l10n.pick('删除自定义电台', 'Delete custom station'),
                    destructive: true,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.highlight = false});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlight
            ? colors.accentSoft
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(LekisRadius.xs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.xs + 2,
          vertical: 1,
        ),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: highlight ? colors.accent : colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _StationIcon extends StatelessWidget {
  const _StationIcon({required this.station, required this.playing});
  final RadioStationDto station;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(LekisRadius.artworkList),
      ),
      child: SizedBox(
        width: LekisSizes.listArtwork,
        height: LekisSizes.listArtwork,
        child: Icon(
          playing ? Icons.graphic_eq_rounded : Icons.radio_rounded,
          color: playing ? colors.accent : colors.onSurfaceVariant,
        ),
      ),
    );
    final favicon = station.favicon;
    if (favicon == null || favicon.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(LekisRadius.artworkList),
      child: SizedBox(
        width: LekisSizes.listArtwork,
        height: LekisSizes.listArtwork,
        child: Image.network(
          favicon,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : fallback,
        ),
      ),
    );
  }
}

String _metaLine(RadioStationDto station) {
  final parts = <String>[];
  if (station.country != null && station.country!.isNotEmpty) {
    parts.add(station.country!);
  }
  if (station.language != null && station.language!.isNotEmpty) {
    parts.add(station.language!);
  }
  return parts.join(' · ');
}

String? _qualityLabel(RadioStationDto station) {
  final codec = station.codec?.trim();
  final bitrate = station.bitrate;
  if (codec != null && codec.isNotEmpty && bitrate != null && bitrate > 0) {
    return '$codec $bitrate';
  }
  if (codec != null && codec.isNotEmpty) return codec;
  if (bitrate != null && bitrate > 0) return '$bitrate kbps';
  return null;
}
