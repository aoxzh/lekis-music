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

  test('SMB password goes to the credential ref, never into the address', () {
    final draft = SourceDraft(
      kind: SourceKindDto.smb,
      host: 'nas',
      share: 'music',
      path: 'FLAC/古典',
      username: 'ao',
      secret: 'hunter2',
    );

    final config = draft.toConfig(credentialRef: 'lekis.source.7');

    expect(config.addresses, ['smb://nas/music/FLAC/%E5%8F%A4%E5%85%B8']);
    expect(config.options, {'username': 'ao'});
    expect(config.credentialRef, 'lekis.source.7');
    expect(config.addresses.single.contains('hunter2'), isFalse);
    expect(config.options.values.contains('hunter2'), isFalse);
    expect(draft.usesCredential, isTrue);
  });

  test('guest SMB has no username and no credential ref', () {
    final draft = SourceDraft(
      kind: SourceKindDto.smb,
      host: 'nas',
      share: 'music',
      guest: true,
    );

    final config = draft.toConfig();

    expect(draft.usesCredential, isFalse);
    expect(config.addresses, ['smb://nas/music']);
    expect(config.options, isEmpty);
    expect(config.credentialRef, isNull);
  });

  test(
    'WebDAV username moves to options and the password stays out of the URL',
    () {
      final draft = SourceDraft(
        kind: SourceKindDto.webDav,
        url: 'https://nas:5006/music',
        username: 'ao',
        secret: 'hunter2',
      );

      final config = draft.toConfig(credentialRef: 'ref-webdav');

      expect(config.addresses, ['https://nas:5006/music']);
      expect(config.options, {'username': 'ao'});
      expect(config.credentialRef, 'ref-webdav');
      expect(config.addresses.single.contains('ao'), isFalse);
      expect(config.addresses.single.contains('hunter2'), isFalse);
    },
  );

  test('server token is not copied into options', () {
    final jellyfin = SourceDraft(
      kind: SourceKindDto.jellyfin,
      url: 'http://jellyfin:8096',
      secret: 'api-key',
    ).toConfig(credentialRef: 'ref-jellyfin');
    final plex = SourceDraft(
      kind: SourceKindDto.plex,
      url: 'http://plex:32400',
      secret: 'plex-token',
    ).toConfig(credentialRef: 'ref-plex');

    expect(jellyfin.options, isEmpty);
    expect(plex.options, isEmpty);
    expect(jellyfin.options.values.contains('api-key'), isFalse);
    expect(plex.options.values.contains('plex-token'), isFalse);
  });

  test('fromConfig restores editable fields without reading a password', () {
    const existing = SourceConfigDto(
      id: 7,
      kind: SourceKindDto.smb,
      name: 'NAS',
      addresses: ['smb://ao@nas/music/FLAC'],
      rootPath: '',
      credentialRef: 'lekis.source.7',
      options: {'username': 'ao'},
      enabled: true,
    );

    final draft = SourceDraft.fromConfig(existing);

    expect(draft.name, 'NAS');
    expect(draft.host, 'nas');
    expect(draft.share, 'music');
    expect(draft.path, 'FLAC');
    expect(draft.username, 'ao');
    expect(draft.guest, isFalse);
    expect(draft.secret, isEmpty);
    expect(draft.usesCredential, isTrue);
    expect(
      draft.toConfig(credentialRef: existing.credentialRef).credentialRef,
      'lekis.source.7',
    );
  });

  test('fromConfig ignores legacy passwords embedded in the address', () {
    const legacyPassword = 'legacy-pass';
    final existing = SourceConfigDto(
      id: 8,
      kind: SourceKindDto.webDav,
      name: 'legacy',
      addresses: ['https://ao:$legacyPassword@nas:5006/music'],
      rootPath: '',
      options: {},
      enabled: true,
    );

    final draft = SourceDraft.fromConfig(existing);

    expect(draft.username, 'ao');
    expect(draft.secret, isEmpty);
    expect(draft.url, 'https://nas:5006/music');
  });
}
