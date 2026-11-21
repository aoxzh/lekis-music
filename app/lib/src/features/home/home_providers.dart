import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/player/playback_session.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// Items per home shelf.
const int homeShelfLimit = 30;

final recentlyAddedProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(minutes: 5));
  return core.recentlyAdded(limit: homeShelfLimit);
});

/// 首页「最近添加」按专辑展示，避免导入整张专辑时出现一整排重复封面。
final recentlyAddedAlbumsProvider = FutureProvider.autoDispose<List<AlbumDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(minutes: 5));
  return core.listAlbums(
    sort: TrackSortDto.recentlyAdded,
    offset: 0,
    limit: homeShelfLimit,
  );
});

/// 首页"最近播放"：core 的 `recentlyPlayed` 按 `last_played` 倒序，
/// 由播放历史（[playHistoryRevisionProvider]）和资料库变化驱动刷新。
final recentlyPlayedProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.watch(playHistoryRevisionProvider);
  ref.listen<int>(playbackProvider.select((s) => s.trackId ?? -1), (_, _) {
    ref.invalidateSelf();
  });
  ref.cacheFor(const Duration(minutes: 2));
  return core.recentlyPlayed(limit: homeShelfLimit);
});

final mostPlayedProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.invalidateOnCatalogChange();
  ref.cacheFor(const Duration(minutes: 5));
  return core.mostPlayed(limit: homeShelfLimit);
});

/// 首页快捷胶囊展示的真实高频流派（最多 5 个，仅来自 SQLite 真实曲库）。
final homeQuickGenresProvider = FutureProvider.autoDispose<List<GenreCountDto>>(
  (ref) async {
    ref.invalidateOnCatalogChange();
    ref.cacheFor(const Duration(minutes: 5));
    final all = await core.listGenres(limit: 24);
    final valid =
        all
            .where((g) => g.name.trim().isNotEmpty && g.trackCount > 0)
            .toList(growable: false)
          ..sort((a, b) => b.trackCount.compareTo(a.trackCount));
    return valid.take(5).toList(growable: false);
  },
);
