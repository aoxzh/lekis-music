import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show SimpleValue;
import 'package:lekis/src/features/library/widgets/track_actions.dart'
    show LovedButton;
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/features/settings/settings_providers.dart'
    show playbackOutputProvider;
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// What the desktop right-hand context panel shows (Spotify's "lyrics" /
/// "queue" buttons in the player bar toggle it). `null` = closed.
enum DesktopSidePane { lyrics, queue }

/// Open desktop side pane, toggled from the player bar.
final desktopSidePaneProvider =
    NotifierProvider<SimpleValue<DesktopSidePane?>, DesktopSidePane?>(
      () => SimpleValue<DesktopSidePane?>(null),
    );

/// Desktop player bar along the bottom of the window, Spotify / Apple Music
/// style:
/// `[artwork  title/artist  ♡] [transport + seek] [lyrics queue device volume]`.
///
/// Only the artwork / title block opens Now Playing; the rest of the bar is
/// controls, so a stray click between buttons does nothing.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key, this.sidePanel = false});

  /// Whether the window has the right-hand context panel. Then lyrics /
  /// queue toggle that panel in place; otherwise lyrics open Now Playing and
  /// the queue opens as a sheet.
  final bool sidePanel;

  static const Key lyricsKey = ValueKey('player-bar.lyrics');
  static const Key queueKey = ValueKey('player-bar.queue');
  static const Key devicesKey = ValueKey('player-bar.devices');

  /// Below this width the right-hand block drops the volume slider and keeps
  /// only the mute button (the mouse wheel still changes volume over it).
  static const double _volumeSliderMinWidth =
      LekisSizes.touchTargetMin * 4 + LekisSizes.gridArtworkMin * 0.75;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final sidePane = sidePanel ? ref.watch(desktopSidePaneProvider) : null;
    final colors = context.lekisColors;
    const artSize = LekisSizes.desktopPlayerBarHeight - LekisSpacing.lg * 2;

    void toggleSide(DesktopSidePane pane) => ref
        .read(desktopSidePaneProvider.notifier)
        .set(sidePane == pane ? null : pane);

    final left = Row(
      children: [
        Flexible(
          child: _NowPlayingLink(
            enabled: hasTrack,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: artSize,
                  child: CurrentArtwork(radius: LekisRadius.artworkList),
                ),
                SizedBox(width: LekisSpacing.md),
                Flexible(child: CurrentTrackText()),
              ],
            ),
          ),
        ),
        const _CurrentLovedButton(),
      ],
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
            _BarToggle(
              key: lyricsKey,
              tooltip: sidePane == DesktopSidePane.lyrics ? '隐藏歌词' : '歌词',
              icon: Icons.lyrics_outlined,
              selectedIcon: Icons.lyrics_rounded,
              selected: sidePane == DesktopSidePane.lyrics,
              onPressed: !hasTrack
                  ? null
                  : sidePanel
                  ? () => toggleSide(DesktopSidePane.lyrics)
                  : () {
                      ref
                          .read(nowPlayingPaneProvider.notifier)
                          .set(NowPlayingPane.lyrics);
                      openNowPlaying(context);
                    },
            ),
            _BarToggle(
              key: queueKey,
              tooltip: sidePane == DesktopSidePane.queue ? '隐藏播放队列' : '播放队列',
              icon: Icons.queue_music_rounded,
              selectedIcon: Icons.queue_music_rounded,
              selected: sidePane == DesktopSidePane.queue,
              onPressed: !hasTrack
                  ? null
                  : sidePanel
                  ? () => toggleSide(DesktopSidePane.queue)
                  : () => showQueueSheet(context),
            ),
            const _OutputDeviceButton(key: devicesKey),
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
        child: DecoratedBox(
          // One hairline on top separates the bar from the content.
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outline)),
          ),
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
      ),
    );
  }
}

/// Icon toggle in the right cluster: accent icon + soft disc when active.
class _BarToggle extends StatelessWidget {
  const _BarToggle({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      constraints: const BoxConstraints(
        minWidth: LekisSizes.touchTargetMin,
        minHeight: LekisSizes.touchTargetMin,
      ),
      style: IconButton.styleFrom(
        backgroundColor: selected ? colors.accentSoft : null,
        foregroundColor: selected ? colors.accent : null,
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon, color: colors.accent),
    );
  }
}

/// Heart for the playing track, right after its title (Spotify).
class _CurrentLovedButton extends ConsumerWidget {
  const _CurrentLovedButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();
    return LovedButton(
      key: const ValueKey('player-bar.loved'),
      trackId: track.id,
      initialLoved: track.loved,
      compact: false,
    );
  }
}

/// Output device picker (Spotify's "connect to a device" slot). Devices are
/// listed when the menu opens, never while building the bar.
class _OutputDeviceButton extends ConsumerWidget {
  const _OutputDeviceButton({super.key});

  /// Menu value for "follow the system default".
  static const String _systemDefault = '';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    return PopupMenuButton<String>(
      tooltip: '输出设备',
      icon: const Icon(Icons.speaker_group_outlined),
      constraints: const BoxConstraints(
        minWidth: LekisSizes.desktopSidebarWidth,
      ),
      itemBuilder: (context) {
        ref.read(playbackOutputProvider.notifier).refresh();
        final state = ref.read(playbackOutputProvider);
        final selected = state.selectedDeviceId;
        PopupMenuItem<String> item(String value, String label, bool on) =>
            PopupMenuItem<String>(
              value: value,
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: LekisSpacing.xl,
                    child: on
                        ? Icon(
                            Icons.check_rounded,
                            size: LekisSpacing.lg + LekisSpacing.xxs,
                            color: colors.accent,
                          )
                        : null,
                  ),
                  const SizedBox(width: LekisSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
        return [
          item(_systemDefault, '跟随系统默认', selected == null),
          if (state.devices.isNotEmpty) const PopupMenuDivider(),
          for (final d in state.devices) item(d.id, d.name, selected == d.id),
        ];
      },
      onSelected: (id) async {
        try {
          await ref
              .read(playbackOutputProvider.notifier)
              .selectDevice(id == _systemDefault ? null : id);
        } catch (_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('切换输出设备失败')));
        }
      },
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
    if (!enabled) return link;
    return Tooltip(
      message: '打开播放页',
      waitDuration: LekisMotion.slow,
      child: link,
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
