// 播客的数据层（SRC-12）：核心 API 的薄封装 + Riverpod 状态。
//
// 页面只通过 [podcastApiProvider] 访问核心，测试里可以换成假的实现。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Bridge's own Int64List wrapper (not dart:typed_data's).
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/podcast.dart' as rust;

export 'package:lekis/src/rust/api/podcast.dart'
    show
        DirectoryPodcastDto,
        PodcastDto,
        PodcastEpisodeDto,
        OpmlImportReportDto,
        PodcastRefreshReportDto;

/// 一页单集。
const int podcastEpisodePageSize = 50;

/// 目录一次取多少条。
const int podcastDirectoryLimit = 100;

/// 核心播客 API（可在测试里替换）。
abstract class PodcastApi {
  Future<List<rust.DirectoryPodcastDto>> search(String term, String country);
  Future<List<rust.DirectoryPodcastDto>> top(String country, int? genreId);
  Future<rust.PodcastDto> openDirectory(rust.DirectoryPodcastDto podcast);
  Future<rust.PodcastDto> openFeed(String address);
  Future<rust.PodcastDto> get(int id);
  Future<rust.PodcastDto> refresh(int id);
  Future<rust.PodcastRefreshReportDto> refreshAll();
  Future<void> setSubscribed(int id, bool subscribed);
  Future<List<rust.PodcastDto>> subscriptions();
  Future<List<rust.PodcastEpisodeDto>> episodes(int id, int offset, int limit);
  Future<List<rust.PodcastEpisodeDto>> latest(int limit);
  Future<List<rust.PodcastEpisodeDto>> inProgress(int limit);
  Future<void> setPlayed(int episodeId, bool played);
  Future<void> markAllPlayed(int podcastId);
  Future<void> play(List<rust.PodcastEpisodeDto> episodes, int start);
  Future<rust.OpmlImportReportDto> importOpml(String text);
  Future<String> exportOpml();
  Future<String?> loadRegion();
  Future<void> saveRegion(String region);
}

class RustPodcastApi implements PodcastApi {
  const RustPodcastApi();

  static const _regionKey = 'podcast.region';

  @override
  Future<List<rust.DirectoryPodcastDto>> search(String term, String country) =>
      rust.podcastSearch(
        term: term,
        country: country,
        limit: podcastDirectoryLimit,
      );

  @override
  Future<List<rust.DirectoryPodcastDto>> top(String country, int? genreId) =>
      rust.podcastTop(
        country: country,
        genreId: genreId,
        limit: podcastDirectoryLimit,
      );

  @override
  Future<rust.PodcastDto> openDirectory(rust.DirectoryPodcastDto podcast) =>
      rust.podcastOpenDirectory(
        itunesId: podcast.itunesId,
        feedUrl: podcast.feedUrl,
      );

  @override
  Future<rust.PodcastDto> openFeed(String address) =>
      rust.podcastOpenFeed(address: address);

  @override
  Future<rust.PodcastDto> get(int id) => rust.podcastGet(podcastId: id);

  @override
  Future<rust.PodcastDto> refresh(int id) => rust.podcastRefresh(podcastId: id);

  @override
  Future<rust.PodcastRefreshReportDto> refreshAll() => rust.podcastRefreshAll();

  @override
  Future<void> setSubscribed(int id, bool subscribed) =>
      rust.podcastSetSubscribed(podcastId: id, subscribed: subscribed);

  @override
  Future<List<rust.PodcastDto>> subscriptions() => rust.podcastSubscriptions();

  @override
  Future<List<rust.PodcastEpisodeDto>> episodes(
    int id,
    int offset,
    int limit,
  ) => rust.podcastEpisodes(podcastId: id, offset: offset, limit: limit);

  @override
  Future<List<rust.PodcastEpisodeDto>> latest(int limit) =>
      rust.podcastLatestEpisodes(limit: limit);

  @override
  Future<List<rust.PodcastEpisodeDto>> inProgress(int limit) =>
      rust.podcastInProgress(limit: limit);

  @override
  Future<void> setPlayed(int episodeId, bool played) =>
      rust.podcastSetPlayed(episodeId: episodeId, played: played);

