// Playback state for the whole app.
//
// * [playbackProvider]   – coarse state (track, play/pause, volume, modes).
//                          Changes rarely; safe to watch broadly.
// * [positionProvider]   – raw position in ms, updated on every core tick.
//                          Only ever watch it through `.select(...)` that
//                          collapses to something coarse (e.g. lyric index).
// * [throttledPositionProvider] – position at most every
//                          [positionThrottle]; for sliders / progress bars.
// * [currentTrackProvider], [currentArtworkProvider] – details of the track.
// * [playerActionsProvider] – commands. Widgets never call the core directly.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Bridge's own Int64List wrapper (not dart:typed_data's).
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/player/playback_session.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';

/// UI updates for progress bars happen at most this often.
const Duration positionThrottle = Duration(milliseconds: 250);

@immutable
class PlaybackUiState {
  const PlaybackUiState({
    this.state = PlaybackStateDto.idle,
    this.trackId,
    this.durationMs = 0,
    this.queueLength = 0,
    this.queueIndex,
    this.queueVersion = 0,
    this.volume = 1,
    this.repeat = RepeatModeDto.off,
    this.shuffle = ShuffleModeDto.off,
  });

  final PlaybackStateDto state;
  final int? trackId;
  final int durationMs;
  final int queueLength;
  final int? queueIndex;

  /// Bumped on every queue change so list providers can reload.
  final int queueVersion;
  final double volume;
  final RepeatModeDto repeat;
  final ShuffleModeDto shuffle;

  bool get hasTrack => trackId != null;

  /// "Wants to play" – loading/buffering count as playing so the play/pause
  /// button does not flicker.
  bool get isPlaying =>
      state == PlaybackStateDto.playing ||
      state == PlaybackStateDto.buffering ||
      state == PlaybackStateDto.loading;

  bool get isBuffering =>
      state == PlaybackStateDto.buffering || state == PlaybackStateDto.loading;

  bool get canGoNext =>
      queueIndex != null &&
      (queueIndex! + 1 < queueLength || repeat == RepeatModeDto.all);

  bool get canGoPrevious => hasTrack;

  PlaybackUiState copyWith({
    PlaybackStateDto? state,
    int? Function()? trackId,
    int? durationMs,
    int? queueLength,
    int? Function()? queueIndex,
    int? queueVersion,
    double? volume,
    RepeatModeDto? repeat,
    ShuffleModeDto? shuffle,
  }) {
    return PlaybackUiState(
      state: state ?? this.state,
      trackId: trackId != null ? trackId() : this.trackId,
      durationMs: durationMs ?? this.durationMs,
      queueLength: queueLength ?? this.queueLength,
      queueIndex: queueIndex != null ? queueIndex() : this.queueIndex,
      queueVersion: queueVersion ?? this.queueVersion,
      volume: volume ?? this.volume,
      repeat: repeat ?? this.repeat,
      shuffle: shuffle ?? this.shuffle,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackUiState &&
      other.state == state &&
      other.trackId == trackId &&
      other.durationMs == durationMs &&
      other.queueLength == queueLength &&
      other.queueIndex == queueIndex &&
      other.queueVersion == queueVersion &&
      other.volume == volume &&
      other.repeat == repeat &&
      other.shuffle == shuffle;

  @override
  int get hashCode => Object.hash(
    state,
    trackId,
    durationMs,
    queueLength,
    queueIndex,
    queueVersion,
    volume,
    repeat,
    shuffle,
  );
}

PlaybackSnapshotDto? _safeSnapshot() {
  try {
    return core.playbackSnapshot();
  } catch (e) {
    debugPrint('playbackSnapshot failed: $e');
    return null;
  }
}

class PlaybackController extends Notifier<PlaybackUiState> {
  @override
  PlaybackUiState build() {
    ref.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event is CoreEventDto_PlaybackChanged) {
        state = state.copyWith(
          state: event.state,
          trackId: () => event.trackId,
          durationMs: event.durationMs.toInt(),
        );
      } else if (event is CoreEventDto_QueueChanged) {
        state = state.copyWith(
          queueLength: event.length,
          queueIndex: () => event.currentIndex,
          queueVersion: state.queueVersion + 1,
        );
      } else if (event is CoreEventDto_PlaybackOptionsChanged) {
        state = state.copyWith(
          volume: event.volume,
          repeat: event.repeat,
          shuffle: event.shuffle,
        );
      }
    });

