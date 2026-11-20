// Lekis Connect（在其他设备上播放 / 遥控其他设备）的核心门面。单独抽出来是为了在单测里
// 替换成内存实现，不需要启动 Flutter 引擎或 Rust 核心。
//
// 大多数命令都要求核心已经 `connectStart` 过（核心没启动时桥接层报
// `Unsupported: connect is not started`）；`port` / `devices` / `pairedDevices` /
// `pairCancel` 是同步的，其余都是异步。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// 桥接层自己的 Int64List（不是 dart:typed_data 的）。
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import '../../rust/api/connect.dart' as core;
import '../../rust/api/dto.dart' as dto;

/// 局域网里的一台 Lekis（mDNS 看到的或手动添加的）。
@immutable
class ConnectDeviceInfo {
  const ConnectDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.host,
    required this.port,
    required this.paired,
    required this.connected,
  });

  factory ConnectDeviceInfo.fromDto(dto.ConnectDeviceDto d) =>
      ConnectDeviceInfo(
        deviceId: d.deviceId,
        name: d.name,
        platform: d.platform,
        host: d.host,
        port: d.port,
        paired: d.paired,
        connected: d.connected,
      );

  final String deviceId;
  final String name;

  /// `android` / `windows` / ...。
  final String platform;
  final String host;
  final int port;

  /// 已经配对过（长期密钥在凭据库里）。
  final bool paired;

  /// 当前有控制连接。
  final bool connected;
}

/// 一台已配对的设备（包括当前不在线的）。
@immutable
class PairedPeerInfo {
  const PairedPeerInfo({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.pairedAtMs,
  });

  factory PairedPeerInfo.fromDto(dto.PairedPeerDto p) => PairedPeerInfo(
    deviceId: p.deviceId,
    name: p.name,
    platform: p.platform,
    pairedAtMs: p.pairedAtMs.toInt(),
  );

  final String deviceId;

  /// 配对时的设备名。
  final String name;
  final String platform;

  /// 配对时间（Unix 毫秒）。
  final int pairedAtMs;
}

/// 「在其他设备上播放」的设置。
@immutable
class ConnectSettingsInfo {
  const ConnectSettingsInfo({
    required this.deviceName,
    required this.allowControl,
  });

  factory ConnectSettingsInfo.fromDto(dto.ConnectSettingsDto s) =>
      ConnectSettingsInfo(
        deviceName: s.deviceName,
        allowControl: s.allowControl,
      );

  /// 本机在其他设备上显示的名字。
  final String deviceName;

  /// 允许其他设备控制本机（默认允许，仍需配对）。
  final bool allowControl;
}

/// 把队列交给另一台设备的结果：每种方式各解析了几首。
@immutable
class QueueReportInfo {
  const QueueReportInfo({
    required this.total,
    required this.library,
    required this.sameSource,
    required this.stream,
    required this.skipped,
  });

  factory QueueReportInfo.fromDto(dto.QueueReportDto r) => QueueReportInfo(
    total: r.total,
    // 桥接层把 Rust 的 `library` 字段改名成 `library_`（Dart 的内置标识符）。
    library: r.library_,
    sameSource: r.sameSource,
    stream: r.stream,
    skipped: r.skipped,
  );

  /// 一共几首。
  final int total;

  /// 从被控端自己的资料库里找到的。
  final int library;

  /// 同一个音源上直接读的。
  final int sameSource;

  /// 走控制端局域网流的。
  final int stream;

  /// 解析不了、被跳过的。
  final int skipped;

  /// 对方真的能播的曲目数。
  int get playable => library + sameSource + stream;
}

/// Connect 事件（和核心事件分开，界面单独订阅）。
sealed class ConnectEventInfo {
  const ConnectEventInfo();

  factory ConnectEventInfo.fromDto(dto.ConnectEventDto event) => switch (event) {
    dto.ConnectEventDto_DevicesChanged(:final devices) => ConnectDevicesChanged([
      for (final d in devices) ConnectDeviceInfo.fromDto(d),
    ]),
    dto.ConnectEventDto_PairingCode(
      :final peerId,
      :final peerName,
      :final code,
    ) =>
      ConnectPairingCode(peerId: peerId, peerName: peerName, code: code),
    dto.ConnectEventDto_PairingFinished(
      :final peerId,
      :final peerName,
      :final success,
    ) =>
      ConnectPairingFinished(
        peerId: peerId,
        peerName: peerName,
        success: success,
      ),
    dto.ConnectEventDto_RemoteState(:final deviceId, :final state) =>
      ConnectRemoteStateChanged(deviceId: deviceId, state: state),
    dto.ConnectEventDto_SessionClosed(:final deviceId, :final reason) =>
      ConnectSessionClosed(deviceId: deviceId, reason: reason),
    dto.ConnectEventDto_ControllersChanged(:final names) =>
      ConnectControllersChanged(names),
  };
}

