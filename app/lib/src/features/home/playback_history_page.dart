// Playback history: the most recent tracks, newest first.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

class PlaybackHistoryPage extends ConsumerWidget {
  const PlaybackHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(_historyProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pick('播放历史', 'Playback History'))),
      body: history.whenSkeleton(
        skeleton: const SkeletonTrackListView(top: LekisSpacing.sm),
        error: (e, _) =>
            Center(child: Text(l10n.pick('读取失败：$e', 'Failed to load: $e'))),
        data: (tracks) {
          if (tracks.isEmpty) {
            return Center(
              child: Text(l10n.pick('还没有播放记录', 'No playback history yet')),
            );
          }
          final gutter = pageGutterOf(context);
          final actions = ref.read(playerActionsProvider);
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  LekisSpacing.sm,
                  gutter,
                  LekisSpacing.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.pick(
                          '最近 ${tracks.length} 首',
                          '${tracks.length} recent tracks',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.pick('播放全部', 'Play all'),
                      onPressed: () => actions.playRows(tracks),
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                    IconButton(
                      tooltip: l10n.pick('随机播放', 'Shuffle'),
                      onPressed: () => actions.playRows(tracks, shuffle: true),
                      icon: const Icon(Icons.shuffle_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    gutter - LekisSpacing.sm,
                    0,
                    gutter - LekisSpacing.sm,
                    scrollEndPadding(context),
                  ),
                  itemExtent: TrackTile.extent,
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final track = tracks[i];
                    return TrackTile(
                      track: track,
                      onTap: () => actions.playRows(tracks, start: i),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final _historyProvider = FutureProvider.autoDispose<List<TrackRowDto>>(
  (ref) => core.recentlyPlayed(limit: 500),
);