    final snap = _safeSnapshot();
    if (snap == null) return const PlaybackUiState();
    return PlaybackUiState(
      state: snap.state,
      trackId: snap.trackId,
      durationMs: snap.durationMs.toInt(),
      queueLength: snap.queueLen,
      queueIndex: snap.queueIndex,
      volume: snap.volume,
      repeat: snap.repeat,
      shuffle: snap.shuffle,
    );
  }

  // Optimistic updates (the core has no event for these yet).
  void _setVolume(double v) => state = state.copyWith(volume: v);
  void _setRepeat(RepeatModeDto m) => state = state.copyWith(repeat: m);
  void _setShuffle(ShuffleModeDto m) => state = state.copyWith(shuffle: m);
}

final playbackProvider = NotifierProvider<PlaybackController, PlaybackUiState>(
  PlaybackController.new,
);

/// Warm the core's artwork cache for the next queue item while the current
/// track plays. Remote covers then appear without the usual download delay
/// when the queue advances; failures are intentionally ignored.
final artworkPrefetchProvider = Provider<void>((ref) {
  var generation = 0;
  var last = '';
  Timer? delay;
  ref.onDispose(() => delay?.cancel());

  void scheduleNext(PlaybackUiState state, int index) {
    final current = ++generation;
    // Let rapid skips settle: only the track the listener actually dwells on
    // gets its neighbour prefetched. This avoids a burst of cover downloads
    // while the user is scrubbing the queue.
    delay?.cancel();
    delay = Timer(const Duration(milliseconds: 350), () {
      if (current != generation) return;
      unawaited(
        _prefetchNextArtwork(state, index, () => current == generation),
      );
    });
  }

  ref.listen<PlaybackUiState>(playbackProvider, (_, next) {
    final key = '${next.trackId}:${next.queueIndex}';
    if (key == last) return;
    last = key;
    final index = next.queueIndex;
    if (index == null) return;
    scheduleNext(next, index);
  });
});

Future<void> _prefetchNextArtwork(
  PlaybackUiState state,
  int index,
  bool Function() stillCurrent,
) async {
  try {
    if (index + 1 >= state.queueLength) return;
    final rows = await core.queueItems(offset: index + 1, limit: 1);
    if (rows.isEmpty || !stillCurrent()) return;
    await core.artwork(trackId: rows.first.id);
  } catch (_) {
    // Prefetch is best-effort; playback must never depend on it.
  }
}

/// 播放命令失败；根布局监听后弹 SnackBar，并可携带“重试”动作。
///
/// core 的播放命令有的是同步 void，有的是 Future；旧代码用同步 try/catch
/// 包住，异步失败会变成未处理异常，用户只看到“点了没反应”。现在统一上报。
class PlaybackFailure {
  const PlaybackFailure(this.message, {this.retry});

  final String message;
  final VoidCallback? retry;
}

final playbackErrorProvider =
    NotifierProvider<PlaybackErrorNotifier, PlaybackFailure?>(
      PlaybackErrorNotifier.new,
    );

class PlaybackErrorNotifier extends Notifier<PlaybackFailure?> {
  @override
  PlaybackFailure? build() => null;

  void report(PlaybackFailure failure) => state = failure;
  void clear() => state = null;
}

/// Raw position in milliseconds (every core tick).
class PositionController extends Notifier<int> {
  @override
  int build() {
    ref.listen<AsyncValue<CoreEventDto>>(coreEventsProvider, (_, next) {
      final event = next.value;
      if (event is CoreEventDto_PositionTick) {
        state = event.positionMs.toInt();
      } else if (event is CoreEventDto_PlaybackChanged) {
        state = event.positionMs.toInt();
      }
    });
    return _safeSnapshot()?.positionMs.toInt() ?? 0;
  }

