// Spotify 式的设备按钮和设备列表。
//
// 列表第一行是这台设备，下面是局域网里的其他 Lekis：
//   * 点一台设备 → 必要时先配对 → 把当前的队列和进度交给它（本机暂停），
//     之后迷你播放器 / 播放条改成显示和控制它；
//   * 点右侧的遥控按钮 → 只遥控它正在播的东西，不转移；
//   * 点"这台设备" → 回到本机。
// 手机上是底部面板，桌面上是对话框（[UiProfile.prefersSheets]）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../platform/ui_profile.dart';
import '../../theme/theme.dart';
import '../player/player_providers.dart';
import 'connect_active.dart';
import 'connect_gateway.dart';
import 'connect_providers.dart';
import 'connect_strings.dart';
import 'connect_ui.dart';
import 'remote_control_page.dart';

/// 设备按钮：局域网里有其他 Lekis 时才出现；正在遥控别的设备时高亮。
class ConnectDeviceButton extends ConsumerWidget {
  const ConnectDeviceButton({super.key, this.alwaysShow = false});

  /// 没发现设备时也显示（播放页 / 桌面播放条有地方放）。
  final bool alwaysShow;

  static const Key buttonKey = ValueKey('connect.device-button');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any = ref.watch(hasConnectDevicesProvider);
    final active = ref.watch(activeRemoteDeviceProvider);
    if (!any && !alwaysShow && active == null) return const SizedBox.shrink();
    final colors = context.lekisColors;
    return IconButton(
      key: buttonKey,
      tooltip: active == null
          ? ConnectStrings.pickerTooltip
          : ConnectStrings.playingOnDevice(active.name),
      isSelected: active != null,
      constraints: const BoxConstraints(
        minWidth: LekisSizes.touchTargetMin,
        minHeight: LekisSizes.touchTargetMin,
      ),
      icon: const Icon(Icons.devices_rounded),
      selectedIcon: Icon(Icons.devices_rounded, color: colors.accent),
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

/// 打开设备列表，并执行用户的选择。
Future<void> showConnectDevicePicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final content = const _DeviceList();
  final _Pick? pick = UiProfile.current.prefersSheets
      ? await showModalBottomSheet<_Pick>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(child: content),
        )
      : await showDialog<_Pick>(
          context: context,
          builder: (context) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: LekisSizes.desktopSidebarWidth * 2,
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: LekisSpacing.md),
                child: _DeviceList(),
              ),
            ),
          ),
        );
  if (pick == null || !context.mounted) return;
  switch (pick) {
    case _PickThisDevice():
      ref.read(activeRemoteProvider.notifier).clear();
    case _PickDevice(:final device, :final transfer):
      await _useDevice(context, ref, device, transfer: transfer);
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

class _DeviceList extends ConsumerWidget {
  const _DeviceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final state = ref.watch(connectProvider).value;
    final active = ref.watch(activeRemoteProvider);
    final devices = state?.sortedDevices ?? const <ConnectDeviceInfo>[];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final thisName = state?.settings.deviceName ?? '';

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
            color: active == null ? colors.accent : null,
          ),
          title: Text(
            thisName.isEmpty ? ConnectStrings.thisDevice : thisName,
            style: active == null ? TextStyle(color: colors.accent) : null,
          ),
          subtitle: Text(
            active == null
                ? ConnectStrings.thisDeviceNow
                : ConnectStrings.backToThisDevice,
          ),
          onTap: () => Navigator.of(context).pop(const _PickThisDevice()),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LekisSpacing.lg,
              LekisSpacing.sm,
              LekisSpacing.lg,
              LekisSpacing.lg,
            ),
            child: Text(ConnectStrings.pickerEmpty, style: muted),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  _DeviceTile(
                    device: device,
                    active: device.deviceId == active,
                  ),
              ],
            ),
          ),
      ],
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
