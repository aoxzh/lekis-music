// Connect 界面里几处共用的小件：错误文案、"需要时先配对"、平台图标。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../rust/api/error.dart';
import '../settings/connect_settings_section.dart' show showPairingCodeDialog;
import '../sources/common.dart' show coreErrorKind, describeCoreError;
import 'connect_gateway.dart';
import 'connect_providers.dart';
import 'connect_strings.dart';

/// 给提示条用的错误文案：统一说法 + 核心自己的细节。
///
/// Connect 的错误都是我们自己写的协议消息（"配对码不对"、"对方拒绝"…），
/// 显示细节既安全又是唯一能区分它们的办法；release 构建里 `CoreError`
/// 没有 `toString`，不处理就只剩 "Instance of 'CoreError'"。
String connectErrorText(Object error) {
  // 连不上（超时 / 被拒绝）：多半是对方没开 Lekis，或手机上的 Lekis 在后台没在播放
  // （Android 不让后台 App 接受入站连接）。直接告诉用户该怎么做，比 "connect timed out" 有用。
  if (coreErrorKind(error) == ErrorKind.network) return ConnectStrings.unreachable;
  final text = describeCoreError(error);
  final detail = error is CoreError ? error.detail.trim() : '';
  return detail.isEmpty ? text : '$text（$detail）';
}

void showConnectSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 确保已经和 [device] 建立了控制连接；第一次需要用户输入对方屏幕上的
/// 6 位配对码。返回 false 表示用户取消或失败（已经提示过）。
Future<bool> ensureConnectPaired(
  BuildContext context,
  WidgetRef ref,
  ConnectDeviceInfo device,
) async {
  if (device.connected) return true;
  final notifier = ref.read(connectProvider.notifier);
  try {
    final needsCode = await notifier.pair(device.deviceId);
    if (!needsCode) return true;
    if (!context.mounted) return false;
    final code = await showPairingCodeDialog(context, device: device);
    if (code == null) {
      notifier.pairCancel(device.deviceId);
      return false;
    }
    await notifier.pairConfirm(device.deviceId, code);
    return true;
  } catch (error) {
    if (context.mounted) {
      showConnectSnack(
        context,
        '${ConnectStrings.pairFailed}：${connectErrorText(error)}',
      );
    }
    return false;
  }
}

/// 设备平台对应的图标。
IconData connectPlatformIcon(String platform) => switch (platform) {
  'android' || 'ios' => Icons.smartphone_rounded,
  'windows' || 'macos' || 'linux' => Icons.computer_rounded,
  _ => Icons.devices_other_rounded,
};

/// 平台的中文名。
String connectPlatformName(String platform) => switch (platform) {
  'android' => 'Android',
  'ios' => 'iOS',
  'windows' => 'Windows',
  'macos' => 'macOS',
  'linux' => 'Linux',
  _ => platform,
};
