import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/lyrics_parser.dart';
import 'package:lekis/src/rust/api/core.dart' as core;

/// Whether Now Playing shows lyrics (compact: instead of the artwork).
/// The desktop player bar sets this before opening Now Playing.
final nowPlayingLyricsVisibleProvider =
    NotifierProvider<SimpleValue<bool>, bool>(() => SimpleValue<bool>(false));

final lyricsProvider = FutureProvider.autoDispose.family<ParsedLyrics?, int>((
  ref,
  trackId,
) async {
  ref.cacheFor(const Duration(minutes: 1));
  final dto = await core.lyrics(trackId: trackId);
  if (dto == null || dto.content.trim().isEmpty) return null;
  final parsed = ParsedLyrics.parse(dto);
  return parsed.isEmpty ? null : parsed;
});
