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
    expect(
      displayAddress('smb://user@nas/music'),
      'smb://nas/music',
    );
  });
}