  void _seekOptimistic(int ms) => state = ms;
}

final positionProvider = NotifierProvider<PositionController, int>(
  PositionController.new,
);

/// Position for progress UI: emits at most every [positionThrottle], except
/// for jumps (seek / track change) which are forwarded immediately.
class ThrottledPositionController extends Notifier<int> {
  final Stopwatch _sinceEmit = Stopwatch()..start();
  Timer? _trailing;

  @override
  int build() {
    ref.onDispose(() => _trailing?.cancel());
    ref.listen<int>(positionProvider, (_, next) {
      final jump = (next - state).abs() > positionThrottle.inMilliseconds * 4;
      if (jump || _sinceEmit.elapsed >= positionThrottle) {
        _emit(next);
      } else {
        // Make sure the last value (e.g. right before pause) still lands.
        _trailing ??= Timer(positionThrottle - _sinceEmit.elapsed, () {
          _trailing = null;
          _emit(ref.read(positionProvider));
        });
      }
    });
    return ref.read(positionProvider);
  }

  void _emit(int value) {
    _trailing?.cancel();
    _trailing = null;
    _sinceEmit.reset();
    state = value;
  }
}

final throttledPositionProvider =
    NotifierProvider<ThrottledPositionController, int>(
      ThrottledPositionController.new,
    );

/// Progress in 0..1 at the throttled rate.
final progressProvider = Provider<double>((ref) {
  final duration = ref.watch(playbackProvider.select((s) => s.durationMs));
  if (duration <= 0) return 0;
  final pos = ref.watch(throttledPositionProvider);
  return (pos / duration).clamp(0.0, 1.0);
});

final currentTrackProvider = FutureProvider<TrackDto?>((ref) async {
  ref.invalidateOnCatalogChange();
  final id = ref.watch(playbackProvider.select((s) => s.trackId));
  if (id == null) return null;
  return core.getTrack(trackId: id);
});

final currentArtworkProvider = FutureProvider<ArtworkDto?>((ref) async {
  final id = ref.watch(playbackProvider.select((s) => s.trackId));
  if (id == null) return null;
  // Share the row's lookup/cache while a remote cover is being downloaded.
  return ref.watch(trackArtworkProvider(id).future);
});

/// First queue index included in [queuePreviewProvider].
int queuePreviewStart(int length, int? currentIndex) {
  if (length <= 0) return 0;
  return ((currentIndex ?? 0) - 1).clamp(0, length - 1);
}

/// A short window around the current item, for the queue sheet / side panel.
/// The full queue can be huge; the persistent context only needs what is
/// around the cursor.
final queuePreviewProvider = FutureProvider.autoDispose<List<TrackRowDto>>((
  ref,
) async {
  ref.watch(playbackProvider.select((s) => s.queueVersion));
  final length = ref.watch(playbackProvider.select((s) => s.queueLength));
  final index = ref.watch(playbackProvider.select((s) => s.queueIndex));
  if (length == 0) return const [];
  final start = queuePreviewStart(length, index);
  final limit = (length - start).clamp(1, 30);
  return core.queueItems(offset: start, limit: limit);
});

/// The whole playback queue, paged on demand.
///
/// The panel can show a 100k-track queue without loading it all: pages are
/// fetched when rows scroll into view. Rebuilt after every queue change so
/// remove / move operations land immediately.
final queueListProvider = Provider.autoDispose<PagedList<TrackRowDto>>((ref) {
  ref.watch(playbackProvider.select((s) => s.queueVersion));
  final length = ref.watch(playbackProvider.select((s) => s.queueLength));
  final list = PagedList<TrackRowDto>(
    fetch: (offset, limit) => core.queueItems(offset: offset, limit: limit),
    pageSize: 100,
    count: () async => length,
  );
  ref.onDispose(list.dispose);
  return list;
});

/// Commands. All are fire-and-forget; state comes back through events.
class PlayerActions {
  PlayerActions(this._ref);
  final Ref _ref;

  PlaybackController get _playback => _ref.read(playbackProvider.notifier);

