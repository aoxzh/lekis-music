import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/sources/source_credentials.dart';
import 'package:lekis/src/features/sources/source_draft.dart';
import 'package:lekis/src/features/sources/source_gateway.dart';
import 'package:lekis/src/rust/api/dto.dart';

void main() {
  late _FakeGateway gateway;
  late SourceCredentialService service;
  var refs = 0;

  setUp(() {
    gateway = _FakeGateway();
    refs = 0;
    service = SourceCredentialService(gateway, newRef: () => 'ref-${++refs}');
  });

  SourceConfigDto smbConfig({String? ref = 'ref-existing'}) => SourceConfigDto(
    id: 7,
    kind: SourceKindDto.smb,
    name: 'NAS',
    addresses: const ['smb://nas/music'],
    rootPath: '',
    credentialRef: ref,
    options: const {'username': 'ao'},
    enabled: true,
  );

  test(
    'add writes the credential before the source and keeps it out of config',
    () async {
      final draft = SourceDraft(
        kind: SourceKindDto.smb,
        name: 'NAS',
        host: 'nas',
        share: 'music',
        username: 'ao',
        secret: 'hunter2',
      );

      final id = await service.add(draft);

      expect(id, gateway.nextId);
      expect(gateway.calls, ['set:ref-1', 'add']);
      expect(gateway.credentials['ref-1'], 'hunter2');
      expect(draft.secret, isEmpty);
      final saved = gateway.lastAdded!;
      expect(saved.credentialRef, 'ref-1');
      expect(saved.addresses.single.contains('hunter2'), isFalse);
      expect(saved.options.values.contains('hunter2'), isFalse);
      expect(saved.options['username'], 'ao');
    },
  );

  test('add failure removes the orphan credential', () async {
    gateway.addError = StateError('add failed');
    final draft = SourceDraft(
      kind: SourceKindDto.webDav,
      host: 'nas',
      url: 'https://nas/music',
      username: 'ao',
      secret: 'hunter2',
    );

    await expectLater(service.add(draft), throwsStateError);

    expect(gateway.calls, ['set:ref-1', 'add', 'delete:ref-1']);
    expect(gateway.credentials, isEmpty);
  });

  test('guest SMB saves without any credential', () async {
    final draft = SourceDraft(
      kind: SourceKindDto.smb,
      host: 'nas',
      share: 'music',
      guest: true,
    );

    await service.add(draft);

    expect(gateway.calls, ['add']);
    expect(gateway.lastAdded!.credentialRef, isNull);
    expect(gateway.lastAdded!.options.containsKey('username'), isFalse);
  });

  test('edit without a new password keeps the saved credential', () async {
    final existing = smbConfig();
    gateway.credentials['ref-existing'] = 'old-secret';
    final draft = SourceDraft.fromConfig(existing)..name = 'Living room';

    await service.update(existing, draft);

    expect(gateway.calls, ['update']);
    final updated = gateway.lastUpdated!;
    expect(updated.name, 'Living room');
    expect(updated.credentialRef, 'ref-existing');
    expect(updated.addresses.single, 'smb://nas/music');
    expect(updated.options['username'], 'ao');
    expect(gateway.credentials['ref-existing'], 'old-secret');
  });

  test('replacing the password reuses the same reference', () async {
    final existing = smbConfig();
    gateway.credentials['ref-existing'] = 'old-secret';
    final draft = SourceDraft.fromConfig(existing)..secret = 'new-secret';

    await service.update(existing, draft);

    expect(gateway.calls, ['set:ref-existing', 'update']);
    expect(gateway.credentials['ref-existing'], 'new-secret');
    expect(gateway.lastUpdated!.credentialRef, 'ref-existing');
    expect(draft.secret, isEmpty);
  });

  test(
    'switching to guest updates first, then deletes the old credential',
    () async {
      final existing = smbConfig();
      gateway.credentials['ref-existing'] = 'old-secret';
      final draft = SourceDraft.fromConfig(existing)
        ..guest = true
        ..username = '';

      await service.update(existing, draft);

      expect(gateway.calls, ['update', 'delete:ref-existing']);
      expect(gateway.lastUpdated!.credentialRef, isNull);
      expect(gateway.lastUpdated!.options.containsKey('username'), isFalse);
      expect(gateway.credentials, isEmpty);
    },
  );

  test('delete removes the source before its credential', () async {
    final existing = smbConfig();
    gateway.credentials['ref-existing'] = 'old-secret';

    final cleaned = await service.delete(existing);

    expect(cleaned, isTrue);
    expect(gateway.calls, ['remove:7', 'delete:ref-existing']);
    expect(gateway.credentials, isEmpty);
  });

  test('delete reports a credential cleanup failure without failing the source delete', () async {
    final existing = smbConfig();
    gateway.failDeleteCredential = true;

    final cleaned = await service.delete(existing);

    expect(cleaned, isFalse);
    expect(gateway.calls, ['remove:7', 'delete:ref-existing']);
  });

  test(
    'testDraft uses a temporary reference and removes it afterwards',
    () async {
      final draft = SourceDraft(
        kind: SourceKindDto.jellyfin,
        url: 'http://jellyfin:8096',
        secret: 'api-key',
      );

      await service.testDraft(draft);

      expect(gateway.calls, ['set:ref-1', 'test', 'delete:ref-1']);
      expect(gateway.lastTested!.credentialRef, 'ref-1');
      expect(gateway.lastTested!.addresses.single, 'http://jellyfin:8096');
      expect(gateway.lastTested!.options.values.contains('api-key'), isFalse);
      expect(gateway.credentials, isEmpty);
    },
  );

  test(
    'testing a saved source reads the existing credential by reference',
    () async {
      final existing = smbConfig();
      gateway.credentials['ref-existing'] = 'old-secret';

      await service.test(existing);

      expect(gateway.calls, ['test']);
      expect(gateway.lastTested, same(existing));
      expect(gateway.credentials['ref-existing'], 'old-secret');
    },
  );
}

