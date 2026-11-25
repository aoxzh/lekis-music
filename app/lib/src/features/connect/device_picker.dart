// Spotify 式的设备按钮和设备列表。
//
// 列表第一行是这台设备，下面是局域网里的其他 Lekis：
//   * 点一台设备 → 必要时先配对 → 把当前的队列和进度交给它（本机暂停），
//     之后迷你播放器 / 播放条改成显示和控制它；
//   * 点右侧的遥控按钮 → 只遥控它正在播的东西，不转移；
//   * 点"这台设备" → 回到本机。
// 手机上是底部面板，桌面上是对话框。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/adaptive_panel.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/cast.dart' show CastDeviceDto, CastKindDto, CastPlaybackStateDto;
import '../../theme/theme.dart';
import '../player/player_providers.dart';
import 'cast_providers.dart';
import 'connect_active.dart';
import 'connect_gateway.dart';
import 'connect_providers.dart';
import 'connect_strings.dart';
import 'connect_ui.dart';
import 'remote_control_page.dart';

/// 设备按钮：局域网里有其他 Lekis 或正在投放时高亮；`alwaysShow` 为 true 时常驻。
class ConnectDeviceButton extends ConsumerWidget {
  const ConnectDeviceButton({super.key, this.alwaysShow = false});

  /// 没发现设备时也显示（播放页 / 桌面播放条有地方放）。
  final bool alwaysShow;

  static const Key buttonKey = ValueKey('connect.device-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(hasConnectDevicesProvider);
    final active = ref.watch(activeRemoteDeviceProvider);
    final castActive = ref.watch(castProvider.select((s) => s.active));
    final isActive = active != null || castActive != null;
    if (!any && !alwaysShow && !isActive) return const SizedBox.shrink();
    final colors = context.lekisColors;
    final tooltip = castActive != null
        ? ConnectStrings.castActiveOn(castActive.deviceName)
        : active != null
        ? ConnectStrings.playingOnDevice(active.name)
        : ConnectStrings.pickerTooltip;
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      isSelected: isActive,
      constraints: const BoxConstraints(
        minWidth: LekisSizes.touchTargetMin,
        minHeight: LekisSizes.touchTargetMin,
      ),
      icon: Icon(castActive != null ? Icons.cast_connected_rounded : Icons.devices_rounded),
      selectedIcon: Icon(
        castActive != null ? Icons.cast_connected_rounded : Icons.devices_rounded,
        color: colors.accent,
      ),
      onPressed: () => showConnectDevicePicker(context, ref),
    );
  }
}

/// 用户在列表里选了什么。
sealed class _Pick {
  const _Pick();
}

final class _PickThisDevice extends _Pick {
  const _PickThisDevice();
}

final class _PickDevice extends _Pick {
  const _PickDevice(this.device, {required this.transfer});
  final ConnectDeviceInfo device;

  /// true = 转移播放；false = 只遥控。
  final bool transfer;
}

final class _PickCastDevice extends _Pick {
  const _PickCastDevice(this.device);
  final CastDeviceDto device;
}

/// 打开设备列表，并执行用户的选择。
Future<void> showConnectDevicePicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final pick = await showLekisSheet<_Pick>(
    context,
    heightFactor: null,
    builder: (_) => const _DeviceList(),
  );
  if (pick == null || !context.mounted) return;
  switch (pick) {
    case _PickThisDevice():
      ref.read(activeRemoteProvider.notifier).clear();
      if (ref.read(castProvider).isCasting) {
        unawaited(ref.read(castProvider.notifier).stop());
      }
    case _PickDevice(:final device, :final transfer):
      if (ref.read(castProvider).isCasting) {
        unawaited(ref.read(castProvider.notifier).stop());
      }
      await _useDevice(context, ref, device, transfer: transfer);
    case _PickCastDevice(:final device):
      await _castToDevice(context, ref, device);
  }
}