/// 设备列表变了。
final class ConnectDevicesChanged extends ConnectEventInfo {
  const ConnectDevicesChanged(this.devices);

  /// 当前局域网里（含手动添加的）所有设备。
  final List<ConnectDeviceInfo> devices;
}

/// 本机作为被控端：有设备请求配对，请把配对码显示出来。
final class ConnectPairingCode extends ConnectEventInfo {
  const ConnectPairingCode({
    required this.peerId,
    required this.peerName,
    required this.code,
  });

  /// 请求配对的设备 ID。
  final String peerId;

  /// 请求配对的设备名。
  final String peerName;

  /// 6 位配对码，用户需要把它输进那台设备。
  final String code;
}

/// 本机作为被控端：配对结束（成功或失败），可以收起配对码。
final class ConnectPairingFinished extends ConnectEventInfo {
  const ConnectPairingFinished({
    required this.peerId,
    required this.peerName,
    required this.success,
  });

  final String peerId;
  final String peerName;
  final bool success;
}

/// 本机作为控制端：远端设备的状态变了。
final class ConnectRemoteStateChanged extends ConnectEventInfo {
  const ConnectRemoteStateChanged({
    required this.deviceId,
    required this.state,
  });

  final String deviceId;

  /// 它的最新状态（桥接层的 `RemoteStateDto`，界面直接读字段）。
  final dto.RemoteStateDto state;
}

/// 本机作为控制端：和远端设备的连接断了。
final class ConnectSessionClosed extends ConnectEventInfo {
  const ConnectSessionClosed({required this.deviceId, required this.reason});

  final String deviceId;

  /// 断开的原因（给日志 / 提示用）。
  final String reason;
}

/// 本机作为被控端：有设备连上 / 断开了。
final class ConnectControllersChanged extends ConnectEventInfo {
  const ConnectControllersChanged(this.names);

  /// 当前连着本机的控制端名字。
  final List<String> names;
}

abstract interface class ConnectGateway {
  /// 开始监听控制连接、在局域网广播本机并浏览其他设备；返回监听端口。
  /// 重复调用直接返回端口。`mdns: false` 只留手动添加。
  Future<int> start({int? port, bool mdns = true});

  /// 停止监听（已有的控制连接一并断开）。
  Future<void> stop();

  /// 本机监听端口（未启动时为 0）。
  int port();

  Future<ConnectSettingsInfo> settings();

  /// 改名后重新广播；关掉 [allowControl] 会停止广播并断开所有控制端。
  Future<void> setSettings({
    required String deviceName,
    required bool allowControl,
  });

  /// 局域网里的其他 Lekis（含手动添加的）。
  List<ConnectDeviceInfo> devices();

  /// 已配对的设备（包括当前不在线的）。
  List<PairedPeerInfo> pairedDevices();

  /// 手动按地址添加一台设备（组播不通时）。
  Future<ConnectDeviceInfo> addDevice({required String host, required int port});

  /// 连接一台设备。返回 `true` 表示对方屏幕上出现了配对码，
  /// 用户输入后要接着调 [pairConfirm]。
  Future<bool> pair(String deviceId);

  Future<void> pairConfirm(String deviceId, String code);

  /// 放弃正在进行的配对。
  void pairCancel(String deviceId);

  /// 删除配对（之后需要重新输入配对码）。
  Future<void> forget(String deviceId);

  /// 断开控制连接（不删除配对）。
  Future<void> disconnect(String deviceId);

  /// 远端设备的当前状态（同时开始接收它的状态推送）。
  Future<dto.RemoteStateDto> remoteState(String deviceId);

  /// 遥控：播放 / 暂停 / 切歌 / 跳转 / 音量……
  Future<void> control(String deviceId, dto.ControlActionDto action);

  /// 远端队列的一页。
  Future<List<dto.RemoteTrackDto>> remoteQueue(
    String deviceId, {
    required int offset,
    required int limit,
  });

  /// 远端曲目的封面字节；`uid` 让核心在本机资料库里找同一首歌的封面兜底。
  Future<Uint8List?> remoteArtwork(
    String deviceId, {
    required int trackId,
    String? uid,
  });

  /// 转移播放：把本机当前队列和进度交给另一台设备，成功后本机暂停。
  Future<QueueReportInfo> transfer(
    String deviceId, {
    required bool pauseLocal,
  });