class _FakeGateway implements SourceGateway {
  final Map<String, String> credentials = {};
  final List<String> calls = [];
  int nextId = 41;
  SourceConfigDto? lastAdded;
  SourceConfigDto? lastUpdated;
  SourceConfigDto? lastTested;
  Object? addError;
  Object? removeError;
  Object? testError;
  bool failDeleteCredential = false;

  @override
  Future<int> addSource(SourceConfigDto source) async {
    calls.add('add');
    if (addError != null) throw addError!;
    lastAdded = source;
    return nextId;
  }

  @override
  Future<void> updateSource(SourceConfigDto source) async {
    calls.add('update');
    lastUpdated = source;
  }

  @override
  Future<void> removeSource(int sourceId) async {
    calls.add('remove:$sourceId');
    if (removeError != null) throw removeError!;
  }

  @override
  Future<void> testSource(SourceConfigDto source) async {
    calls.add('test');
    if (testError != null) throw testError!;
    lastTested = source;
  }

  @override
  Future<List<ShareDto>> listShares(SourceConfigDto source) async {
    calls.add('shares');
    return const [];
  }

  @override
  Future<SourceListingDto> browseSource(
    SourceConfigDto source,
    String path,
  ) async {
    calls.add('browse:$path');
    return const SourceListingDto(folders: [], audioFiles: 0);
  }

  @override
  Future<void> setCredential(String credentialRef, String secret) async {
    calls.add('set:$credentialRef');
    credentials[credentialRef] = secret;
  }

  @override
  Future<void> deleteCredential(String credentialRef) async {
    calls.add('delete:$credentialRef');
    if (failDeleteCredential) throw StateError('delete failed');
    credentials.remove(credentialRef);
  }

  @override
  bool hasCredential(String credentialRef) =>
      credentials.containsKey(credentialRef);
}
