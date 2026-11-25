import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/connect/device_picker.dart';
import 'package:lekis/src/features/connect/remote_now_playing_bar.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lekis/src/features/desktop_lyrics/desktop_lyrics_strings.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show SimpleValue;
import 'package:lekis/src/features/mini_mode/mini_mode_controller.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart'
    show LovedButton;
import 'package:lekis/src/features/now_playing/now_playing_providers.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_view.dart';
import 'package:lekis/src/features/player/sleep_timer.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/features/settings/settings_providers.dart'
    show playbackOutputProvider;
import 'package:lekis/src/rust/api/dto.dart' show OutputModeDto;
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/lekis_slider.dart';
import 'package:lekis/src/widgets/action_menu.dart';
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
  static const Key desktopLyricsKey = ValueKey('player-bar.desktop-lyrics');
  static const Key queueKey = ValueKey('player-bar.queue');
  static const Key devicesKey = ValueKey('player-bar.devices');
  static const Key volumeKey = ValueKey('player-bar.volume');
  static const Key volumePopoverKey = ValueKey('player-bar.volume-popover');
  static const Key miniModeKey = ValueKey('player-bar.mini-mode');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final sidePane = sidePanel ? ref.watch(desktopSidePaneProvider) : null;
    final desktopLyricsSupported = ref.watch(desktopLyricsSupportedProvider);
    final miniModeSupported = ref.watch(miniModeSupportedProvider);
    final desktopLyricsVisible = desktopLyricsSupported
        ? ref.watch(desktopLyricsProvider.select((s) => s.visible))
        : false;
    final sleepTimerActive = ref.watch(
      sleepTimerProvider.select((s) => s.active),
    );
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

    final right = IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(38, 38),
          padding: const EdgeInsets.all(LekisSpacing.xs),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _BarToggle(
            key: lyricsKey,
            tooltip: sidePane == DesktopSidePane.lyrics
                ? context.l10n.hideLyrics
                : context.l10n.lyrics,
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
          if (desktopLyricsSupported)
            _BarToggle(
              key: desktopLyricsKey,
              tooltip: DesktopLyricsStrings.toggleTooltip,
              icon: Icons.subtitles_outlined,
              selectedIcon: Icons.subtitles_rounded,
              selected: desktopLyricsVisible,
              onPressed: () =>
                  ref.read(desktopLyricsProvider.notifier).toggleVisible(),
            ),
          _BarToggle(
            key: queueKey,
            tooltip: sidePane == DesktopSidePane.queue
                ? context.l10n.hideQueue
                : context.l10n.queue,
            icon: Icons.queue_music_rounded,
            selectedIcon: Icons.queue_music_rounded,
            selected: sidePane == DesktopSidePane.queue,
            onPressed: !hasTrack
                ? null
                : sidePanel
                ? () => toggleSide(DesktopSidePane.queue)
                : () => showQueueSheet(context),
          ),
          const ConnectDeviceButton(alwaysShow: true),
          const _ExclusiveModeButton(),
          if (sleepTimerActive)
            const SleepTimerButton(
              key: ValueKey('player-bar.sleep-timer'),
              compact: true,
            ),
          const _OutputDeviceButton(key: devicesKey),
          const _WheelVolume(child: _VolumePopoverButton(key: volumeKey)),
          if (miniModeSupported)
            IconButton(
              key: miniModeKey,
              tooltip: context.l10n.miniPlayerMode,
              constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              onPressed: () => ref.read(miniModeProvider.notifier).enter(),
              icon: const Icon(Icons.picture_in_picture_alt_rounded),
            ),
        ],
      ),
    );

    return PlayerShortcuts(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // "正在 xx 上播放" while controlling another device (Connect).
          const ConnectRemoteStrip(),
          Material(
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
                      const SizedBox(width: LekisSpacing.md),
                      Expanded(flex: 4, child: Center(child: center)),
                      const SizedBox(width: LekisSpacing.md),
                      Expanded(flex: 4, child: right),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
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
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
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

/// Toggle bit-perfect exclusive output from the player bar when the current
/// device supports it. Hidden on devices/systems without exclusive support.
class _ExclusiveModeButton extends ConsumerWidget {
  const _ExclusiveModeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(playbackOutputProvider);
    if (!output.exclusiveSupported) return const SizedBox.shrink();
    final exclusive = output.mode == OutputModeDto.exclusive;
    return IconButton(
      tooltip: exclusive
          ? context.l10n.pick('关闭独占模式', 'Disable exclusive mode')
          : context.l10n.pick('开启独占模式', 'Enable exclusive mode'),
      icon: Icon(
        exclusive ? Icons.high_quality_rounded : Icons.high_quality_outlined,
      ),
      onPressed: () async {
        try {
          await ref
              .read(playbackOutputProvider.notifier)
              .setMode(
                exclusive ? OutputModeDto.shared : OutputModeDto.exclusive,
              );
        } catch (_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.pick('切换输出模式失败', 'Failed to switch output mode'),
                ),
              ),
            );
        }
      },
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
    return LekisActionMenuButton<String>(
      title: context.l10n.outputDevice,
      tooltip: context.l10n.outputDevice,
      icon: Icons.speaker_group_outlined,
      actions: () {
        ref.read(playbackOutputProvider.notifier).refresh();
        final state = ref.read(playbackOutputProvider);
        return [
          LekisMenuAction(
            _systemDefault,
            Icons.speaker_group_outlined,
            context.l10n.pick('跟随系统默认', 'System default'),
            selected: state.selectedDeviceId == null,
          ),
          for (final (index, device) in state.devices.indexed)
            LekisMenuAction(
              device.id,
              Icons.speaker_outlined,
              device.name,
              selected: state.selectedDeviceId == device.id,
              startsGroup: index == 0,
            ),
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
            ..showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.pick(
                    '切换输出设备失败',
                    'Failed to switch output device',
                  ),
                ),
              ),
            );
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
      message: context.l10n.pick('打开播放页', 'Open Now Playing'),
      waitDuration: LekisMotion.slow,
      child: link,
    );
  }
}

