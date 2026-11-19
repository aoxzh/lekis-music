import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/sources/source_draft.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  test('a local source takes its name from the folder', () {
    final draft = SourceDraft(
      kind: SourceKindDto.local,
      path: '/storage/emulated/0/Music/',
    );

    final config = draft.toConfig();

    expect(config.name, 'Music');
    expect(config.addresses, ['/storage/emulated/0/Music/']);
    expect(config.rootPath, isEmpty);
  });

  test('http URLs get a scheme and lose trailing slashes', () {
    expect(normalizeHttpUrl('nas.local:4533/'), 'http://nas.local:4533');
    expect(
      normalizeHttpUrl('https://music.example.com/'),
      'https://music.example.com',
    );
  });

  test('displayAddress never leaks credentials', () {
    expect(displayAddress('smb://user@nas/music'), 'smb://nas/music');
  });

  test('mDNS WebDAV result prefills http(s)://host:port/path', () {
    final draft = SourceDraft.fromDiscovered(
      const DiscoveredServiceDto(
        kind: DiscoveredKindDto.webDavs,
        name: 'DS920',
        host: '192.168.1.10',
        hostname: 'ds920.local',
        port: 5006,
        path: '/music',
        via: DiscoveryProtocolDto.mdns,
      ),
    );
    expect(draft.kind, SourceKindDto.webDav);
    expect(draft.name, 'DS920');
    expect(draft.url, 'https://192.168.1.10:5006/music');
  });

  test('SMB result keeps a non-default port and drops 445', () {
    final withPort = SourceDraft.fromDiscovered(
      const DiscoveredServiceDto(
        kind: DiscoveredKindDto.smb,
        name: 'NAS',
        host: '192.168.1.10',
        port: 4450,
        via: DiscoveryProtocolDto.wsDiscovery,
      ),
    );
    expect(withPort.kind, SourceKindDto.smb);
    expect(withPort.host, '192.168.1.10:4450');

    final plain = SourceDraft.fromDiscovered(
      const DiscoveredServiceDto(
        kind: DiscoveredKindDto.smb,
        name: 'NAS',
        host: '192.168.1.10',
        port: 445,
        via: DiscoveryProtocolDto.mdns,
      ),
    );
    expect(plain.host, '192.168.1.10');
  });

  test('DLNA result only borrows the host for a possible SMB share', () {
    final draft = SourceDraft.fromDiscovered(
      const DiscoveredServiceDto(
        kind: DiscoveredKindDto.mediaServer,
        name: '客厅 NAS',
        host: '192.168.1.10',
        port: 50001,
        via: DiscoveryProtocolDto.ssdp,
      ),
    );
    expect(draft.kind, SourceKindDto.smb);
    expect(draft.host, '192.168.1.10');
  });
}
