// Sleep timer (PLY-11): pause playback after a chosen wall-clock duration.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_providers.dart';

enum SleepTimerKind {
  off('off', '关闭', null),
  min15('15', '15 分钟', Duration(minutes: 15)),
  min30('30', '30 分钟', Duration(minutes: 30)),
  min60('60', '60 分钟', Duration(hours: 1)),
  min90('90', '90 分钟', Duration(minutes: 90));

  const SleepTimerKind(this.id, this.label, this.duration);

  final String id;
  final String label;
  final Duration? duration;
}

class SleepTimerState {
  const SleepTimerState({this.kind = SleepTimerKind.off, this.endsAt});

  final SleepTimerKind kind;
  final DateTime? endsAt;

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
    return const SleepTimerState();
  }

  void set(SleepTimerKind kind) {
    _timer?.cancel();
    _timer = null;
    final duration = kind.duration;
    if (duration == null) {
      state = const SleepTimerState();
      return;
    }
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
