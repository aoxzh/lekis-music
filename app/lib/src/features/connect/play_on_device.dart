// 「在这台设备上播放」：把当前队列和进度交给另一台已配对的设备。
//
// 只列已经配对 / 已连接的设备；没有就直说没得选，而不是弹一个空列表。
// 转移由核心完成（优先对方自己的资料库，其次同一音源，最后本机局域网流），
// 所以这里只负责选设备和报告结果。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

import 'connect_ui.dart' show connectErrorText;
import 'connect_gateway.dart';
import 'connect_providers.dart';
import 'connect_strings.dart';

/// 让用户挑一台设备，把当前播放交给它。
Future<void> showPlayOnDeviceSheet(BuildContext context, WidgetRef ref) async {
  final state = ref.read(connectProvider).value;
  final candidates = <ConnectDeviceInfo>[
    if (state != null)
      for (final device in state.sortedDevices)
        if (device.paired || device.connected) device,
  ];
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String message) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  if (candidates.isEmpty) {
    say(ConnectStrings.noDevicesToPlay);
    return;
  }

  final picked = await showLekisActionList(
    context,
    title: ConnectStrings.transferTitle,
    subtitle: ConnectStrings.transferBody,
    actions: [
      for (final device in candidates)
        LekisMenuAction(
          device,
          device.connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
          device.name,
          description: device.platform,
        ),
    ],
  );
  if (picked == null || !context.mounted) return;

  try {
    final report = await ref
        .read(connectProvider.notifier)
        .transfer(picked.deviceId);
    if (report.total == 0) {
      say(ConnectStrings.nothingPlaying);
    } else if (report.skipped > 0) {
      say(ConnectStrings.transferPartial);
    } else {
      say(ConnectStrings.transferDone);
    }
  } catch (error) {
    say('${ConnectStrings.transferFailed}：${connectErrorText(error)}');
  }
}