/// 桌面播放条音量按钮：点击向上弹出浮动竖向音量条，窄窗口不再被裁切；
/// 滚轮悬停在按钮或浮层上同样可直接微调音量。
class _VolumePopoverButton extends ConsumerStatefulWidget {
  const _VolumePopoverButton({super.key});

  @override
  ConsumerState<_VolumePopoverButton> createState() =>
      _VolumePopoverButtonState();
}

class _VolumePopoverButtonState extends ConsumerState<_VolumePopoverButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  double _beforeMute = 1;

  IconData _iconFor(double volume) => volume == 0
      ? Icons.volume_off_rounded
      : volume < 0.5
      ? Icons.volume_down_rounded
      : Icons.volume_up_rounded;

  void _toggleMute(double volume) {
    final actions = ref.read(playerActionsProvider);
    if (volume == 0) {
      actions.setVolume(_beforeMute > 0 ? _beforeMute : 1);
    } else {
      _beforeMute = volume;
      actions.setVolume(0);
    }
  }

  void _togglePopover() {
    setState(() {
      if (_portal.isShowing) {
        _portal.hide();
      } else {
        _portal.show();
      }
    });
  }

  void _hidePopover() {
    if (!_portal.isShowing) return;
    setState(() => _portal.hide());
  }

  @override
  Widget build(BuildContext context) {
    final volume = ref.watch(playbackProvider.select((s) => s.volume));
    final colors = context.lekisColors;
    final percent = (volume.clamp(0.0, 1.0) * 100).round();

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          final currentVol = ref
              .watch(playbackProvider.select((s) => s.volume))
              .clamp(0.0, 1.0);
          final currentPct = (currentVol * 100).round();
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _hidePopover,
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _hidePopover,
                  ),
                ),
                CompositedTransformFollower(
                  link: _link,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.topRight,
                  followerAnchor: Alignment.bottomRight,
                  offset: const Offset(0, -LekisSpacing.sm),
                  child: _WheelVolume(
                    child: Material(
                      key: PlayerBar.volumePopoverKey,
                      elevation: 10,
                      color: colors.surfaceElevated,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(LekisRadius.lg),
                        side: BorderSide(color: colors.outline),
                      ),
                      child: SizedBox(
                        width: 52,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: LekisSpacing.sm,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$currentPct%',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colors.onSurfaceVariant,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                              const SizedBox(height: LekisSpacing.xs),
                              SizedBox(
                                height: 136,
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: LekisSlider(
                                    value: currentVol,
                                    semanticFormatterCallback: (v) =>
                                        context.l10n.pick(
                                          '音量 ${(v * 100).round()}%',
                                          'Volume ${(v * 100).round()}%',
                                        ),
                                    onChanged: (v) => ref
                                        .read(playerActionsProvider)
                                        .setVolume(v),
                                    trackHeight: LekisSliderGeometry.track,
                                    dense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(height: LekisSpacing.xs),
                              IconButton(
                                tooltip: currentVol == 0
                                    ? context.l10n.unmute
                                    : context.l10n.mute,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _toggleMute(currentVol),
                                icon: Icon(
                                  _iconFor(currentVol),
                                  size: 20,
                                  color: currentVol == 0
                                      ? colors.onSurfaceVariant
                                      : colors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: _BarToggle(
          tooltip: context.l10n.volumeTooltip(percent),
          icon: _iconFor(volume),
          selectedIcon: _iconFor(volume),
          selected: _portal.isShowing,
          onPressed: _togglePopover,
        ),
      ),
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
