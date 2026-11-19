// 播放会话持久化 + 播放历史。
//
// * [playbackSessionProvider] – 在暂停 / 跳转 / 队列变化 / 退到后台时保存队列、
//   游标、进度、随机 / 循环模式和音量；播放中每 [playbackSaveInterval] 节流保存一次。
//   冷启动后由 `main.dart` 在首帧之后异步恢复，恢复出来的是暂停状态，不会自动出声。
// * [playHistoryProvider] – 按真实播放时长累计（不是进度条位置），越过阈值后调用
//   `core.recordPlay`。同一首歌暂停 / 继续不会重复计数，切歌时重置。
// * [playHistoryRevisionProvider] – 每记一次播放 +1，首页"最近播放"据此刷新。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';

/// 播放中定期落库的间隔。暂停 / 跳转 / 队列变化会立即（防抖 300ms）保存。
const Duration playbackSaveInterval = Duration(seconds: 10);

/// 播放历史阈值：至少听了这么久（或短歌的一半）才算一次播放。
const int playRecordThresholdMs = 5000;

/// 切歌 / 暂停事件可能很密集，保存前等这么久合并一次写库。
const Duration _saveDebounce = Duration(milliseconds: 300);

class PlaybackSessionController with WidgetsBindingObserver {
  PlaybackSessionController(this._ref);

  final Ref _ref;
  Timer? _periodic;
  Timer? _pending;
  bool _saving = false;
  bool _saveAgain = false;
  bool _restored = false;
  bool _restoring = false;
  bool _disposed = false;

  /// 在 Provider 初始化时调用：注册生命周期观察者和状态监听。
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _ref.listen<PlaybackUiState>(playbackProvider, (prev, next) {
      if (prev == null) return;
      // 暂停 / 结束 / 队列变化 / 切歌都值得保存；播放中的进度由定时器负责。
      if (prev.state != next.state ||
          prev.trackId != next.trackId ||
          prev.queueVersion != next.queueVersion ||
          prev.queueLength != next.queueLength) {
        scheduleSave();
      }
    });
    _periodic = Timer.periodic(playbackSaveInterval, (_) {
      final p = _ref.read(playbackProvider);
      if (p.isPlaying && p.hasTrack) {
        unawaited(saveNow());
      }
    });
  }

  /// 冷启动后恢复上次的会话。只调用一次，必须在首帧之后（不阻塞 UI）。
  Future<void> restore() async {
    if (_disposed || _restored) return;
    _restored = true;
    // 用户在启动阶段已经开始播放：以当前队列为准，不要用旧会话覆盖。
    if (_ref.read(playbackProvider).hasTrack) return;
    _restoring = true;
    try {
      final restored = await core.restorePlaybackState();
      if (_disposed || !restored) return;
      debugPrint('playback session restored (paused)');
      // 核心按命令顺序推进，等一拍让 QueueChanged / PlaybackChanged 发出来，
      // 再把 UI provider 对齐到快照（防止首帧早于事件订阅）。
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_disposed) return;
      _ref.invalidate(playbackProvider);
      _ref.invalidate(positionProvider);
      _ref.invalidate(throttledPositionProvider);
    } catch (e) {
      debugPrint('restore playback session failed: $e');
    } finally {
      _restoring = false;
    }
  }

  /// 合并一阵连续的变更后写库。
  void scheduleSave({Duration delay = _saveDebounce}) {
    if (_disposed) return;
    _pending?.cancel();
    _pending = Timer(delay, () => unawaited(saveNow()));
  }

  /// 立即保存当前播放会话。
  Future<void> saveNow() async {
    // 恢复之前不要用空引擎覆盖上次保存的会话；恢复过程中也不要抢写。
    if (_disposed || !_restored || _restoring) return;
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    try {
      await core.savePlaybackState();
    } catch (e) {
      debugPrint('save playback session failed: $e');
    } finally {
      _saving = false;
      if (_saveAgain && !_disposed) {
        _saveAgain = false;
        unawaited(saveNow());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // 退到后台可能很快被系统杀掉，取消防抖直接写。
      scheduleSave(delay: Duration.zero);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _periodic?.cancel();
    _pending?.cancel();
  }
}

final playbackSessionProvider = Provider<PlaybackSessionController>((ref) {
  final controller = PlaybackSessionController(ref);
  controller.start();
  ref.onDispose(controller.dispose);
  return controller;
});

/// 每记一次播放加一，首页"最近播放"监听它刷新。
class PlayHistoryRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final playHistoryRevisionProvider = NotifierProvider<PlayHistoryRevision, int>(
  PlayHistoryRevision.new,
);

class PlayHistoryTracker {
  PlayHistoryTracker(this._ref) {
    _ref.listen<int>(positionProvider, (_, _) => _onTick());
    _ref.listen<PlaybackUiState>(playbackProvider, (_, _) => _onTick());
  }

  final Ref _ref;
  int? _trackId;
  int? _queueIndex;
  int _lastPositionMs = 0;
  int _playedMs = 0;
  bool _recorded = false;
  bool _recording = false;

  void _onTick() {
    final p = _ref.read(playbackProvider);
    final position = _ref.read(positionProvider);

    if (p.trackId != _trackId || p.queueIndex != _queueIndex) {
      _trackId = p.trackId;
      _queueIndex = p.queueIndex;
      _lastPositionMs = position;
      _playedMs = 0;
      _recorded = false;
    } else if (p.state == PlaybackStateDto.idle ||
        p.state == PlaybackStateDto.ended) {
      // 自然播完 / 队列清空：用户重新播放同一首时应该再记一次。
      _playedMs = 0;
      _recorded = false;
      _lastPositionMs = position;
    } else {
      final delta = position - _lastPositionMs;
      // 只累计连续播放的进度；seek、卡顿造成的大跳变不算"听过"。
      if (p.isPlaying && delta > 0 && delta <= 3000) {
        _playedMs += delta;
      }
      _lastPositionMs = position;
    }

    final id = p.trackId;
    if (id == null || _recorded || _recording || !p.isPlaying) return;
    final threshold = p.durationMs > 0
        ? math.min(playRecordThresholdMs, p.durationMs ~/ 2)
        : playRecordThresholdMs;
    if (_playedMs < threshold) return;

    // 先立旗再 await：暂停 / 继续和事件抖动都不会重复计数。
    _recorded = true;
    unawaited(_record(id, _playedMs));
  }

  Future<void> _record(int trackId, int msPlayed) async {
    _recording = true;
    try {
      await core.recordPlay(trackId: trackId, msPlayed: BigInt.from(msPlayed));
      if (_disposed) return;
      _ref.read(playHistoryRevisionProvider.notifier).bump();
    } catch (e) {
      // 曲目已被删除 / 写库失败：这首不再重试，避免每 200ms 报一次错；
      // 切歌后 flags 会重置。
      _recorded = true;
      final message = e is CoreError ? '${e.kind.name}: ${e.detail}' : '$e';
      debugPrint('recordPlay($trackId) failed: $message');
    } finally {
      _recording = false;
    }
  }

  bool _disposed = false;

  void dispose() => _disposed = true;
}

final playHistoryProvider = Provider<PlayHistoryTracker>((ref) {
  final tracker = PlayHistoryTracker(ref);
  ref.onDispose(tracker.dispose);
  return tracker;
});
