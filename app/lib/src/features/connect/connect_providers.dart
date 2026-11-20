// 「在其他设备上播放」（Lekis Connect）：界面层的状态。
//
// 一条事件流驱动全部状态：核心推 ConnectDevicesChanged / PairingCode /
// PairingFinished / RemoteState / SessionClosed / ControllersChanged，这里把它
// 们收进一个 [ConnectState]，页面只读需要的部分（`select`），不会因为设备列表
// 每次刷新就整屏重建。
//
// 首次 watch 时自动 `start()`：监听控制连接、在局域网广播本机、开始浏览别的
// 设备。默认端口由核心挑（被占用时用系统分配的），改设置只会重新广播。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/dto.dart';
import 'connect_gateway.dart';

/// 这一层看到的全部 Connect 状态。
class ConnectState {
  const ConnectState({
    this.started = false,
    this.port = 0,
    this.settings = const ConnectSettingsInfo(
      deviceName: '',
      allowControl: true,
    ),
    this.devices = const [],
    this.peers = const [],
    this.pairing,
    this.controllers = const [],
    this.remoteStates = const {},
    this.lastClosed,
    this.lastError,
  });

  /// 已经开始监听。
  final bool started;

  /// 监听端口（未启动时 0）。
  final int port;

  final ConnectSettingsInfo settings;

  /// 局域网里的其他 Lekis（含手动添加的）。
  final List<ConnectDeviceInfo> devices;

  /// 已配对的设备（不在线也在）。
  final List<PairedPeerInfo> peers;

  /// 本机作为被控端，正在等某台设备输入配对码。
  final ConnectPairingCode? pairing;

  /// 当前连着本机的控制端名字。
  final List<String> controllers;

  /// 各台设备最近一次的远端状态（遥控页用）。
  final Map<String, RemoteStateDto> remoteStates;

  /// 最近一次被对方断开（给一句提示用）。
  final ({String deviceId, String reason})? lastClosed;

  /// 最近一次失败（start / 设置更新之类）。
  final Object? lastError;

