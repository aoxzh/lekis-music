import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:material_ui/material_ui.dart';

String moveToNextLabel(BuildContext context) =>
    context.l10n.pick('移到下一首', 'Move to Next');

VoidCallback? queueMoveToNext(WidgetRef ref, int index) {
  final playback = ref.read(playbackProvider);
  final current = playback.queueIndex;
  if (current == null ||
      current < 0 ||
      current >= playback.queueLength ||
      index < 0 ||
      index >= playback.queueLength ||
      index == current ||
      index == current + 1) {
    return null;
  }
  final context = ref.context;
  return () {
    if (!context.mounted) return;
    final latest = ref.read(playbackProvider);
    if (latest.queueVersion != playback.queueVersion ||
        latest.queueLength != playback.queueLength ||
        latest.queueIndex != current) {
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
    final destination = index < current ? current : current + 1;
    ref.read(playerActionsProvider).moveQueueItem(index, destination);
  };
}
