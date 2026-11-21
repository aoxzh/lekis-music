// 歌单封面：用户选过图就显示那张图，否则是按歌单类型的图标方块。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class PlaylistCover extends ConsumerWidget {
  const PlaylistCover({
    super.key,
    required this.playlist,
    required this.size,
    required this.radius,
    required this.iconSize,
  });

  final PlaylistDto playlist;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artworkId = playlist.artworkId;
    final hash = artworkId == null
        ? null
        : ref.watch(artworkByIdProvider(artworkId.toInt())).value?.hash;
    if (hash != null) {
      return SizedBox.square(
        dimension: size,
        child: ArtworkImage(hash: hash, radius: radius),
      );
    }
    final colors = context.lekisColors;
    final smart = playlist.kind == PlaylistKindDto.smart;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: smart
            ? colors.accentSoft
            : colors.surfaceVariant.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        smart ? Icons.auto_awesome_rounded : Icons.queue_music_rounded,
        size: iconSize,
        color: smart ? colors.accent : colors.onSurfaceVariant,
      ),
    );
  }
}