Future<void> _castToDevice(
  BuildContext context,
  WidgetRef ref,
  CastDeviceDto device,
) async {
  final playback = ref.read(playbackProvider);
  final trackId = playback.trackId;
  if (trackId == null) {
    if (context.mounted) {
      showConnectSnack(context, ConnectStrings.castNothingPlaying);
    }
    return;
  }
  final positionMs = ref.read(positionProvider);
  try {
    ref.read(activeRemoteProvider.notifier).clear();
    await ref
        .read(castProvider.notifier)
        .castTrack(device, trackId: trackId, positionMs: positionMs);
    if (context.mounted) {
      showConnectSnack(context, ConnectStrings.castActiveOn(device.name));
    }
  } catch (error) {
    if (context.mounted) {
      showConnectSnack(
        context,
        '${ConnectStrings.castFailed}：${connectErrorText(error)}',
      );
    }
  }
}

Future<void> _useDevice(
  BuildContext context,
  WidgetRef ref,
  ConnectDeviceInfo device, {
  required bool transfer,
}) async {
  if (!await ensureConnectPaired(context, ref, device)) return;
  if (!context.mounted) return;
  final hasLocal = ref.read(playbackProvider).hasTrack;
  try {
    if (transfer && hasLocal) {
      final report = await ref
          .read(connectProvider.notifier)
          .transfer(device.deviceId);
      if (context.mounted && report.skipped > 0) {
        showConnectSnack(context, ConnectStrings.transferPartial);
      }
    }
    await ref.read(activeRemoteProvider.notifier).activate(device.deviceId);
  } catch (error) {
    if (context.mounted) {
      showConnectSnack(
        context,
        '${ConnectStrings.transferFailed}：${connectErrorText(error)}',
      );
    }
    return;
  }
  if (!context.mounted) return;
  // 只遥控、或者本机原本就没在播：直接打开遥控页看对方在放什么。
  if (!transfer || !hasLocal) {
    await openRemoteControl(context, device.deviceId);
  }
}

class _DeviceList extends ConsumerStatefulWidget {
  const _DeviceList();

