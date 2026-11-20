// 网络电台的数据层（SRC-11）：浏览分页、收藏、自定义、最近播放。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Bridge's own Int64List wrapper (not dart:typed_data's).
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

/// 浏览一页电台。
const int radioPageSize = 50;

/// 热门 / 搜索列表的状态。
@immutable
class RadioBrowseState {
  const RadioBrowseState({
    required this.stations,
    required this.hasMore,
    this.loadingMore = false,
  });

  final List<RadioStationDto> stations;
  final bool hasMore;
  final bool loadingMore;

  RadioBrowseState copyWith({
    List<RadioStationDto>? stations,
    bool? hasMore,
    bool? loadingMore,
  }) => RadioBrowseState(
    stations: stations ?? this.stations,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// 热门 / 搜索列表。
final radioBrowseProvider =
    AsyncNotifierProvider<RadioBrowseNotifier, RadioBrowseState>(
      RadioBrowseNotifier.new,
    );

class RadioBrowseNotifier extends AsyncNotifier<RadioBrowseState> {
  String _search = '';
  String? _countryCode;
  String? _language;
  String? _tag;

  @override
  Future<RadioBrowseState> build() => _firstPage();

  Future<RadioBrowseState> _firstPage() async {
    final page = await core.radioBrowse(
      search: _search,
      countryCode: _countryCode,
      language: _language,
      tag: _tag,
      sort: RadioSortDto.popular,
      offset: 0,
      limit: radioPageSize,
    );
    return RadioBrowseState(stations: page.stations, hasMore: page.hasMore);
  }

  /// 重新搜索 / 应用筛选。
  Future<void> reload({
    required String search,
    String? countryCode,
    String? language,
    String? tag,
  }) async {
    _search = search.trim();
    _countryCode = countryCode;
    _language = language;
    _tag = tag;
    state = const AsyncLoading();
    state = await AsyncValue.guard(_firstPage);
  }

  /// 刷新当前关键词 / 筛选，保留列表直到新结果回来。
  Future<void> refresh() async {
    final next = await AsyncValue.guard(_firstPage);
    if (next.hasValue) state = next;
  }

  /// 追加下一页；失败时保留已有列表并把错误抛给页面提示。
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await core.radioBrowse(
        search: _search,
        countryCode: _countryCode,
        language: _language,
        tag: _tag,
        sort: RadioSortDto.popular,
        offset: current.stations.length,
        limit: radioPageSize,
      );
      final seen = current.stations.map((s) => s.id).toSet();
      final merged = [
        ...current.stations,
        ...page.stations.where((s) => seen.add(s.id)),
      ];
      state = AsyncData(
        RadioBrowseState(stations: merged, hasMore: page.hasMore),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(loadingMore: false));
      rethrow;
    }
  }
}

/// 通用「一个列表」加载器（收藏 / 自定义 / 最近播放）。
class RadioStationsNotifier extends AsyncNotifier<List<RadioStationDto>> {
  RadioStationsNotifier(this._fetch);

  final Future<List<RadioStationDto>> Function() _fetch;

  @override
  Future<List<RadioStationDto>> build() => _fetch();

  Future<void> reload() async {
    state = await AsyncValue.guard(_fetch);
  }
}

final radioFavoritesProvider =
    AsyncNotifierProvider<RadioStationsNotifier, List<RadioStationDto>>(
      () => RadioStationsNotifier(() => core.radioFavorites(limit: 500)),
    );

final radioCustomProvider =
    AsyncNotifierProvider<RadioStationsNotifier, List<RadioStationDto>>(
      () => RadioStationsNotifier(() => core.radioCustom(limit: 500)),
    );

final radioRecentProvider =
    AsyncNotifierProvider<RadioStationsNotifier, List<RadioStationDto>>(
      () => RadioStationsNotifier(() => core.radioRecent(limit: 100)),
    );

/// Radio Browser 的筛选选项；失败时页面用本地兜底列表。
final radioFilterOptionsProvider = FutureProvider<RadioFilterOptionsDto>((
  ref,
) async {
  return core.radioFilterOptions();
});

/// 页面动作。
final radioActionsProvider = Provider<RadioActions>(RadioActions.new);

class RadioActions {
  RadioActions(this._ref);

  final Ref _ref;

  Future<void> playStation(RadioStationDto station) =>
      playStations([station], 0);

  Future<void> playStations(List<RadioStationDto> stations, int start) async {
    if (stations.isEmpty) return;
    await core.radioPlay(
      stationIds: Int64List.fromList([for (final s in stations) s.id]),
      start: start.clamp(0, stations.length - 1),
    );
    _ref.invalidate(radioRecentProvider);
  }

  Future<void> setFavorite(RadioStationDto station, bool favorite) async {
    await core.radioSetFavorite(stationId: station.id, favorite: favorite);
    _ref.invalidate(radioFavoritesProvider);
    _ref.invalidate(radioRecentProvider);
    _ref.invalidate(radioCustomProvider);
  }

  Future<RadioStationDto> addCustom({
    required String name,
    required String address,
    String? homepage,
  }) async {
    final station = await core.radioAddCustom(
      name: name,
      address: address,
      homepage: homepage?.trim().isEmpty == true ? null : homepage,
    );
    _ref.invalidate(radioCustomProvider);
    return station;
  }

  Future<void> deleteCustom(RadioStationDto station) async {
    await core.radioDeleteCustom(stationId: station.id);
    _ref.invalidate(radioCustomProvider);
    _ref.invalidate(radioFavoritesProvider);
    _ref.invalidate(radioRecentProvider);
  }
}
