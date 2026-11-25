import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/sources/sources_providers.dart';
import 'package:lekis/src/rust/api/core.dart'
    show FolderRootDto, FolderListingDto, FolderEntryDto;
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

  testWidgets(
    'folder menus and breadcrumbs keep the parent route and its scroll offset',
    (tester) async {
      final container = ProviderContainer.test(
        overrides: [
          scopedFolderRootsProvider.overrideWith(
            (ref, scope) async => [
              const FolderRootDto(sourceId: 1, name: 'Music', trackCount: 30),
            ],
          ),
          folderListingProvider.overrideWith(
            (ref, key) async => FolderListingDto(
              folders: key.path.isEmpty
                  ? [
                      for (var i = 0; i < 30; i++)
                        FolderEntryDto(
                          name: 'Disc $i',
                          path: 'Disc $i',
                          trackCount: 1,
                        ),
                    ]
                  : const [],
              trackCount: 0,
            ),
          ),
          folderTracksListProvider.overrideWith((ref, key) {
            final list = PagedList<TrackRowDto>(fetch: (_, _) async => []);
            ref.onDispose(list.dispose);
            return list;
          }),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const Scaffold(body: FoldersView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openFolder(String name) async {
        await tester.tap(find.byTooltip('更多操作：$name'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开文件夹'));
        await tester.pumpAndSettle();
      }

      await openFolder('Music');
      final menu = find.byTooltip('更多操作：Disc 20');
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      final before = tester.getCenter(menu);
      await openFolder('Disc 20');
      expect(find.text('没有子文件夹'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.getCenter(menu), before);
      await openFolder('Disc 20');
      await tester.tap(find.widgetWithText(TextButton, '音源'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作：Music'), findsOneWidget);
    },
  );

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
