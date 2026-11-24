import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;

/// What the main Now Playing area shows. On wide windows `lyrics` and
/// `queue` move to the third pane next to cover + controls; on compact
/// windows they replace the cover (the queue opens as a bottom sheet).
enum NowPlayingPane { cover, wall, lyrics, queue, dial }

/// Currently selected Now Playing pane. The desktop player bar sets
/// [NowPlayingPane.lyrics] before opening the page.
final nowPlayingPaneProvider =
    NotifierProvider<SimpleValue<NowPlayingPane>, NowPlayingPane>(
      () => SimpleValue<NowPlayingPane>(NowPlayingPane.cover),
    );

final lyricsProvider = FutureProvider.autoDispose.family<ParsedLyrics?, int>((
  ref,
  trackId,
) async {
  ref.cacheFor(const Duration(minutes: 1));
  final dto = await core.lyrics(trackId: trackId);
  if (dto == null || dto.content.trim().isEmpty) return null;
  final parsed = ParsedLyrics.parse(dto);
  return parsed.isEmpty ? null : parsed;
}, retry: (retryCount, error) => null);

/// While the lyrics pane is open, quietly fetch the next queue item's lyrics
/// so switching tracks does not always start with a spinner. Only the next
/// item is prefetched, and failures are ignored.
final lyricsPrefetchProvider = Provider.autoDispose<void>((ref) {
  var generation = 0;

  Future<void> prefetch(PlaybackUiState state) async {
    final index = state.queueIndex;
    if (index == null || index + 1 >= state.queueLength) return;
    final current = ++generation;
    try {
      final rows = await core.queueItems(offset: index + 1, limit: 1);
      if (rows.isEmpty || current != generation) return;
      final provider = lyricsProvider(rows.first.id);
      final sub = ref.listen(provider, (_, _) {});
      try {
        await ref.read(provider.future);
      } finally {
        sub.close();
      }
    } catch (_) {
      // Prefetch is best-effort; the visible lyrics still load normally.
    }
  }

  ref.listen<PlaybackUiState>(playbackProvider, (_, next) {
    unawaited(prefetch(next));
  });
  unawaited(prefetch(ref.read(playbackProvider)));
});