  @override
  Future<void> markAllPlayed(int podcastId) =>
      rust.podcastMarkAllPlayed(podcastId: podcastId);

  @override
  Future<void> play(List<rust.PodcastEpisodeDto> episodes, int start) async {
    if (episodes.isEmpty) return;
    await rust.podcastPlay(
      episodeIds: Int64List.fromList([for (final e in episodes) e.id]),
      start: start.clamp(0, episodes.length - 1),
    );
  }

  @override
  Future<rust.OpmlImportReportDto> importOpml(String text) =>
      rust.podcastImportOpml(text: text);

  @override
  Future<String> exportOpml() => rust.podcastExportOpml();

  @override
  Future<String?> loadRegion() => core.getSetting(key: _regionKey);

  @override
  Future<void> saveRegion(String region) =>
      core.setSetting(key: _regionKey, value: region);
}

final podcastApiProvider = Provider<PodcastApi>(
  (ref) => const RustPodcastApi(),
);

/// 正在播放的曲目 ID（单集是负数合成 ID）。单独成一个 Provider，测试里可以覆盖。
final podcastNowPlayingTrackIdProvider = Provider<int?>(
  (ref) => ref.watch(playbackProvider.select((s) => s.trackId)),
);

/// 系统地区对应的默认目录地区（不在列表里时用中国大陆）。
@visibleForTesting
String defaultPodcastRegion([String? countryCode]) {
  final code = (countryCode ?? PlatformDispatcher.instance.locale.countryCode)
      ?.toUpperCase();
  if (code != null && podcastRegions.any((r) => r.$1 == code)) return code;
  return 'CN';
}

/// 当前目录地区（持久化到核心设置）。
final podcastRegionProvider = NotifierProvider<PodcastRegionNotifier, String>(
  PodcastRegionNotifier.new,
);

class PodcastRegionNotifier extends Notifier<String> {
  @override
  String build() {
    _restore();
    return defaultPodcastRegion();
  }

  Future<void> _restore() async {
    try {
      final saved = await ref.read(podcastApiProvider).loadRegion();
      if (saved != null && saved.length == 2 && saved != state) {
        state = saved.toUpperCase();
      }
    } catch (_) {
      // 设置读不到就用默认地区。
    }
  }

  Future<void> set(String region) async {
    state = region;
    try {
      await ref.read(podcastApiProvider).saveRegion(region);
    } catch (_) {}
  }
}

/// 排行榜分类（`null` 表示全部）。
final podcastGenreProvider = NotifierProvider<PodcastGenreNotifier, int?>(
  PodcastGenreNotifier.new,
);

class PodcastGenreNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? genre) => state = genre;
}

/// 当前地区 + 分类的排行榜。
final podcastTopProvider = FutureProvider<List<rust.DirectoryPodcastDto>>((
  ref,
) {
  final region = ref.watch(podcastRegionProvider);
  final genre = ref.watch(podcastGenreProvider);
  return ref.read(podcastApiProvider).top(region, genre);
});

/// 搜索关键词（空串表示显示排行榜）。
final podcastSearchTermProvider =
    NotifierProvider<PodcastSearchTermNotifier, String>(
      PodcastSearchTermNotifier.new,
    );

class PodcastSearchTermNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String term) => state = term.trim();
}

final podcastSearchProvider = FutureProvider<List<rust.DirectoryPodcastDto>>((
  ref,
) {
  final term = ref.watch(podcastSearchTermProvider);
  if (term.isEmpty) return Future.value(const []);
  final region = ref.watch(podcastRegionProvider);
  return ref.read(podcastApiProvider).search(term, region);
});

final podcastSubscriptionsProvider = FutureProvider<List<rust.PodcastDto>>(
  (ref) => ref.read(podcastApiProvider).subscriptions(),
);

final podcastLatestProvider = FutureProvider<List<rust.PodcastEpisodeDto>>(
  (ref) => ref.read(podcastApiProvider).latest(30),
);

