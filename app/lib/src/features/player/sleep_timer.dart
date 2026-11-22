// Sleep timer (PLY-11): pause playback after a chosen wall-clock duration
// or at the end of the current track ("放完这首").
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  SleepTimerState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen<(int?, int?)>(
      playbackProvider.select((s) => (s.trackId, s.queueIndex)),
      (_, next) => _onTrackPointerChanged(next.$1, next.$2),
    );
    return const SleepTimerState();
  }

  void _onTrackPointerChanged(int? nextTrackId, int? nextQueueIndex) {
    if (state.kind != SleepTimerKind.endOfTrack) return;
    final armedTrack = state.armedTrackId;
    final armedIndex = state.armedQueueIndex;
    if (armedTrack == null) {
      // 激活时尚无曲目：记住随后开始播放的第一首，不立即暂停。
      if (nextTrackId != null) {
        state = SleepTimerState(
          kind: SleepTimerKind.endOfTrack,
          armedTrackId: nextTrackId,
          armedQueueIndex: nextQueueIndex,
        );
      }
      return;
    }
    if (nextTrackId == null) {
      // 播放已停止 / 队列清空：自动关闭定时。
      state = const SleepTimerState();
      return;
    }
    if (nextTrackId != armedTrack || nextQueueIndex != armedIndex) {
      ref.read(playerActionsProvider).pause();
      state = const SleepTimerState();
    }
  }

  void set(SleepTimerKind kind) {
    _timer?.cancel();
    _timer = null;
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
      return;
    }
    final duration = kind.duration!;
    _timer = Timer(duration, () {
      ref.read(playerActionsProvider).pause();
      state = const SleepTimerState();
    });
    state = SleepTimerState(kind: kind, endsAt: DateTime.now().add(duration));
  }

  void cancel() => set(SleepTimerKind.off);
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, SleepTimerState>(
      SleepTimerNotifier.new,
    );
