import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/rust/api/core.dart' show FolderRootDto;
import 'package:lekis/src/rust/api/dto.dart';

class _Sources extends SourcesNotifier {
  @override
  Future<List<SourceConfigDto>> build() async => [
    for (final (id, kind) in [(1, SourceKindDto.local), (2, SourceKindDto.smb)])
      SourceConfigDto(
        id: id,
        kind: kind,
        name: 'Music',
        addresses: const [],
        rootPath: '',
        options: const {},
        enabled: true,
      ),
  ];
}

void main() {
  test('same-named folder roots are separated by source identity', () async {
    final container = ProviderContainer.test(
      overrides: [
        sourcesProvider.overrideWith(_Sources.new),
        folderRootsProvider.overrideWith(
          (ref) async => [
            for (final id in [1, 2])
              FolderRootDto(sourceId: id, name: 'Music', trackCount: 1),
          ],
        ),
      ],
    );
    for (final (scope, ids) in [
      (const LibraryScope.local(), [1]),
      (const LibraryScope.nas(), [2]),
      (const LibraryScope.plugin('Music'), <int>[]),
    ]) {
      final roots = await container.read(
        scopedFolderRootsProvider(scope).future,
      );
      expect(roots.map((root) => root.sourceId), ids);
    }
  });

  test('folder location splits its path for breadcrumbs', () {
    const location = FolderLocation(
      sourceId: 7,
      sourceName: 'NAS',
      path: 'Artist/Album 10',
    );

    expect(location.name, 'Album 10');
    expect(location.segments, ['Artist', 'Album 10']);
    expect(location.pathAt(0), '');
    expect(location.pathAt(1), 'Artist');
    expect(location.pathAt(2), 'Artist/Album 10');
    expect(folderKeyOf(location), (sourceId: 7, path: 'Artist/Album 10'));
  });

  test('folder root is named after its source', () {
    const location = FolderLocation(sourceId: 7, sourceName: 'NAS', path: '');
    expect(location.name, 'NAS');
    expect(location.segments, isEmpty);
    expect(location.pathAt(0), '');
  });
}
