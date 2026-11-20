// Playback history: the most recent tracks, newest first.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class PlaybackHistoryPage extends ConsumerWidget {
  const PlaybackHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('播放历史')),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (tracks) {
          if (tracks.isEmpty) {
            return const Center(child: Text('还没有播放记录'));
          }
          final gutter = pageGutterOf(context);
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(
              gutter - LekisSpacing.sm,
              LekisSpacing.sm,
              gutter - LekisSpacing.sm,
              scrollEndPadding(context),
            ),
            itemExtent: TrackTile.extent,
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final track = tracks[i];
              return TrackTile(
                track: track,
                onTap: () =>
                    ref.read(playerActionsProvider).playRows(tracks, start: i),
              );
            },
          );
        },
      ),
    );
  }
}

final _historyProvider = FutureProvider.autoDispose<List<TrackRowDto>>(
  (ref) => core.recentlyPlayed(limit: 500),
);
