// 正在播放里的收藏 / 评分 / 添加到歌单。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class NowPlayingLibraryActions extends ConsumerWidget {
  const NowPlayingLibraryActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: LekisSpacing.xs,
      children: [
        LovedButton(
          trackId: track.id,
          initialLoved: track.loved,
          size: 24,
          compact: false,
        ),
        RatingStars(
          trackId: track.id,
          initialRating: track.rating?.toInt(),
          size: 22,
          compact: false,
        ),
        TrackDownloadButton(trackId: track.id, compact: false),
        IconButton(
          tooltip: '添加到歌单',
          onPressed: () => showAddToPlaylistSheet(
            context,
            trackId: track.id,
            trackTitle: track.title,
          ),
          icon: const Icon(Icons.playlist_add_rounded),
        ),
      ],
    );
  }
}