  /// 让另一台设备播放一组本机曲目（「在 xx 上播放」）。
  Future<QueueReportInfo> playOn(
    String deviceId, {
    required List<int> trackIds,
    required int start,
    required int positionMs,
    required bool play,
  });

  /// Connect 事件流（设备列表、配对码、远端状态……）。
  Stream<ConnectEventInfo> get events;

  /// 关掉事件订阅。
  void dispose();
}

/// 真正调用 Rust 核心的实现。
class CoreConnectGateway implements ConnectGateway {
  StreamController<ConnectEventInfo>? _events;
  StreamSubscription<dto.ConnectEventDto>? _eventsSub;

  @override
  Future<int> start({int? port, bool mdns = true}) =>
      core.connectStart(port: port, mdns: mdns);

  @override
  Future<void> stop() => core.connectStop();

  @override
  int port() => core.connectPort();

  @override
  Future<ConnectSettingsInfo> settings() async =>
      ConnectSettingsInfo.fromDto(await core.connectSettings());

  @override
  Future<void> setSettings({
    required String deviceName,
    required bool allowControl,
  }) => core.connectSetSettings(
    deviceName: deviceName,
    allowControl: allowControl,
  );

  @override
  List<ConnectDeviceInfo> devices() => [
    for (final d in core.connectDevices()) ConnectDeviceInfo.fromDto(d),
  ];

  @override
  List<PairedPeerInfo> pairedDevices() => [
    for (final p in core.connectPairedDevices()) PairedPeerInfo.fromDto(p),
  ];

  @override
  Future<ConnectDeviceInfo> addDevice({
    required String host,
    required int port,
  }) async => ConnectDeviceInfo.fromDto(
    await core.connectAddDevice(host: host, port: port),
  );

  @override
  Future<bool> pair(String deviceId) => core.connectPair(deviceId: deviceId);

  @override
  Future<void> pairConfirm(String deviceId, String code) =>
      core.connectPairConfirm(deviceId: deviceId, code: code);

  @override
  void pairCancel(String deviceId) => core.connectPairCancel(deviceId: deviceId);

  @override
  Future<void> forget(String deviceId) =>
      core.connectForget(deviceId: deviceId);

  @override
  Future<void> disconnect(String deviceId) =>
      core.connectDisconnect(deviceId: deviceId);

  @override
  Future<dto.RemoteStateDto> remoteState(String deviceId) =>
      core.connectRemoteState(deviceId: deviceId);

  @override
  Future<void> control(String deviceId, dto.ControlActionDto action) =>
      core.connectControl(deviceId: deviceId, action: action);

  @override
  Future<List<dto.RemoteTrackDto>> remoteQueue(
    String deviceId, {
    required int offset,
    required int limit,
  }) => core.connectRemoteQueue(
    deviceId: deviceId,
    offset: offset,
    limit: limit,
  );

  @override
  Future<Uint8List?> remoteArtwork(
    String deviceId, {
    required int trackId,
    String? uid,
  }) => core.connectRemoteArtwork(
    deviceId: deviceId,
    trackId: trackId,
    uid: uid,
  );

  @override
  Future<QueueReportInfo> transfer(
    String deviceId, {
    required bool pauseLocal,
  }) async => QueueReportInfo.fromDto(
    await core.connectTransfer(deviceId: deviceId, pauseLocal: pauseLocal),
  );

  @override
  Future<QueueReportInfo> playOn(
    String deviceId, {
    required List<int> trackIds,
    required int start,
    required int positionMs,
    required bool play,
  }) async => QueueReportInfo.fromDto(
    await core.connectPlayOn(
      deviceId: deviceId,
      trackIds: Int64List.fromList(trackIds),
      start: start,
      positionMs: BigInt.from(positionMs),
      play: play,
    ),
  );

  @override
  Stream<ConnectEventInfo> get events {
    final existing = _events;
    if (existing != null) return existing.stream;
    final controller = StreamController<ConnectEventInfo>.broadcast();
    _events = controller;
    // 核心那边的监听者只注册一次（核心不会移除监听者）。
    _eventsSub = core.connectEvents().listen(
      (event) => controller.add(ConnectEventInfo.fromDto(event)),
      onError: controller.addError,
      onDone: controller.close,
    );
    return controller.stream;
  }

  @override
  void dispose() {
    final sub = _eventsSub;
    final controller = _events;
    _eventsSub = null;
    _events = null;
    sub?.cancel();
    controller?.close();
  }
}

/// 全局网关。单测里用 `overrideWithValue` 换成假的。
final connectGatewayProvider = Provider<ConnectGateway>((ref) {
  final gateway = CoreConnectGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});
