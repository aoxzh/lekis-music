// Sleep timer (PLY-11): pause playback after a chosen wall-clock duration
// or at the end of the current track ("放完这首").
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_l10n.dart';
import 'player_providers.dart';

enum SleepTimerKind {
  off('off', null),
  endOfTrack('end_of_track', null),
  min15('15', Duration(minutes: 15)),
  min30('30', Duration(minutes: 30)),
  min60('60', Duration(hours: 1)),
  min90('90', Duration(minutes: 90));

  const SleepTimerKind(this.id, this.duration);

  final String id;
  final Duration? duration;

  String get label => switch (this) {
    SleepTimerKind.off => L10n.tr('关闭', 'Off'),
    SleepTimerKind.endOfTrack => L10n.tr('放完这首', 'End of Track'),
    SleepTimerKind.min15 => L10n.tr('15 分钟', '15 min'),
    SleepTimerKind.min30 => L10n.tr('30 分钟', '30 min'),
    SleepTimerKind.min60 => L10n.tr('60 分钟', '60 min'),
    SleepTimerKind.min90 => L10n.tr('90 分钟', '90 min'),
  };
}

class SleepTimerState {
  const SleepTimerState({
    this.kind = SleepTimerKind.off,
    this.endsAt,
    this.armedTrackId,
    this.armedQueueIndex,
  });

  final SleepTimerKind kind;
  final DateTime? endsAt;

  /// 「放完这首」激活时记录的当前曲目；切歌或停止时触发暂停并自动归零。
  final int? armedTrackId;
  final int? armedQueueIndex;

  bool get active => kind != SleepTimerKind.off;

