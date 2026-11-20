// Right-hand context panel for wide desktop windows (Spotify style): the
// lyrics / queue buttons in the player bar open it next to the content and
// close it again. Nothing is shown until the user asks for it, so the
// default desktop layout is just sidebar | content | player bar.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/lyrics_view.dart';
import 'package:lekis/src/features/player/player_bar.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_panel.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class NowPlayingContextPanel extends ConsumerWidget {
  const NowPlayingContextPanel({super.key});

  static const double width = LekisSizes.desktopQueuePanelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pane = ref.watch(desktopSidePaneProvider);
    final trackId = ref.watch(playbackProvider.select((s) => s.trackId));
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    if (pane == null || !hasTrack || trackId == null) {
      return const SizedBox.shrink();
    }
    void close() => ref.read(desktopSidePaneProvider.notifier).set(null);

    return SizedBox(
      key: const ValueKey('context-panel'),
      width: width,
      child: SafeArea(
        left: false,
        bottom: false,
        child: switch (pane) {
          DesktopSidePane.queue => QueuePanel(onClose: close),
          DesktopSidePane.lyrics => _LyricsPane(
            trackId: trackId,
            onClose: close,
          ),
        },
      ),
    );
  }
}

/// Same frame as [QueuePanel]: header with a close button, then the current
/// track and its lyrics.
class _LyricsPane extends StatelessWidget {
  const _LyricsPane({required this.trackId, required this.onClose});

  final int trackId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final panelColor = Color.alphaBlend(
      colors.surfaceElevated.withValues(alpha: 0.92),
      theme.colorScheme.surface,
    );
    return Material(
      key: const ValueKey('context-panel.lyrics'),
      color: panelColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.outline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.lg,
                0,
                LekisSpacing.sm,
                LekisSpacing.xs,
              ),
              child: SizedBox(
                height: LekisSizes.touchTargetMin,
                child: Row(
                  children: [
                    Icon(
                      Icons.lyrics_outlined,
                      size: LekisSpacing.xl,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: LekisSpacing.sm),
                    Expanded(
                      child: Text('歌词', style: theme.textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: '打开播放页',
                      onPressed: () => openNowPlaying(context),
                      icon: const Icon(Icons.open_in_full_rounded, size: 18),
                    ),
                    IconButton(
                      tooltip: '关闭歌词',
                      constraints: const BoxConstraints(
                        minWidth: LekisSizes.touchTargetMin,
                        minHeight: LekisSizes.touchTargetMin,
                      ),
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: colors.outline),
            Padding(
              padding: const EdgeInsets.all(LekisSpacing.lg),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: LekisSizes.listArtwork,
                    child: CurrentArtwork(radius: LekisRadius.artworkList),
                  ),
                  const SizedBox(width: LekisSpacing.md),
                  Expanded(
                    child: CurrentTrackText(
                      titleStyle: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LyricsView(
                key: ValueKey('context-lyrics-$trackId'),
                trackId: trackId,
                compact: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
