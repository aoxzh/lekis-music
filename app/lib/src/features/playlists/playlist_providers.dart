// 歌单数据层：普通歌单 + 智能歌单。
//
// 所有写操作都由 core 完成并发出 `LibraryChanged(playlists)`，这里只监听
// 事件刷新缓存，不自己维护第二份歌单状态。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

const int _pageSize = 500;

/// 歌单列表 / 详情 / 条目缓存。
void _watchPlaylistChange(Ref ref, {bool userState = false}) {
  ref.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, (_, next) {
    final event = next.value;
    if (event is! CoreEventDto_LibraryChanged) return;
    if (event.scope == LibraryScopeDto.playlists ||
        (userState && event.scope == LibraryScopeDto.userState)) {
      ref.invalidateSelf();
    }
  });
}

/// 所有歌单（普通 + 智能），按名称排序。
final playlistsProvider = FutureProvider.autoDispose<List<PlaylistDto>>((
  ref,
) async {
  _watchPlaylistChange(ref);
  ref.cacheFor(const Duration(seconds: 30));
  return core.listPlaylists();
});

/// 单个歌单元数据。
final playlistProvider = FutureProvider.autoDispose.family<PlaylistDto, int>((
  ref,
  id,
) async {
  _watchPlaylistChange(ref);
  ref.cacheFor(const Duration(seconds: 30));
  return core.getPlaylist(playlistId: id);
});

/// 普通歌单的全部条目。智能歌单返回空（内容由规则实时求值）。
///
/// 歌单通常只有几百首；为了拖动排序一次拿全，最多加载 10000 条。
final playlistEntriesProvider = FutureProvider.autoDispose
    .family<List<PlaylistEntryDto>, int>((ref, id) async {
      _watchPlaylistChange(ref);
      ref.cacheFor(const Duration(minutes: 1));
      final playlist = await core.getPlaylist(playlistId: id);
      if (playlist.kind == PlaylistKindDto.smart) return const [];

      final out = <PlaylistEntryDto>[];
      var offset = 0;
      while (out.length < playlist.trackCount && out.length < 10000) {
        final rows = await core.playlistItems(
          playlistId: id,
          offset: offset,
          limit: _pageSize,
        );
        out.addAll(rows);
        if (rows.length < _pageSize) break;
        offset += rows.length;
      }
      return out;
    });

/// 智能歌单当前求值结果（详情页预览 / 列表）。
final smartPlaylistTracksProvider = FutureProvider.autoDispose
    .family<List<TrackRowDto>, int>((ref, id) async {
      _watchPlaylistChange(ref, userState: true);
      ref.cacheFor(const Duration(minutes: 1));
      const cap = 5000;
      final out = <TrackRowDto>[];
      var offset = 0;
      while (out.length < cap) {
        final rows = await core.smartPlaylistTracks(
          playlistId: id,
          offset: offset,
          limit: _pageSize,
        );
        out.addAll(rows);
        if (rows.length < _pageSize) break;
        offset += rows.length;
      }
      return out;
    });

/// 歌单规则；普通歌单为 `None`。
final playlistRulesProvider = FutureProvider.autoDispose
    .family<SmartRulesDto?, int>((ref, id) async {
      _watchPlaylistChange(ref, userState: true);
      ref.cacheFor(const Duration(minutes: 1));
      return core.getPlaylistRules(playlistId: id);
    });

/// 某个曲目是否已经在歌单里（避免重复添加）。
///
/// 桥接层没有"按 uid 查条目"的接口，但歌单条目数有限；这里按页扫描，
/// 和详情页使用同一套 `playlistItems` 数据。
Future<bool> playlistContainsTrack(int playlistId, String trackUid) async {
  var offset = 0;
  while (true) {
    final rows = await core.playlistItems(
      playlistId: playlistId,
      offset: offset,
      limit: _pageSize,
    );
    if (rows.any((e) => e.trackUid == trackUid)) return true;
    if (rows.length < _pageSize || offset > 10000) return false;
    offset += rows.length;
  }
}

/// 删除歌单。
Future<void> deletePlaylistById(int id) async {
  await core.deletePlaylist(playlistId: id);
}
