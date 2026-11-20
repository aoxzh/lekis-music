// In-memory ConnectGateway for widget tests: no Rust core, records calls.

import 'dart:async';
import 'dart:typed_data';

import 'package:lekis/src/features/connect/connect_gateway.dart';
import 'package:lekis/src/rust/api/dto.dart' as dto;

ConnectDeviceInfo fakeDevice({
  String id = 'pc',
  String name = '书房电脑',
  String platform = 'windows',
  bool paired = true,
  bool connected = true,
}) => ConnectDeviceInfo(
  deviceId: id,
  name: name,
  platform: platform,
  host: '192.168.1.20',
  port: 47655,
  paired: paired,
  connected: connected,
);

dto.RemoteStateDto fakeRemoteState({
  String title = 'Time',
  dto.PlaybackStateDto state = dto.PlaybackStateDto.playing,
  int positionMs = 60000,
  BigInt? queueVersion,
}) => dto.RemoteStateDto(
  state: state,
  track: dto.RemoteTrackDto(
    id: 4,
    uid: 'uid-4',
    title: title,
    artist: 'Pink Floyd',
    album: 'The Dark Side of the Moon',
    durationMs: BigInt.from(413000),
    via: dto.MediaViaDto.stream,
  ),
  positionMs: BigInt.from(positionMs),
  durationMs: BigInt.from(413000),
  volume: 0.5,
  queueLen: 10,
  queueIndex: 3,
  repeat: dto.RepeatModeDto.off,
  shuffle: dto.ShuffleModeDto.off,
  queueVersion: queueVersion ?? BigInt.one,
);

class FakeConnectGateway implements ConnectGateway {
  FakeConnectGateway({List<ConnectDeviceInfo>? devices, this.remote})
    : _devices = devices ?? [fakeDevice()];

  List<ConnectDeviceInfo> _devices;
  dto.RemoteStateDto? remote;
  final StreamController<ConnectEventInfo> _events =
      StreamController.broadcast();

  final List<String> calls = [];
  final List<dto.ControlActionDto> controls = [];

  void emit(ConnectEventInfo event) => _events.add(event);

  void setDevices(List<ConnectDeviceInfo> devices) {
    _devices = devices;
    emit(ConnectDevicesChanged(devices));
  }

  @override
  Future<int> start({int? port, bool mdns = true}) async => 47655;

  @override
  Future<void> stop() async {}

  @override
  int port() => 47655;

  @override
  Future<ConnectSettingsInfo> settings() async =>
      const ConnectSettingsInfo(deviceName: '我的手机', allowControl: true);

  @override
  Future<void> setSettings({
    required String deviceName,
    required bool allowControl,
  }) async {}

  @override
  List<ConnectDeviceInfo> devices() => _devices;

  @override
  List<PairedPeerInfo> pairedDevices() => const [];

  @override
  Future<ConnectDeviceInfo> addDevice({
    required String host,
    required int port,
  }) async => _devices.first;

  @override
  Future<bool> pair(String deviceId) async {
    calls.add('pair:$deviceId');
    return false;
  }

  @override
  Future<void> pairConfirm(String deviceId, String code) async =>
      calls.add('confirm:$deviceId:$code');

  @override
  void pairCancel(String deviceId) => calls.add('cancel:$deviceId');

  @override
  Future<void> forget(String deviceId) async => calls.add('forget:$deviceId');

  @override
  Future<void> disconnect(String deviceId) async =>
      calls.add('disconnect:$deviceId');

  @override
  Future<dto.RemoteStateDto> remoteState(String deviceId) async {
    calls.add('state:$deviceId');
    return remote ?? fakeRemoteState();
  }

  @override
  Future<void> control(String deviceId, dto.ControlActionDto action) async {
    calls.add('control:$deviceId');
    controls.add(action);
  }

  @override
  Future<List<dto.RemoteTrackDto>> remoteQueue(
    String deviceId, {
    required int offset,
    required int limit,
  }) async => [
    dto.RemoteTrackDto(
      id: 5,
      title: 'The Great Gig in the Sky',
      artist: 'Pink Floyd',
      durationMs: BigInt.from(283000),
    ),
  ];

  @override
  Future<Uint8List?> remoteArtwork(
    String deviceId, {
    required int trackId,
    String? uid,
  }) async => null;

  @override
  Future<QueueReportInfo> transfer(
    String deviceId, {
    required bool pauseLocal,
  }) async {
    calls.add('transfer:$deviceId');
    return const QueueReportInfo(
      total: 10,
      library: 0,
      sameSource: 0,
      stream: 10,
      skipped: 0,
    );
  }

  @override
  Future<QueueReportInfo> playOn(
    String deviceId, {
    required List<int> trackIds,
    required int start,
    required int positionMs,
    required bool play,
  }) async => const QueueReportInfo(
    total: 0,
    library: 0,
    sameSource: 0,
    stream: 0,
    skipped: 0,
  );

  @override
  Stream<ConnectEventInfo> get events => _events.stream;

  @override
  void dispose() => _events.close();
}
