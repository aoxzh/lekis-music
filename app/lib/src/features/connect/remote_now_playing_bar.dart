// 正在遥控别的设备时，迷你播放器 / 桌面播放条上方显示的那一条。
//
// 迷你播放器保持原来的胶囊外形和高度（外壳按固定高度给它留位置），只是
// 内容换成对方的曲目、"正在 xx 上播放"和遥控的播放 / 暂停；点一下打开遥控页。
// 桌面播放条不动，在它上面加一条细的提示条。

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/dto.dart';
import '../../shell/tab_bar_style.dart';
import '../../theme/theme.dart';
import '../../widgets/liquid_glass.dart';
import 'connect_active.dart';
import 'connect_gateway.dart';
import 'connect_strings.dart';
import 'connect_ui.dart';
import 'device_picker.dart';
import 'remote_control_page.dart';

/// Shared remote cover fetch keyed by `(deviceId, trackId, uid)` so the
/// remote mini player and remote-control page reuse the same bytes.
final remoteArtworkBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String deviceId, int trackId, String? uid})>((
      ref,
      key,
    ) async {
      try {
        return await ref
            .read(connectGatewayProvider)
            .remoteArtwork(key.deviceId, trackId: key.trackId, uid: key.uid);
      } catch (_) {
        return null;
      }
    });

Future<void> _toggle(WidgetRef ref, String deviceId) async {
  try {
    await ref
        .read(connectGatewayProvider)
        .control(deviceId, const ControlActionDto.toggle());
  } catch (_) {
    // The state push (or its absence) tells the user; nothing to add here.
  }
}

/// 迷你播放器的遥控版本（同样的胶囊、同样的高度）。
class ConnectRemoteMiniPlayer extends ConsumerWidget {
  const ConnectRemoteMiniPlayer({super.key});

  static const Key cardKey = ValueKey('connect.remote-mini');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(activeRemoteDeviceProvider);
    final state = ref.watch(activeRemoteStateProvider);
    if (device == null) return const SizedBox.shrink();
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final flat = ref.watch(tabBarStyleProvider).resolved == TabBarStyle.flat;
    final track = state?.track;
    final playing = state?.state == PlaybackStateDto.playing;
    final duration = state?.durationMs.toInt() ?? 0;
    final progress = duration <= 0
        ? 0.0
        : (state!.positionMs.toInt() / duration).clamp(0.0, 1.0);
    const art = LekisSizes.miniPlayerHeight - LekisSpacing.sm * 2;

    final artBytes = track == null
        ? null
        : ref
              .watch(
                remoteArtworkBytesProvider((
                  deviceId: device.deviceId,
                  trackId: track.id,
                  uid: track.uid,
                )),
              )
              .value;
    final subtitleColor = theme.colorScheme.onSurface.withValues(alpha: 0.78);

    return Semantics(
      container: true,
      button: true,
      label: ConnectStrings.playingOnDevice(device.name),
      child: GestureDetector(
        key: cardKey,
        behavior: HitTestBehavior.opaque,
        onTap: () => openRemoteControl(context, device.deviceId),
        child: LekisGlassCapsule(
          radius: LekisRadius.miniPlayer,
          flat: flat,
          enableLens: !MediaQuery.disableAnimationsOf(context),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              height: LekisSizes.miniPlayerHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LekisSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        ClipOval(
                          child: SizedBox.square(
                            dimension: art,
                            child: artBytes != null
                                ? Image.memory(
                                    artBytes,
                                    fit: BoxFit.cover,
                                    cacheWidth: 128,
                                    gaplessPlayback: true,
                                  )
                                : ColoredBox(
                                    color: colors.accentSoft,
                                    child: Icon(
                                      connectPlatformIcon(device.platform),
                                      color: colors.accent,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: LekisSpacing.md),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track?.title ?? ConnectStrings.nothingOnRemote,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    connectPlatformIcon(device.platform),
                                    size: 13,
                                    color: colors.moon,
                                  ),
                                  const SizedBox(width: LekisSpacing.xxs),
                                  Expanded(
                                    child: Text(
                                      ConnectStrings.playingOnDevice(
                                        device.name,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: subtitleColor),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('connect.remote-mini.toggle'),
                          tooltip: playing ? '暂停' : '播放',
                          onPressed: track == null
                              ? null
                              : () => _toggle(ref, device.deviceId),
                          icon: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        const ConnectDeviceButton(alwaysShow: true),
                      ],
                    ),
                  ),
                  Positioned(
                    left: LekisRadius.miniPlayer,
                    right: LekisRadius.miniPlayer,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: LekisSpacing.xxs,
                      color: colors.moon,
                      backgroundColor: colors.outline.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(LekisRadius.pill),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 桌面播放条上方的细条："正在 xx 上播放 · 歌名"，播放 / 暂停、遥控、回到本机。
class ConnectRemoteStrip extends ConsumerWidget {
  const ConnectRemoteStrip({super.key});

  static const Key stripKey = ValueKey('connect.remote-strip');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(activeRemoteDeviceProvider);
    if (device == null) return const SizedBox.shrink();
    final state = ref.watch(activeRemoteStateProvider);
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final track = state?.track;
    final playing = state?.state == PlaybackStateDto.playing;
    final onAccent = colors.onAccent;
    final label = [
      ConnectStrings.playingOnDevice(device.name),
      if (track != null) '${track.title} — ${track.artist}',
    ].join(' · ');

    return Material(
      key: stripKey,
      color: colors.accent,
      child: SizedBox(
        height: LekisSizes.touchTargetMin - LekisSpacing.xs,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.lg),
          child: IconTheme(
            data: IconThemeData(color: onAccent, size: LekisSpacing.lg + 2),
            child: Row(
              children: [
                Icon(connectPlatformIcon(device.platform)),
                const SizedBox(width: LekisSpacing.sm),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: onAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: playing ? '暂停' : '播放',
                  visualDensity: VisualDensity.compact,
                  onPressed: track == null
                      ? null
                      : () => _toggle(ref, device.deviceId),
                  icon: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: onAccent),
                  onPressed: () => openRemoteControl(context, device.deviceId),
                  child: Text(ConnectStrings.controlOnly),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: onAccent),
                  onPressed: () =>
                      ref.read(activeRemoteProvider.notifier).clear(),
                  child: Text(ConnectStrings.backToThisDevice),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
