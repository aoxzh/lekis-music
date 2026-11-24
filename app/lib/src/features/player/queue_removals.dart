import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/error.dart';
import 'package:material_ui/material_ui.dart';

final queueRemoveCommandProvider = Provider<void Function(int)>(
  (ref) =>
      (index) => core.queueRemove(index: index),
);

final queueRemovalsProvider = NotifierProvider<QueueRemovals, Set<int>>(
  QueueRemovals.new,
);

class QueueRemovals extends Notifier<Set<int>> {
  final _acknowledged = <int, Set<int>>{};

  @override
  Set<int> build() {
    ref.listen(playbackProvider, (previous, next) {
      if (previous == null || previous.queueVersion == next.queueVersion) {
        return;
      }
      final count = previous.queueLength - next.queueLength;
      final confirmed = count > 0 ? state.take(count).toSet() : <int>{};
      final cursor = previous.queueIndex;
      final nextCursor = cursor == null || next.queueLength == 0
          ? null
          : _after(cursor, confirmed).clamp(0, next.queueLength - 1);
      if (next.queueVersion != previous.queueVersion + 1 ||
          confirmed.isEmpty ||
          count != confirmed.length ||
          next.queueIndex != nextCursor) {
        _acknowledged.clear();
        state = const {};
        return;
      }
      _acknowledged[previous.queueVersion] = confirmed;
      state = {for (final index in state.skip(count)) _after(index, confirmed)};
    });
    return const {};
  }

  int _after(int index, Set<int> removed) =>
      index - removed.where((position) => position < index).length;

  int? _resolve(int index, int shownVersion, int version) {
    for (var previous = shownVersion; previous < version; previous++) {
      final confirmed = _acknowledged[previous];
      if (confirmed == null || confirmed.contains(index)) return null;
      index = _after(index, confirmed);
    }
    return index;
  }

  bool isRemoving(int index, int shownVersion, int version) {
    if (shownVersion < version && !_acknowledged.containsKey(shownVersion)) {
      return false;
    }
    final resolved = _resolve(index, shownVersion, version);
    return resolved == null || state.contains(resolved);
  }

  void remove(BuildContext context, int index, int shownVersion) {
    final version = ref.read(playbackProvider).queueVersion;
    final resolved = _resolve(index, shownVersion, version);
    if (resolved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.pick(
              '队列已变化，请重新选择曲目',
              'Queue changed. Select the track again.',
            ),
          ),
        ),
      );
      return;
    }
    if (state.contains(resolved)) return;
    final position = _after(resolved, state);
    try {
      ref.read(queueRemoveCommandProvider)(position);
    } catch (error) {
      ref
          .read(playbackErrorProvider.notifier)
          .report(
            PlaybackFailure(
              error is CoreError ? error.detail : '$error',
              retry: () {
                if (context.mounted) remove(context, index, shownVersion);
              },
            ),
          );
      return;
    }
    _acknowledged.removeWhere((version, _) => version < shownVersion);
    state = {...state, resolved};
  }
}
