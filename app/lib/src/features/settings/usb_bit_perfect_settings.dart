// 设置里的 USB DAC 比特完美直出开关 + 状态行（只在 Android 上出现）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/usb_output.dart';
import '../../theme/tokens.dart';
import 'settings_guard.dart';
import 'strings.dart';
import 'usb_bit_perfect_providers.dart';
import 'widgets/settings_widgets.dart';

/// 开关和状态行，作为若干行放进 [SettingsSection]。不支持的平台返回空列表。
List<Widget> usbBitPerfectTiles(WidgetRef ref) {
  if (!ref.watch(usbBitPerfectSupportedProvider)) return const [];
  final status = ref.watch(usbBitPerfectProvider);
  return [
    const UsbBitPerfectSwitchTile(key: UsbBitPerfectSwitchTile.switchKey),
    if (status.enabled)
      const UsbBitPerfectStatusTile(key: UsbBitPerfectStatusTile.statusKey),
  ];
}

class UsbBitPerfectSwitchTile extends ConsumerWidget {
  const UsbBitPerfectSwitchTile({super.key});

  static const Key switchKey = ValueKey('settings.usb-bit-perfect');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(usbBitPerfectProvider);
    return SettingsSwitchTile(
      icon: Icons.usb_rounded,
      title: SettingsStrings.usbBitPerfect,
      subtitle: SettingsStrings.usbBitPerfectHint,
      value: status.enabled,
      onChanged: status.available
          ? (on) => settingsGuard(
              context,
              () => ref.read(usbBitPerfectProvider.notifier).setEnabled(on),
            )
          : null,
    );
  }
}

class UsbBitPerfectStatusTile extends ConsumerWidget {
  const UsbBitPerfectStatusTile({super.key});

  static const Key statusKey = ValueKey('settings.usb-bit-perfect.status');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(usbBitPerfectProvider);
    final colors = context.lekisColors;
    final active = status.state == UsbBitPerfectStateDto.active;
    final failed = status.state == UsbBitPerfectStateDto.failed;
    return SettingsTile(
      icon: active ? Icons.check_circle_outline_rounded : Icons.info_outline,
      title: SettingsStrings.usbStatus,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            describeUsbBitPerfectStatus(status),
            style: failed ? TextStyle(color: colors.danger) : null,
          ),
          // 真正直出（或已就绪）时，把被旁路的东西说清楚。
          if (active || status.state == UsbBitPerfectStateDto.ready)
            Text(SettingsStrings.usbBypassedNote),
        ],
      ),
      trailing: IconButton(
        tooltip: SettingsStrings.refreshDevices,
        onPressed: ref.read(usbBitPerfectProvider.notifier).refresh,
        icon: const Icon(Icons.refresh_rounded),
      ),
    );
  }
}

/// 状态行文字：正在直出的设备 + 格式，或者回退原因。
String describeUsbBitPerfectStatus(UsbBitPerfectStatusDto s) {
  final device = s.deviceName ?? SettingsStrings.usbUnknownDevice;
  return switch (s.state) {
    UsbBitPerfectStateDto.disabled => SettingsWidgetStrings.off,
    UsbBitPerfectStateDto.unavailable => SettingsStrings.usbStatusUnavailable,
    UsbBitPerfectStateDto.noDevice => SettingsStrings.usbStatusNoDevice,
    UsbBitPerfectStateDto.unsupported =>
      s.sdkInt > 0 && s.sdkInt < 34
          ? SettingsStrings.usbStatusOldAndroid(s.sdkInt)
          : SettingsStrings.usbStatusUnsupported(device),
    UsbBitPerfectStateDto.formatFallback =>
      SettingsStrings.usbStatusFormatFallback(device, usbFormatLabel(s)),
    UsbBitPerfectStateDto.ready => SettingsStrings.usbStatusReady(device),
    UsbBitPerfectStateDto.active => SettingsStrings.usbStatusActive(
      device,
      usbFormatLabel(s),
    ),
    UsbBitPerfectStateDto.failed => SettingsStrings.usbStatusFailed(
      s.message ?? '—',
    ),
  };
}

/// `96 kHz / 24-bit`（容器位宽不同时补一句）。没有格式信息时返回 `—`。
String usbFormatLabel(UsbBitPerfectStatusDto s) {
  final rate = s.sampleRate;
  if (rate == null) return '—';
  final khz = rate % 1000 == 0
      ? '${rate ~/ 1000}'
      : (rate / 1000).toStringAsFixed(1);
  final parts = <String>['$khz kHz'];
  final bits = s.sourceBits;
  if (bits != null) parts.add(s.sourceFloat ? '$bits-bit float' : '$bits-bit');
  var label = parts.join(' / ');
  final container = s.containerBits;
  if (container != null && container != bits) {
    label = '$label · ${SettingsStrings.usbContainer(container)}';
  }
  return label;
}
