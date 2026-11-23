import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/rust/api/core.dart' as core;

/// What the main Now Playing area shows. On wide windows `lyrics` and
/// `queue` move to the third pane next to cover + controls; on compact
/// windows they replace the cover (the queue opens as a bottom sheet).
enum NowPlayingPane { cover, wall, lyrics, queue }

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