  @override
  ConsumerState<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends ConsumerState<_DeviceList> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) unawaited(ref.read(castProvider.notifier).discover());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final state = ref.watch(connectProvider).value;
    final active = ref.watch(activeRemoteProvider);
    final castState = ref.watch(castProvider);
    final devices = state?.sortedDevices ?? const <ConnectDeviceInfo>[];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final thisName = state?.settings.deviceName ?? '';
    final thisActive = active == null && !castState.isCasting;

    return Column(
      key: const ValueKey('connect.device-list'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LekisSpacing.lg,
            0,
            LekisSpacing.lg,
            LekisSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ConnectStrings.pickerTitle,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: LekisSpacing.xxs),
              Text(ConnectStrings.pickerHint, style: muted),
            ],
          ),
        ),
        ListTile(
          key: const ValueKey('connect.pick.this-device'),
          leading: Icon(
            Icons.volume_up_rounded,
            color: thisActive ? colors.accent : null,
          ),
          title: Text(
            thisName.isEmpty ? ConnectStrings.thisDevice : thisName,
            style: thisActive ? TextStyle(color: colors.accent) : null,
          ),
          subtitle: Text(
            thisActive
                ? ConnectStrings.thisDeviceNow
                : ConnectStrings.backToThisDevice,
          ),
          onTap: () => Navigator.of(context).pop(const _PickThisDevice()),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LekisSpacing.lg,
                    LekisSpacing.sm,
                    LekisSpacing.lg,
                    LekisSpacing.sm,
                  ),
                  child: Text(ConnectStrings.pickerEmpty, style: muted),
                )
              else
                for (final device in devices)
                  _DeviceTile(
                    device: device,
                    active: device.deviceId == active,
                  ),
              const Divider(height: LekisSpacing.lg),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LekisSpacing.lg,
                  0,
                  LekisSpacing.sm,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ConnectStrings.castSectionTitle,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.accent,
                        ),
                      ),
                    ),
                    if (castState.discovering)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        tooltip: ConnectStrings.castRefresh,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        onPressed: () =>
                            ref.read(castProvider.notifier).discover(),
                      ),
                  ],
                ),
              ),
              if (castState.active != null)
                _ActiveCastCard(
                  cast: castState.active!,
                  busy: castState.busy,
                  onTogglePlay: () =>
                      ref.read(castProvider.notifier).togglePlayPause(),
                  onVolume: (v) =>
                      ref.read(castProvider.notifier).setVolume(v),
                  onStop: () => ref.read(castProvider.notifier).stop(),
                ),
              if (castState.devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LekisSpacing.lg,
                    LekisSpacing.xs,
                    LekisSpacing.lg,
                    LekisSpacing.lg,
                  ),
                  child: Text(
                    castState.discovering
                        ? ConnectStrings.castScanning
                        : ConnectStrings.castEmpty,
                    style: muted,
                  ),
                )
              else
                for (final device in castState.devices)
                  _CastDeviceTile(
                    device: device,
                    active: castState.active?.deviceId == device.id,
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActiveCastCard extends StatelessWidget {
  const _ActiveCastCard({
    required this.cast,
    required this.busy,
    required this.onTogglePlay,
    required this.onVolume,
    required this.onStop,
  });

  final CastPlaybackStateDto cast;
  final bool busy;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolume;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LekisSpacing.lg,
        LekisSpacing.xs,
        LekisSpacing.lg,
        LekisSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.all(LekisSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(LekisRadius.md),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  cast.kind == CastKindDto.chromecast
                      ? Icons.cast_connected_rounded
                      : Icons.speaker_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: LekisSpacing.xs),
                Expanded(
                  child: Text(
                    ConnectStrings.castActiveOn(cast.deviceName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: cast.isPlaying ? 'Pause' : 'Play',
                  onPressed: busy ? null : onTogglePlay,
                  icon: Icon(
                    cast.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : onStop,
                  child: Text(ConnectStrings.castStop),
                ),
              ],
            ),
            if (cast.title.isNotEmpty)
              Text(
                cast.artist.isNotEmpty
                    ? '${cast.title} · ${cast.artist}'
                    : cast.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            Row(
              children: [
                const Icon(Icons.volume_up_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: cast.volume.clamp(0.0, 1.0),
                    onChanged: onVolume,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CastDeviceTile extends StatelessWidget {
  const _CastDeviceTile({required this.device, required this.active});

  final CastDeviceDto device;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final protocol = device.kind == CastKindDto.chromecast
        ? ConnectStrings.castChromecast
        : ConnectStrings.castDlna;
    final subtitle = [
      protocol,
      if (device.model != null && device.model!.isNotEmpty) device.model!,
      if (active) ConnectStrings.playingOn,
    ].join(' · ');
    return ListTile(
      key: ValueKey('cast.pick.${device.id}'),
      leading: Icon(
        device.kind == CastKindDto.chromecast
            ? Icons.cast_rounded
            : Icons.speaker_rounded,
        color: active ? colors.accent : null,
      ),
      title: Text(
        device.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: active ? TextStyle(color: colors.accent) : null,
      ),
      subtitle: Text(subtitle),
      onTap: () => Navigator.of(context).pop(_PickCastDevice(device)),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.active});

  final ConnectDeviceInfo device;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final status = [
      connectPlatformName(device.platform),
      if (active)
        ConnectStrings.playingOn
      else if (device.connected)
        ConnectStrings.connected
      else if (!device.paired)
        ConnectStrings.notPaired,
    ].join(' · ');
    return ListTile(
      key: ValueKey('connect.pick.${device.deviceId}'),
      leading: Icon(
        connectPlatformIcon(device.platform),
        color: active ? colors.accent : null,
      ),
      title: Text(
        device.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: active ? TextStyle(color: colors.accent) : null,
      ),
      subtitle: Text(status),
      trailing: IconButton(
        key: ValueKey('connect.pick.${device.deviceId}.remote'),
        tooltip: ConnectStrings.controlOnly,
        icon: const Icon(Icons.settings_remote_rounded),
        onPressed: () =>
            Navigator.of(context).pop(_PickDevice(device, transfer: false)),
      ),
      onTap: () =>
          Navigator.of(context).pop(_PickDevice(device, transfer: true)),
    );
  }
}