  void _guard(String what, FutureOr<void> Function() body) {
    unawaited(() async {
      try {
        await body();
      } catch (e) {
        final message = e is CoreError ? e.detail : '$e';
        debugPrint('player $what failed: $message');
        try {
          _ref
              .read(playbackErrorProvider.notifier)
              .report(
                PlaybackFailure(message, retry: () => _guard(what, body)),
              );
        } catch (_) {
          // The provider can be gone while the app is shutting down.
        }
      }
    }());
  }

  void playPause() {
    final s = _ref.read(playbackProvider);
    if (!s.hasTrack) return;
    _guard('playPause', s.isPlaying ? core.pause : core.play);
    // 暂停是重要的落库时机；播放恢复后由定时器负责。
    if (s.isPlaying) {
      _ref.read(playbackSessionProvider).scheduleSave(delay: Duration.zero);
    }
  }

  void play() => _guard('play', core.play);
  void pause() {
    _guard('pause', core.pause);
    _ref.read(playbackSessionProvider).scheduleSave(delay: Duration.zero);
  }

  /// Clear the queue and stop playback. Uses the same SetQueue bridge path
  /// with an empty list, so no extra FFI API is needed.
  void clearQueue() {
    _guard(
      'clearQueue',
      () => core.playTracks(
        trackIds: Int64List.fromList(const <int>[]),
        start: 0,
      ),
    );
  }

  void next() => _guard('next', core.next);
  void previous() => _guard('previous', core.previous);

  void seek(int positionMs) {
    final duration = _ref.read(playbackProvider).durationMs;
    final ms = duration > 0 ? positionMs.clamp(0, duration) : positionMs;
    _ref.read(positionProvider.notifier)._seekOptimistic(ms);
    _guard('seek', () => core.seek(positionMs: BigInt.from(ms)));
    _ref.read(playbackSessionProvider).scheduleSave();
  }

  void seekRelative(Duration delta) =>
      seek(_ref.read(positionProvider) + delta.inMilliseconds);

