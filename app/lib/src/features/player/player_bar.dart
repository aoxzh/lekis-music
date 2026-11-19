import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Desktop player bar along the bottom of the window:
/// `[artwork  title/artist] [transport + seek] [lyrics queue volume]`.
///
/// Only the artwork / title block opens Now Playing; the rest of the bar is
/// controls, so a stray click between buttons does nothing.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  /// Below this width the right-hand block drops the volume slider and keeps
  /// only the mute button (the mouse wheel still changes volume over it).
  static const double _volumeSliderMinWidth =
      LekisSizes.touchTargetMin * 3 + LekisSizes.gridArtworkMin * 0.75;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final colors = context.lekisColors;
    // The bar's own vertical padding is [LekisSpacing.sm]; the artwork keeps
    // a little more air than that so it never touches the divider.
    const artSize = LekisSizes.desktopPlayerBarHeight - LekisSpacing.lg * 2;

    final left = _NowPlayingLink(
      enabled: hasTrack,
      child: const Row(
        children: [
          SizedBox.square(
            dimension: artSize,
            child: CurrentArtwork(radius: LekisRadius.artworkList),
          ),
          SizedBox(width: LekisSpacing.md),
          Expanded(child: CurrentTrackText()),
        ],
      ),
    );

    final center = ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: LekisSizes.desktopSidebarWidth * 3,
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [TransportControls(), SeekBar(inlineTimes: true)],
      ),
    );

    final right = LayoutBuilder(
      builder: (context, constraints) {
        final roomy = constraints.maxWidth >= _volumeSliderMinWidth;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: '歌词',
              constraints: const BoxConstraints(
                minWidth: LekisSizes.touchTargetMin,
                minHeight: LekisSizes.touchTargetMin,
              ),
              onPressed: hasTrack
                  ? () {
                      ref
                          .read(nowPlayingPaneProvider.notifier)
                          .set(NowPlayingPane.lyrics);
                      openNowPlaying(context);
                    }
                  : null,
              icon: const Icon(Icons.lyrics_outlined),
            ),
            IconButton(
              tooltip: '播放队列',
              constraints: const BoxConstraints(
                minWidth: LekisSizes.touchTargetMin,
                minHeight: LekisSizes.touchTargetMin,
              ),
              onPressed: hasTrack ? () => showQueueSheet(context) : null,
              icon: const Icon(Icons.queue_music_rounded),
            ),
            Flexible(
              child: _WheelVolume(child: VolumeControl(showSlider: roomy)),
            ),
          ],
        );
      },
    );

    return PlayerShortcuts(
      child: Material(
        color: colors.surfaceElevated,
        child: SizedBox(
          height: LekisSizes.desktopPlayerBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LekisSpacing.lg,
              vertical: LekisSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(flex: 3, child: left),
                const SizedBox(width: LekisSpacing.lg),
                Expanded(flex: 4, child: Center(child: center)),
                const SizedBox(width: LekisSpacing.lg),
                Expanded(flex: 3, child: right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Artwork + title block: hover highlight, click cursor, opens Now Playing.
class _NowPlayingLink extends StatelessWidget {
  const _NowPlayingLink({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(LekisRadius.sm);
    final link = InkWell(
      borderRadius: radius,
      onTap: enabled ? () => openNowPlaying(context) : null,
      hoverColor: context.lekisColors.accentSoft.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(LekisSpacing.xs),
        child: child,
      ),
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: enabled
          ? Tooltip(
              message: '打开播放页',
              waitDuration: LekisMotion.slow,
              child: link,
            )
          : link,
    );
  }
}

/// Mouse wheel over the volume control nudges the volume (desktop habit).
class _WheelVolume extends ConsumerWidget {
  const _WheelVolume({required this.child});

  final Widget child;

  static const double _step = 0.05;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        GestureBinding.instance.pointerSignalResolver.register(event, (e) {
          final dy = (e as PointerScrollEvent).scrollDelta.dy;
          if (dy == 0) return;
          final volume = ref.read(playbackProvider).volume;
          ref
              .read(playerActionsProvider)
              .setVolume((volume + (dy < 0 ? _step : -_step)).clamp(0.0, 1.0));
        });
      },
      child: child,
    );
  }
}