  Duration? get remaining {
    final end = endsAt;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

class SleepTimerNotifier extends Notifier<SleepTimerState> {
  Timer? _timer;
  Timer? _fadeTimer;
  Timer? _endOfTrackWatch;
  double? _fadeFrom;
  double? _expectedVolume;
  bool _fading = false;
  bool _fadeDismissed = false;
  Duration _fadeLength = fadeDuration;

  /// Fade the last few seconds instead of cutting the music off abruptly.
  static const fadeDuration = Duration(seconds: 8);
  static const _fadeTick = Duration(milliseconds: 250);

  @override
  SleepTimerState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _fadeTimer?.cancel();
      _endOfTrackWatch?.cancel();
    });
    ref.listen<(int?, int?)>(
      playbackProvider.select((s) => (s.trackId, s.queueIndex)),
      (_, next) => _onTrackPointerChanged(next.$1, next.$2),
    );
    // 用户在淡出期间手动调音量时，以用户为准：停止淡出但保留定时暂停。
    ref.listen<double>(playbackProvider.select((s) => s.volume), (_, next) {
      if (!_fading) return;
      final expected = _expectedVolume;
      if (expected == null || (next - expected).abs() > 0.02) {
        _cancelFade(restoreVolume: false);
        _fadeDismissed = true;
      }
    });
    return const SleepTimerState();
  }

  void _onTrackPointerChanged(int? nextTrackId, int? nextQueueIndex) {
    if (state.kind != SleepTimerKind.endOfTrack) return;
    final armedTrack = state.armedTrackId;
    final armedIndex = state.armedQueueIndex;
    if (armedTrack == null) {
      // 激活时尚无曲目：记住随后开始播放的第一首，不立即暂停。
      if (nextTrackId != null) {
        _fadeDismissed = false;
        state = SleepTimerState(
          kind: SleepTimerKind.endOfTrack,
          armedTrackId: nextTrackId,
          armedQueueIndex: nextQueueIndex,
        );
        _startEndOfTrackWatch();
      }
      return;
    }
    if (nextTrackId == null) {
      // 播放已停止 / 队列清空：自动关闭定时。
      _stopEndOfTrackWatch();
      _cancelFade(restoreVolume: true);
      state = const SleepTimerState();
      return;
    }
    if (nextTrackId != armedTrack || nextQueueIndex != armedIndex) {
      _stopEndOfTrackWatch();
      _pauseAndRestore();
      state = const SleepTimerState();
    }
  }

  /// 「放完这首」模式：最后几秒按当前进度淡出。用户往后拖进度时取消淡出，
  /// 让这一首重新拥有完整的结尾。
  void _startEndOfTrackWatch() {
    _endOfTrackWatch?.cancel();
    _endOfTrackWatch = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _checkEndOfTrack(),
    );
  }

  void _stopEndOfTrackWatch() {
    _endOfTrackWatch?.cancel();
    _endOfTrackWatch = null;
  }

  void _checkEndOfTrack() {
    if (state.kind != SleepTimerKind.endOfTrack) {
      _stopEndOfTrackWatch();
      return;
    }
    final playback = ref.read(playbackProvider);
    if (!playback.isPlaying || playback.durationMs <= 0) return;
    final remainingMs = (playback.durationMs - ref.read(positionProvider))
        .toInt();
    if (remainingMs <= 0) return;
    final remaining = Duration(milliseconds: remainingMs);
    if (remaining <= fadeDuration) {
      if (!_fading && !_fadeDismissed) {
        _startFade(length: remaining);
      }
    } else if (_fading) {
      // 用户往后拖了进度：取消淡出并恢复音量，等到新的结尾再淡。
      _cancelFade(restoreVolume: true);
      _fadeDismissed = false;
    } else {
      _fadeDismissed = false;
    }
  }

  void set(SleepTimerKind kind) {
    _timer?.cancel();
    _timer = null;
    _stopEndOfTrackWatch();
    _fadeDismissed = false;
    _cancelFade(restoreVolume: true);
    if (kind == SleepTimerKind.off) {
      state = const SleepTimerState();
      return;
    }
    if (kind == SleepTimerKind.endOfTrack) {
      final current = ref.read(playbackProvider);
      state = SleepTimerState(
        kind: SleepTimerKind.endOfTrack,
        armedTrackId: current.trackId,
        armedQueueIndex: current.queueIndex,
      );
      if (current.trackId != null) _startEndOfTrackWatch();
      return;
    }
    final duration = kind.duration!;
    // 倒计时结束前开始淡出；很短的定时器直接暂停。
    final fadeDelay = duration - fadeDuration;
    if (fadeDelay > Duration.zero) {
      _fadeTimer = Timer(fadeDelay, () => _startFade());
    }
    _timer = Timer(duration, _finish);
    state = SleepTimerState(kind: kind, endsAt: DateTime.now().add(duration));
  }

  void _startFade({Duration length = fadeDuration}) {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    if (_fading || _fadeDismissed) return;
    final playback = ref.read(playbackProvider);
    if (!playback.isPlaying || playback.volume <= 0.01) return;
    _fading = true;
    _fadeFrom = playback.volume;
    _fadeLength = length < const Duration(milliseconds: 500)
        ? const Duration(milliseconds: 500)
        : length;
    final startedAt = DateTime.now();
    _fadeTimer = Timer.periodic(_fadeTick, (timer) {
      final fadeFrom = _fadeFrom;
      if (!_fading || fadeFrom == null) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      final t = (elapsed / _fadeLength.inMilliseconds).clamp(0.0, 1.0);
      final volume = (fadeFrom * (1 - t)).clamp(0.0, 1.0);
      _expectedVolume = volume;
      ref.read(playerActionsProvider).fadeVolume(volume);
      if (t >= 1) timer.cancel();
    });
  }

  void _finish() {
    _timer = null;
    _stopEndOfTrackWatch();
    _pauseAndRestore();
    state = const SleepTimerState();
  }

  void _pauseAndRestore() {
    final restore = _fadeFrom;
    final wasFading = _fading;
    _cancelFade(restoreVolume: false);
    ref.read(playerActionsProvider).pause();
    if (wasFading && restore != null) {
      // 暂停后再恢复音量，避免淡出结束时突然“回响”，下次播放也是原音量。
      ref.read(playerActionsProvider).restoreVolume(restore);
    }
  }

  void _cancelFade({required bool restoreVolume}) {
    final from = _fadeFrom;
    final wasFading = _fading;
    _fading = false;
    _expectedVolume = null;
    _fadeFrom = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    if (wasFading && restoreVolume && from != null) {
      ref.read(playerActionsProvider).restoreVolume(from);
    }
  }

  void cancel() => set(SleepTimerKind.off);
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, SleepTimerState>(
      SleepTimerNotifier.new,
    );

/// Moon button in Now Playing: pick a sleep timer without opening Settings.
class SleepTimerButton extends ConsumerWidget {
  const SleepTimerButton({super.key, this.compact = false});

  /// Smaller icon/padding for the player bar's dense action cluster.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider);
    final active = timer.active;
    return PopupMenuButton<SleepTimerKind>(
      tooltip: active
          ? L10n.tr(
              '睡眠定时：${timer.kind.label}',
              'Sleep timer: ${timer.kind.label}',
            )
          : L10n.tr('睡眠定时', 'Sleep timer'),
      iconSize: compact ? 20 : null,
      padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
      icon: Icon(
        active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
      onSelected: (kind) => ref.read(sleepTimerProvider.notifier).set(kind),
      itemBuilder: (context) => [
        for (final kind in SleepTimerKind.values)
          CheckedPopupMenuItem<SleepTimerKind>(
            value: kind,
            checked: kind == timer.kind,
            child: Text(kind.label),
          ),
      ],
    );
  }
}