final podcastInProgressProvider = FutureProvider<List<rust.PodcastEpisodeDto>>(
  (ref) => ref.read(podcastApiProvider).inProgress(20),
);

final podcastDetailProvider = FutureProvider.family<rust.PodcastDto, int>(
  (ref, id) => ref.read(podcastApiProvider).get(id),
);

/// 节目详情页的单集列表（分页）。
@immutable
class PodcastEpisodesState {
  const PodcastEpisodesState({
    required this.episodes,
    required this.hasMore,
    this.loadingMore = false,
  });

  final List<rust.PodcastEpisodeDto> episodes;
  final bool hasMore;
  final bool loadingMore;
}

final podcastEpisodesProvider =
    AsyncNotifierProvider.family<
      PodcastEpisodesNotifier,
      PodcastEpisodesState,
      int
    >(PodcastEpisodesNotifier.new);

class PodcastEpisodesNotifier extends AsyncNotifier<PodcastEpisodesState> {
  PodcastEpisodesNotifier(this.podcastId);

  final int podcastId;

  @override
  Future<PodcastEpisodesState> build() async {
    final list = await ref
        .read(podcastApiProvider)
        .episodes(podcastId, 0, podcastEpisodePageSize);
    return PodcastEpisodesState(
      episodes: list,
      hasMore: list.length >= podcastEpisodePageSize,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(
      PodcastEpisodesState(
        episodes: current.episodes,
        hasMore: true,
        loadingMore: true,
      ),
    );
    try {
      final next = await ref
          .read(podcastApiProvider)
          .episodes(podcastId, current.episodes.length, podcastEpisodePageSize);
      state = AsyncData(
        PodcastEpisodesState(
          episodes: [...current.episodes, ...next],
          hasMore: next.length >= podcastEpisodePageSize,
        ),
      );
    } catch (e) {
      state = AsyncData(current);
      rethrow;
    }
  }
}

/// 页面动作：调用核心后刷新相关列表。
final podcastActionsProvider = Provider<PodcastActions>(PodcastActions.new);

class PodcastActions {
  PodcastActions(this._ref);

  final Ref _ref;

  PodcastApi get _api => _ref.read(podcastApiProvider);

  void _invalidateLists({int? podcastId}) {
    _ref.invalidate(podcastSubscriptionsProvider);
    _ref.invalidate(podcastLatestProvider);
    _ref.invalidate(podcastInProgressProvider);
    if (podcastId != null) {
      _ref.invalidate(podcastDetailProvider(podcastId));
      _ref.invalidate(podcastEpisodesProvider(podcastId));
    }
  }

  Future<rust.PodcastDto> openDirectory(rust.DirectoryPodcastDto p) =>
      _api.openDirectory(p);

  Future<rust.PodcastDto> openFeed(String address) => _api.openFeed(address);

  Future<void> setSubscribed(int podcastId, bool subscribed) async {
    await _api.setSubscribed(podcastId, subscribed);
    _invalidateLists(podcastId: podcastId);
    _ref.invalidate(podcastTopProvider);
    _ref.invalidate(podcastSearchProvider);
  }

  Future<void> refresh(int podcastId) async {
    await _api.refresh(podcastId);
    _invalidateLists(podcastId: podcastId);
  }

  Future<rust.PodcastRefreshReportDto> refreshAll() async {
    final report = await _api.refreshAll();
    _invalidateLists();
    return report;
  }

  Future<void> play(List<rust.PodcastEpisodeDto> episodes, int start) async {
    await _api.play(episodes, start);
    _ref.invalidate(podcastInProgressProvider);
  }

  Future<void> setPlayed(rust.PodcastEpisodeDto episode, bool played) async {
    await _api.setPlayed(episode.id, played);
    _invalidateLists(podcastId: episode.podcastId);
  }

  Future<void> markAllPlayed(int podcastId) async {
    await _api.markAllPlayed(podcastId);
    _invalidateLists(podcastId: podcastId);
  }

  Future<rust.OpmlImportReportDto> importOpml(String text) async {
    final report = await _api.importOpml(text);
    _invalidateLists();
    return report;
  }

  Future<String> exportOpml() => _api.exportOpml();
}
