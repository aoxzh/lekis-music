// Playback history: the most recent tracks, newest first.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show LekisRefX;
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

class PlaybackHistoryPage extends ConsumerStatefulWidget {
  const PlaybackHistoryPage({super.key});

  @override
  ConsumerState<PlaybackHistoryPage> createState() =>
      _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends ConsumerState<PlaybackHistoryPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<TrackRowDto> _visibleTracks(List<TrackRowDto> tracks) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return tracks;
    return [
      for (final track in tracks)
        if (track.title.toLowerCase().contains(query) ||
            track.artistLine.toLowerCase().contains(query))
          track,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final history = ref.watch(_historyProvider);
    final loadedTracks = history.value ?? const <TrackRowDto>[];
    final appBarTracks = _visibleTracks(loadedTracks);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pick('播放历史', 'Playback History')),
        actions: [
          IconButton(
            tooltip: l10n.pick('复制列表', 'Copy List'),
            onPressed: appBarTracks.isEmpty
                ? null
                : () => copyTrackListAsText(context, appBarTracks),
            icon: const Icon(Icons.content_copy_rounded),
          ),
        ],
      ),
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
          final visible = _visibleTracks(tracks);
          final activeQuery = _query.trim().isNotEmpty;
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
              if (tracks.length >= 8)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    0,
                    gutter,
                    LekisSpacing.sm,
                  ),
                  child: TextField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: l10n.pick('搜索播放历史', 'Search history'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: activeQuery
                          ? IconButton(
                              tooltip: l10n.pick('清除', 'Clear'),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                              icon: const Icon(Icons.close_rounded),
                            )
                          : null,
                      isDense: true,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(LekisRadius.pill),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              if (visible.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(l10n.pick('没有匹配的播放记录', 'No matching history')),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      gutter - LekisSpacing.sm,
                      0,
                      gutter - LekisSpacing.sm,
                      scrollEndPadding(context),
                    ),
                    itemExtent: TrackTile.extent,
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final track = visible[i];
                      return TrackTile(
                        track: track,
                        onTap: () => actions.playRows(visible, start: i),
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

final _historyProvider = FutureProvider.autoDispose<List<TrackRowDto>>((ref) {
  ref.cacheFor(const Duration(seconds: 30));
  ref.listen<int>(playbackProvider.select((s) => s.trackId ?? -1), (_, _) {
    ref.invalidateSelf();
  });
  return core.recentlyPlayed(limit: 500);
});