  ConnectState copyWith({
    bool? started,
    int? port,
    ConnectSettingsInfo? settings,
    List<ConnectDeviceInfo>? devices,
    List<PairedPeerInfo>? peers,
    ConnectPairingCode? pairing,
    bool clearPairing = false,
    List<String>? controllers,
    Map<String, RemoteStateDto>? remoteStates,
    ({String deviceId, String reason})? lastClosed,
    Object? lastError,
    bool clearError = false,
  }) => ConnectState(
    started: started ?? this.started,
    port: port ?? this.port,
    settings: settings ?? this.settings,
    devices: devices ?? this.devices,
    peers: peers ?? this.peers,
    pairing: clearPairing ? null : (pairing ?? this.pairing),
    controllers: controllers ?? this.controllers,
    remoteStates: remoteStates ?? this.remoteStates,
    lastClosed: lastClosed ?? this.lastClosed,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  /// 局域网里其他设备按"先在线、再已配对、再名字"排。
  List<ConnectDeviceInfo> get sortedDevices {
    final list = [...devices]
      ..sort((a, b) {
        if (a.connected != b.connected) return a.connected ? -1 : 1;
        if (a.paired != b.paired) return a.paired ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  /// 已配对但不在当前设备列表里的（对方不在线）。
  List<PairedPeerInfo> get offlinePeers {
    final online = {for (final d in devices) d.deviceId};
    return [
      for (final p in peers)
        if (!online.contains(p.deviceId)) p,
    ];
  }
}

final connectProvider = AsyncNotifierProvider<ConnectNotifier, ConnectState>(
  ConnectNotifier.new,
);

class ConnectNotifier extends AsyncNotifier<ConnectState> {
  StreamSubscription<ConnectEventInfo>? _sub;

  ConnectGateway get _gateway => ref.read(connectGatewayProvider);

  @override
  Future<ConnectState> build() async {
    final gateway = ref.watch(connectGatewayProvider);
    _sub = gateway.events.listen(_onEvent, onError: _onError);
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    try {
      final port = await gateway.start();
      final settings = await gateway.settings();
      return ConnectState(
        started: port > 0,
        port: port,
        settings: settings,
        devices: gateway.devices(),
        peers: gateway.pairedDevices(),
      );
    } catch (e) {
      return ConnectState(lastError: e);
    }
  }

  void _onError(Object error) {
    final state = this.state.value;
    if (state != null) this.state = AsyncData(state.copyWith(lastError: error));
  }

  void _onEvent(ConnectEventInfo event) {
    final current = state.value;
    if (current == null) return;
    switch (event) {
      case ConnectDevicesChanged(:final devices):
        state = AsyncData(
          current.copyWith(devices: devices, peers: _gateway.pairedDevices()),
        );
      case ConnectPairingCode():
        state = AsyncData(current.copyWith(pairing: event));
      case ConnectPairingFinished():
        state = AsyncData(
          current.copyWith(
            clearPairing: current.pairing?.peerId == event.peerId,
            peers: _gateway.pairedDevices(),
            devices: _gateway.devices(),
          ),
        );
      case ConnectRemoteStateChanged(:final deviceId, :final state):
        this.state = AsyncData(
          current.copyWith(
            remoteStates: {...current.remoteStates, deviceId: state},
          ),
        );
      case ConnectSessionClosed():
        state = AsyncData(
          current.copyWith(
            lastClosed: (deviceId: event.deviceId, reason: event.reason),
            devices: _gateway.devices(),
            peers: _gateway.pairedDevices(),
          ),
        );
      case ConnectControllersChanged(:final names):
        state = AsyncData(current.copyWith(controllers: names));
    }
  }

  /// 改名 / 允许被控。关掉"允许被控"会停止广播并断开所有控制端。
  Future<void> setSettings({
    required String deviceName,
    required bool allowControl,
  }) async {
    final current = state.value;
    final gateway = _gateway;
    await gateway.setSettings(
      deviceName: deviceName,
      allowControl: allowControl,
    );
    final settings = await gateway.settings();
    if (current == null) return;
    state = AsyncData(
      current.copyWith(settings: settings, lastError: null, clearError: true),
    );
  }

  /// 只改名，保留"允许其他设备控制"。
  Future<void> rename(String deviceName) async {
    final allowControl = state.value?.settings.allowControl ?? true;
    await setSettings(deviceName: deviceName, allowControl: allowControl);
  }

  /// 手动按地址添加（组播被路由器挡住时）。
  Future<ConnectDeviceInfo> addDevice({
    required String host,
    required int port,
  }) async {
    final device = await _gateway.addDevice(host: host, port: port);
    await refresh();
    return device;
  }

  /// 连接（必要时发起配对）。返回 true 表示要用户输入 6 位配对码。
  Future<bool> pair(String deviceId) async {
    final needsCode = await _gateway.pair(deviceId);
    await refresh();
    return needsCode;
  }

  Future<void> pairConfirm(String deviceId, String code) async {
    await _gateway.pairConfirm(deviceId, code);
    await refresh();
  }

  void pairCancel(String deviceId) => _gateway.pairCancel(deviceId);

  Future<void> forget(String deviceId) async {
    await _gateway.forget(deviceId);
    await refresh();
  }

  Future<void> disconnect(String deviceId) async {
    await _gateway.disconnect(deviceId);
    await refresh();
  }

  /// 把本机当前队列和进度交给另一台设备。
  Future<QueueReportInfo> transfer(
    String deviceId, {
    bool pauseLocal = true,
  }) async {
    final report = await _gateway.transfer(deviceId, pauseLocal: pauseLocal);
    await refresh();
    return report;
  }

  /// 存一份远端状态快照（第一次打开遥控页时用）。
  void cacheRemoteState(String deviceId, RemoteStateDto state) {
    final current = this.state.value;
    if (current == null) return;
    this.state = AsyncData(
      current.copyWith(
        remoteStates: {...current.remoteStates, deviceId: state},
      ),
    );
  }

  /// 重新读一次设备 / 配对列表（核心推事件之后兜底用）。
  Future<void> refresh() async {
    final current = state.value;
    if (current == null) return;
    final gateway = _gateway;
    state = AsyncData(
      current.copyWith(
        devices: gateway.devices(),
        peers: gateway.pairedDevices(),
        port: gateway.port(),
        started: gateway.port() > 0,
        lastError: null,
        clearError: true,
      ),
    );
  }

  /// 收起配对码（用户点了关闭）。
  void dismissPairing() {
    final current = state.value;
    if (current?.pairing == null) return;
    state = AsyncData(current!.copyWith(clearPairing: true));
  }
}

/// 本机作为被控端正在等的配对码（没有就是 null）。
final incomingPairingProvider = Provider<ConnectPairingCode?>(
  (ref) => ref.watch(connectProvider).value?.pairing,
);

/// 当前连着本机的控制端名字。
final connectControllersProvider = Provider<List<String>>(
  (ref) => ref.watch(connectProvider).value?.controllers ?? const [],
);

/// 开始接收某台设备的状态推送（遥控页打开时调一次）。
Future<void> watchRemoteState(WidgetRef ref, String deviceId) async {
  final gateway = ref.read(connectGatewayProvider);
  final notifier = ref.read(connectProvider.notifier);
  final snapshot = await gateway.remoteState(deviceId);
  notifier.cacheRemoteState(deviceId, snapshot);
}

/// 一台设备的远端状态（遥控页用）；没收到过就是 null。
final remoteStateProvider = Provider.autoDispose
    .family<RemoteStateDto?, String>(
      (ref, deviceId) => ref.watch(
        connectProvider.select((s) => s.value?.remoteStates[deviceId]),
      ),
    );
