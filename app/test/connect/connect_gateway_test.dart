// Connect 网关的 DTO → 界面模型转换（不启动 Rust 核心）。

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/connect/connect_gateway.dart';
import 'package:lekis/src/rust/api/dto.dart' as dto;

dto.ConnectDeviceDto _device({
  String deviceId = 'dev-1',
  String name = '客厅',
  bool paired = true,
  bool connected = false,
}) => dto.ConnectDeviceDto(
  deviceId: deviceId,
  name: name,
  platform: 'windows',
  host: '192.168.1.20',
  port: 47655,
  paired: paired,
  connected: connected,
);

dto.RemoteStateDto _remoteState() => dto.RemoteStateDto(
  state: dto.PlaybackStateDto.playing,
  track: dto.RemoteTrackDto(
    id: 7,
    uid: 'uid-7',
    title: 'Song',
    artist: 'Artist',
    durationMs: BigInt.from(180000),
    via: dto.MediaViaDto.sameSource,
  ),
  positionMs: BigInt.from(42000),
  durationMs: BigInt.from(180000),
  volume: 0.6,
  queueLen: 5,
  queueIndex: 2,
  repeat: dto.RepeatModeDto.off,
  shuffle: dto.ShuffleModeDto.off,
  queueVersion: BigInt.from(3),
);

void main() {
  test('device and peer DTOs map onto the flat models', () {
    final device = ConnectDeviceInfo.fromDto(_device(connected: true));
    expect(device.deviceId, 'dev-1');
    expect(device.name, '客厅');
    expect(device.platform, 'windows');
    expect(device.host, '192.168.1.20');
    expect(device.port, 47655);
    expect(device.paired, isTrue);
    expect(device.connected, isTrue);

    final peer = PairedPeerInfo.fromDto(
      dto.PairedPeerDto(
        deviceId: 'dev-2',
        name: '书房',
        platform: 'android',
        pairedAtMs: 1700000000000,
      ),
    );
    expect(peer.deviceId, 'dev-2');
    expect(peer.name, '书房');
    expect(peer.pairedAtMs, 1700000000000);

    final settings = ConnectSettingsInfo.fromDto(
      dto.ConnectSettingsDto(deviceName: '客厅', allowControl: false),
    );
    expect(settings.deviceName, '客厅');
    expect(settings.allowControl, isFalse);
  });

  test('queue report reads the renamed library field and sums playable', () {
    final report = QueueReportInfo.fromDto(
      dto.QueueReportDto(
        total: 10,
        library_: 4,
        sameSource: 3,
        stream: 2,
        skipped: 1,
      ),
    );
    expect(report.total, 10);
    expect(report.library, 4);
    expect(report.sameSource, 3);
    expect(report.stream, 2);
    expect(report.skipped, 1);
    expect(report.playable, 9);
  });

  test('every connect event maps onto its own subclass', () {
    final devices = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.devicesChanged(devices: [_device()]),
    );
    expect(devices, isA<ConnectDevicesChanged>());
    expect((devices as ConnectDevicesChanged).devices.single.name, '客厅');

    final code = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.pairingCode(
        peerId: 'dev-3',
        peerName: '手机',
        code: '123456',
      ),
    );
    expect(
      code,
      isA<ConnectPairingCode>()
          .having((e) => e.peerId, 'peerId', 'dev-3')
          .having((e) => e.code, 'code', '123456'),
    );

    final finished = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.pairingFinished(
        peerId: 'dev-3',
        peerName: '手机',
        success: true,
      ),
    );
    expect(finished, isA<ConnectPairingFinished>());

    final state = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.remoteState(deviceId: 'dev-1', state: _remoteState()),
    );
    expect(state, isA<ConnectRemoteStateChanged>());
    final changed = state as ConnectRemoteStateChanged;
    expect(changed.deviceId, 'dev-1');
    expect(changed.state.track?.title, 'Song');
    expect(changed.state.positionMs.toInt(), 42000);

    final closed = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.sessionClosed(deviceId: 'dev-1', reason: 'eof'),
    );
    expect(
      closed,
      isA<ConnectSessionClosed>().having((e) => e.reason, 'reason', 'eof'),
    );

    final controllers = ConnectEventInfo.fromDto(
      dto.ConnectEventDto.controllersChanged(names: ['手机']),
    );
    expect(
      controllers,
      isA<ConnectControllersChanged>().having(
        (e) => e.names,
        'names',
        ['手机'],
      ),
    );
  });
}