  void setVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    _playback._setVolume(v);
    _guard('setVolume', () => core.setVolume(volume: v));
    _ref.read(playbackSessionProvider).scheduleSave();
  }

  /// One step of the sleep-timer fade. Updates the slider and the engine but
  /// does not persist every tick; [restoreVolume] saves the final value.
  void fadeVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    _playback._setVolume(v);
    _guard('fadeVolume', () => core.setVolume(volume: v));
  }

  /// Restore the pre-fade volume after the sleep timer paused playback.
  void restoreVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    _playback._setVolume(v);
    _guard('restoreVolume', () => core.setVolume(volume: v));
    _ref.read(playbackSessionProvider).scheduleSave(delay: Duration.zero);
  }

  void cycleRepeat() {
    final next = switch (_ref.read(playbackProvider).repeat) {
      RepeatModeDto.off => RepeatModeDto.all,
      RepeatModeDto.all => RepeatModeDto.one,
      RepeatModeDto.one => RepeatModeDto.off,
    };
    _playback._setRepeat(next);
    _guard('setRepeat', () => core.setRepeat(mode: next));
    _ref.read(playbackSessionProvider).scheduleSave();
  }

  void toggleShuffle() {
    final on = _ref.read(playbackProvider).shuffle != ShuffleModeDto.off;
    final next = on ? ShuffleModeDto.off : ShuffleModeDto.random;
    _playback._setShuffle(next);
    _guard('setShuffle', () => core.setShuffle(mode: next));
    _ref.read(playbackSessionProvider).scheduleSave();
  }

  /// Replace the queue with [trackIds] and start at [start].
  void playTracks(List<int> trackIds, {int start = 0, bool shuffle = false}) {
    if (trackIds.isEmpty) return;
    if (shuffle) {
      _playback._setShuffle(ShuffleModeDto.random);
      _guard('setShuffle', () => core.setShuffle(mode: ShuffleModeDto.random));
    }
    if (kDebugMode) {
      debugPrint(
        'playTracks request: n=${trackIds.length} start=$start '
        'ids=${trackIds.take(3).toList()}',
      );
    }
    _guard(
      'playTracks',
      () => core.playTracks(
        trackIds: Int64List.fromList(trackIds),
        start: start.clamp(0, trackIds.length - 1),
      ),
    );
    if (kDebugMode) {
      void dump(String when) {
        final snap = _safeSnapshot();
        debugPrint(
          'playTracks $when: state=${snap?.state} track=${snap?.trackId} '
          'queue=${snap?.queueLen} index=${snap?.queueIndex}',
        );
      }

      dump('immediate');
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        () => dump('300ms'),
      );
      Future<void>.delayed(const Duration(seconds: 2), () => dump('2s'));
    }
  }

  void playRows(
    List<TrackRowDto> rows, {
    int start = 0,
    bool shuffle = false,
  }) =>
      playTracks([for (final r in rows) r.id], start: start, shuffle: shuffle);

  /// Play an album from the cover wall. The core expands the album into a
  /// queue itself, so the UI only sends one id even for huge libraries.
  Future<void> playAlbum(int albumId) async {
    await playContext(PlayContextDto.album(albumId: albumId));
  }

  /// 按核心播放上下文开播（资料库随机、收藏、流派、专辑等），支持先开启随机模式。
  Future<bool> playContext(
    PlayContextDto context, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    if (shuffle) {
      _playback._setShuffle(ShuffleModeDto.random);
      _guard('setShuffle', () => core.setShuffle(mode: ShuffleModeDto.random));
    }
    try {
      await core.playContext(context: context, startIndex: startIndex);
      return true;
    } catch (e) {
      final message = e is CoreError ? '${e.kind.name}: ${e.detail}' : '$e';
      debugPrint('player playContext failed: $message');
      try {
        _ref
            .read(playbackErrorProvider.notifier)
            .report(
              PlaybackFailure(
                e is CoreError ? e.detail : message,
                retry: () => playContext(
                  context,
                  startIndex: startIndex,
                  shuffle: shuffle,
                ),
              ),
            );
      } catch (_) {
        // The provider can be gone while the app is shutting down.
      }
      return false;
    }
  }

  /// Jump to queue row [index].
  ///
  /// The bridge has no `play_queue_index` yet. For queues up to 500 rows the
  /// complete queue is rebuilt and playback starts at the tapped row; larger
  /// queues restart from a bounded window beginning at that row (the earlier
  /// history is dropped) instead of materialising 100k ids in Dart.
  Future<void> playQueueAt(int index) async {
    final length = _ref.read(playbackProvider).queueLength;
    if (length == 0) return;
    final target = index.clamp(0, length - 1);
    try {
      if (length <= 500) {
        final rows = await core.queueItems(offset: 0, limit: length);
        if (rows.isEmpty) return;
        playTracks([for (final row in rows) row.id], start: target);
        return;
      }
      final rows = await core.queueItems(offset: target, limit: 500);
      if (rows.isEmpty) return;
      playTracks([for (final row in rows) row.id], start: 0);
    } catch (e) {
      final message = e is CoreError ? '${e.kind.name}: ${e.detail}' : '$e';
      debugPrint('player playQueueAt failed: $message');
    }
  }

  void removeQueueAt(int index) =>
      _guard('queueRemove', () => core.queueRemove(index: index));

  void moveQueueItem(int from, int to) {
    if (from == to) return;
    _guard('queueMove', () => core.queueMove(from: from, to: to));
  }

  /// 把整个文件夹放进队列并从头播放（目录可以大于内存里的已加载窗口）。
  Future<bool> playFolder(int sourceId, String path) async {
    try {
      await core.playContext(
        context: PlayContextDto.folder(sourceId: sourceId, path: path),
        startIndex: 0,
      );
      return true;
    } catch (e) {
      final message = e is CoreError ? '${e.kind.name}: ${e.detail}' : '$e';
      debugPrint('player playFolder failed: $message');
      return false;
    }
  }

  Future<void> setLoved(int trackId, bool loved) async {
    try {
      await core.setLoved(trackId: trackId, loved: loved);
    } catch (e) {
      debugPrint('setLoved failed: $e');
    }
  }
}

final playerActionsProvider = Provider<PlayerActions>(PlayerActions.new);
