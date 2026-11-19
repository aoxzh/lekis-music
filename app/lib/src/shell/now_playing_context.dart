// Persistent right-hand context for wide windows: what is playing, with
// lyrics or the queue right next to it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class NowPlayingContextPanel extends ConsumerStatefulWidget {
  const NowPlayingContextPanel({super.key});

  static const double width = 320;

  @override
  ConsumerState<NowPlayingContextPanel> createState() =>
      _NowPlayingContextPanelState();
}

class _NowPlayingContextPanelState
    extends ConsumerState<NowPlayingContextPanel> {
  int _tab = 0; // 0 = lyrics, 1 = queue

  @override
  Widget build(BuildContext context) {
    final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    if (!hasTrack || trackId == null) return const SizedBox.shrink();

    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Container(
      width: NowPlayingContextPanel.width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: colors.outline)),
      ),
      child: SafeArea(
        left: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                LekisSpacing.lg,
                LekisSpacing.md,
                LekisSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在播放',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.moon,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '打开播放页',
                    onPressed: () => openNowPlaying(context),
                    icon: const Icon(Icons.open_in_full_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: CurrentArtwork(
                      radius: LekisRadius.artworkNowPlaying,
                    ),
                  ),
                  const SizedBox(height: LekisSpacing.lg),
                  CurrentTrackText(
                    titleStyle: theme.textTheme.titleLarge,
                    subtitleStyle: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: LekisSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.xl),
              child: Row(
                children: [
                  _ContextTab(
                    label: '歌词',
                    selected: _tab == 0,
                    onTap: () => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  _ContextTab(
                    label: '队列',
                    selected: _tab == 1,
                    onTap: () => setState(() => _tab = 1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: LekisSpacing.sm),
            Divider(color: colors.outline, height: 1),
            Expanded(
              child: _tab == 0
                  ? LyricsView(trackId: trackId, compact: true)
                  : const QueueList(compact: true),
            ),
            Padding(
              padding: const EdgeInsets.all(LekisSpacing.lg),
              child: FilledButton.tonalIcon(
                onPressed: () => openNowPlaying(context),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('打开播放页'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextTab extends StatelessWidget {
  const _ContextTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return InkWell(
      borderRadius: BorderRadius.circular(LekisRadius.pill),
      onTap: onTap,
      child: AnimatedContainer(
        duration: LekisMotion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.md,
          vertical: LekisSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(LekisRadius.pill),
          border: Border.all(
            color: selected ? colors.accentSoft : colors.outline,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? colors.accent : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
