// 「正在 <设备> 上播放」：本机当前在遥控哪一台设备。
//
// 选中一台设备（转移播放，或者直接遥控）之后这里记下它的 ID；迷你播放器、
// 桌面播放条据此改成显示和控制那台设备。对方断开、或者不再出现在设备列表里
// 且没有连接时自动清掉，界面回到本机。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/dto.dart';
import 'connect_gateway.dart';
import 'connect_providers.dart';

final activeRemoteProvider = NotifierProvider<ActiveRemoteNotifier, String?>(
  ActiveRemoteNotifier.new,
);

class ActiveRemoteNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(connectProvider, (_, next) {
      final id = state;
      final value = next.value;
      if (id == null || value == null) return;
      // The control session is what we drive the device through: once it is
      // gone (closed by the other side, network lost, device vanished) the
      // UI goes back to this device instead of showing a stale remote.
      final device = value.devices.where((d) => d.deviceId == id).firstOrNull;
      if (device == null || !device.connected) state = null;
    });
    return null;
  }

  /// 开始遥控 [deviceId]：订阅它的状态推送，界面切到它。
  Future<void> activate(String deviceId) async {
    final gateway = ref.read(connectGatewayProvider);
    final snapshot = await gateway.remoteState(deviceId);
    final connect = ref.read(connectProvider.notifier);
    // remoteState opened the control session; re-read the device list so it
    // already says "connected" before this switches (the listener above
    // would otherwise drop the device on the next push).
    await connect.refresh();
    connect.cacheRemoteState(deviceId, snapshot);
    state = deviceId;
  }

  /// 回到本机（不断开连接，之后还能直接再选它）。
  void clear() => state = null;
}

/// 正在遥控的那台设备（名字、平台……）；没有就是 null。
final activeRemoteDeviceProvider = Provider<ConnectDeviceInfo?>((ref) {
  final id = ref.watch(activeRemoteProvider);
  if (id == null) return null;
  final devices = ref.watch(
    connectProvider.select((s) => s.value?.devices ?? const []),
  );
  for (final d in devices) {
    if (d.deviceId == id) return d;
  }
  return null;
});

/// 正在遥控的那台设备的最新状态。
final activeRemoteStateProvider = Provider<RemoteStateDto?>((ref) {
  final id = ref.watch(activeRemoteProvider);
  if (id == null) return null;
  return ref.watch(remoteStateProvider(id));
});

/// 局域网里有没有可以选的设备（没有就不显示设备按钮，省地方）。
final hasConnectDevicesProvider = Provider<bool>(
  (ref) => ref.watch(
    connectProvider.select(
      (s) =>
          (s.value?.devices.isNotEmpty ?? false) ||
          (s.value?.peers.isNotEmpty ?? false),
    ),
  ),
);
