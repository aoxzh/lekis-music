import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Artwork of the current track; cross-fades on track change.
class CurrentArtwork extends ConsumerWidget {
  const CurrentArtwork({super.key, this.radius});

  final double? radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hash = ref.watch(currentArtworkProvider).value?.hash;
    final track = ref.watch(currentTrackProvider).value;
    return AnimatedSwitcher(
      duration: LekisMotion.normal,
      child: ArtworkImage(
        key: ValueKey(hash),
        hash: hash,
        radius: radius,
        placeholderSeed: track?.id.hashCode ?? 0,
        placeholderLabel: track?.title,
      ),
    );
  }
}

/// Title + artist of the current track.
class CurrentTrackText extends ConsumerWidget {
  const CurrentTrackText({
    super.key,
    this.titleStyle,
    this.subtitleStyle,
    this.alignment = CrossAxisAlignment.start,
  });

  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final track = ref.watch(currentTrackProvider).value;
    final title = track?.title ?? '未在播放';
    final subtitle = track == null
        ? ''
        : [
            track.artists.join(' / '),
            ?track.albumTitle,
          ].where((s) => s.isNotEmpty).join(' — ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle ?? theme.textTheme.titleSmall,
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                subtitleStyle ??
                theme.textTheme.bodySmall?.copyWith(
                  color: context.lekisColors.onSurfaceVariant,
                ),
          ),
      ],
    );
  }
}
