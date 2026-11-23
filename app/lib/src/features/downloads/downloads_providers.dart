// 离线下载的 Riverpod 状态。
//
// * 下载列表只在打开下载页 / 设置页时加载一次；
// * 进度靠核心的 `OfflineProgress` 事件更新内存里的字节数，不轮询数据库；
// * 入队 / 完成 / 失败 / 删除等状态变化才重新拉一次列表（150ms 合并）。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/downloads/downloads_models.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';

class DownloadsController extends AsyncNotifier<DownloadsState> {
  Timer? _reload;
  bool _disposed = false;

  @override
  Future<DownloadsState> build() async {
    ref.onDispose(() {
      _disposed = true;
      _reload?.cancel();
    });
    ref.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, _onEvent);
    return _load();
  }

  void _onEvent(AsyncValue<CoreEventDto>? _, AsyncValue<CoreEventDto> next) {
    final event = next.value;
    if (event == null) return;
    if (event is CoreEventDto_OfflineProgress) {
      final current = state.value;
      if (current == null) {
        _scheduleReload();
        return;
      }
      final updated = current.withProgress(
        event.trackId,
        event.downloaded.toInt(),
        event.total?.toInt(),
      );
      if (!identical(updated, current)) state = AsyncData(updated);
      if (current.entryFor(event.trackId) == null) _scheduleReload();
    } else if (event is CoreEventDto_OfflineChanged ||
        event is CoreEventDto_OfflineRemoved) {
      _scheduleReload();
    }
  }

  void _scheduleReload() {
    if (_disposed) return;
    _reload?.cancel();
    _reload = Timer(const Duration(milliseconds: 150), () {
      unawaited(_refreshQuietly());
    });
  }

  Future<DownloadsState> _load({DownloadsState? previous}) async {
    final downloads = await core.offlineDownloads();
    final stats = await core.offlineStats();

    // Progress events refresh the list often while several downloads run.
    // Reuse the metadata already on screen and only resolve new track ids,
    // eight at a time, instead of firing one bridge call per download.
    final known = <int, TrackDto?>{
      for (final entry in previous?.entries ?? const <DownloadEntry>[])
        entry.trackId: entry.track,
    };
    final tracks = <int, TrackDto?>{};
    final missing = <int>[];
    for (final download in downloads) {
      final id = download.trackId;
      if (known.containsKey(id)) {
        tracks[id] = known[id];
      } else {
        missing.add(id);
      }
    }
    const batchSize = 8;
    for (var start = 0; start < missing.length; start += batchSize) {
      await Future.wait([
        for (final trackId in missing.skip(start).take(batchSize))
          () async {
            try {
              tracks[trackId] = await core.getTrack(trackId: trackId);
            } catch (e) {
              debugPrint('download track $trackId unavailable: $e');
              tracks[trackId] = null;
            }
          }(),
      ]);
    }
    return DownloadsState(
      entries: buildDownloadEntries(downloads: downloads, tracks: tracks),
      readyCount: stats.count.toInt(),
      totalBytes: stats.bytes.toInt(),
    );
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_load);
    if (!_disposed) state = next;
  }

  Future<void> _refreshQuietly() async {
    try {
      final data = await _load(previous: state.value);
      if (!_disposed) state = AsyncData(data);
    } catch (e) {
      debugPrint('refresh downloads failed: $e');
    }
  }

  /// 加入下载队列；返回核心接受的条数。
  Future<int> downloadTracks(List<int> trackIds) async {
    if (trackIds.isEmpty) return 0;
    final count = await core.downloadTracks(
      trackIds: Int64List.fromList(trackIds),
    );
    await _refreshQuietly();
    return count;
  }

  Future<void> downloadTrack(int trackId) async {
    await core.downloadTrack(trackId: trackId);
    await _refreshQuietly();
  }

  Future<void> removeDownload(int trackId) async {
    await core.removeDownload(trackId: trackId);
    await _refreshQuietly();
  }

  /// Delete every completed offline file and refresh the list once. Returns
  /// how many downloads were removed.
  Future<int> clearCompleted() async {
    final entries = state.value?.ready.toList() ?? const <DownloadEntry>[];
    if (entries.isEmpty) return 0;
    for (final entry in entries) {
      await core.removeDownload(trackId: entry.trackId);
    }
    await _refreshQuietly();
    return entries.length;
  }

  /// Drop failed download records so the list only shows actionable items.
  Future<int> clearFailed() async {
    final entries = state.value?.failed.toList() ?? const <DownloadEntry>[];
    if (entries.isEmpty) return 0;
    for (final entry in entries) {
      await core.removeDownload(trackId: entry.trackId);
    }
    await _refreshQuietly();
    return entries.length;
  }

  Future<void> retry(int trackId) => downloadTrack(trackId);

  /// Re-queue every failed download in one pass. Returns how many were
  /// accepted; the list refresh afterwards reflects anything still failing.
  Future<int> retryFailed() async {
    final entries = state.value?.failed.toList() ?? const <DownloadEntry>[];
    if (entries.isEmpty) return 0;
    var retried = 0;
    for (final entry in entries) {
      try {
        await core.downloadTrack(trackId: entry.trackId);
        retried++;
      } catch (e) {
        debugPrint('retry download ${entry.trackId} failed: $e');
      }
    }
    await _refreshQuietly();
    return retried;
  }

  void playDownloaded(int trackId) {
    ref.read(playerActionsProvider).playTracks([trackId]);
  }
}

final downloadsProvider =
    AsyncNotifierProvider<DownloadsController, DownloadsState>(
      DownloadsController.new,
    );

/// 某首歌的下载状态（列表行 / 正在播放用）。只随状态变化重建。
final downloadStateProvider = Provider.autoDispose
    .family<OfflineStateDto?, int>((ref, id) {
      return ref.watch(downloadsProvider).value?.entryFor(id)?.state;
    });

/// 正在下载曲目的 0..1 进度；其他状态返回 `null`。
final downloadProgressProvider = Provider.autoDispose.family<double?, int>((
  ref,
  id,
) {
  final entry = ref.watch(downloadsProvider).value?.entryFor(id);
  if (entry == null || !entry.isActive) return null;
  return entry.progress;
});

/// 设置页 / 角标用的轻量汇总。值不变时不会因为进度 tick 重建界面。
typedef DownloadsSummary = ({int readyCount, int totalBytes, int activeCount});

final downloadsSummaryProvider = Provider<DownloadsSummary>((ref) {
  final state = ref.watch(downloadsProvider).value;
  return (
    readyCount: state?.readyCount ?? 0,
    totalBytes: state?.totalBytes ?? 0,
    activeCount: state?.active.where((e) => e.isActive).length ?? 0,
  );
});
