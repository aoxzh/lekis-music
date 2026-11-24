import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/cover_flow_page.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

PluginInfoDto source(String name, {bool enabled = true}) => PluginInfoDto(
  id: 'test.${name.toLowerCase()}',
  name: name,
  compatibility: 'lekis',
  version: '1',
  apiVersion: '1',
  runtime: 'js',
  kinds: const ['source'],
  entry: 'index.js',
  enabled: enabled,
  nativeAndroidGranted: false,
  directory: name,
  permissions: const PluginPermissionsDto(
    network: [],
    process: [],
    requestHeaderHosts: [],
    webSignIn: false,
    nativeAndroid: false,
    storageKb: 1024,
  ),
  settings: const [],
);

class Sources extends PluginListNotifier {
  @override
  Future<List<PluginInfoDto>> build() async => [
    source('YouTube'),
    source('Bilibili'),
  ];

  void loading() => state = const AsyncLoading();

  void replace(List<PluginInfoDto> plugins) => state = AsyncData(plugins);
}

Widget app(ProviderContainer container, Widget child, {double scale = 1}) =>
    UncontrolledProviderScope(
      container: container,
      child: LekisLocale(
        locale: const Locale('en'),
        child: MaterialApp(
          theme: lekisLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      ),
    );

void main() {
  tearDown(() => UiProfile.debugOverride = null);
  for (final desktop in [false, true]) {
    testWidgets(
      'the title selects local, NAS and individual plugins desktop=$desktop',
      (tester) async {
        UiProfile.debugOverride = desktop
            ? UiProfile.desktop
            : UiProfile.mobile;
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final sources = Sources();
        final container = ProviderContainer.test(
          overrides: [pluginListProvider.overrideWith(() => sources)],
        );
        await tester.pumpWidget(
          app(container, const LibraryHeader(), scale: 2),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library-category-select')),
          findsOneWidget,
        );
        final picker = find.byKey(const ValueKey('library-source-select'));
        expect(picker, findsOneWidget);
        expect(tester.takeException(), isNull);
        Future<void> select(String label) async {
          await tester.tap(find.byKey(const ValueKey('library-title')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: picker, matching: find.text(label)),
            findsOneWidget,
          );
        }

        await select('NAS');
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.nas(),
        );
        container.read(selectedAlbumProvider.notifier).set(42);
        container.read(selectedArtistProvider.notifier).set(43);
        container
            .read(selectedFolderProvider.notifier)
            .set(
              const FolderLocation(
                sourceId: 8,
                sourceName: 'NAS',
                path: 'Jazz',
              ),
            );
        await select('YouTube');
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.plugin('test.youtube'),
        );
        expect(container.read(selectedAlbumProvider), isNull);
        expect(container.read(selectedArtistProvider), isNull);
        expect(container.read(selectedFolderProvider), isNull);
        expect(
          find.byKey(const ValueKey('library-category-select')),
          findsOneWidget,
        );
        expect(find.byTooltip('Search online music'), findsOneWidget);
        await select('Bilibili');
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.plugin('test.bilibili'),
        );
        sources.loading();
        await tester.pumpAndSettle();
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.plugin('test.bilibili'),
        );
        sources.replace([
          source('YouTube'),
          if (desktop) source('Bilibili', enabled: false),
        ]);
        await tester.pumpAndSettle();
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.local(),
        );
        expect(
          find.descendant(of: picker, matching: find.text('Local Library')),
          findsOneWidget,
        );
        expect(find.byTooltip('Search online music'), findsNothing);
        expect(
          find.byKey(const ValueKey('library-category-select')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('library-title')));
        await tester.pumpAndSettle();
        sources.replace([]);
        await tester.pumpAndSettle();
        await tester.tap(find.text('YouTube'));
        await tester.pumpAndSettle();
        expect(
          container.read(effectiveLibrarySourceProvider),
          const LibraryScope.local(),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the current category and cover flow follow the title source', (
    tester,
  ) async {
    final container = ProviderContainer.test(
      overrides: [
        pluginListProvider.overrideWith(Sources.new),
        scopedLibraryTracksProvider.overrideWith((ref, scope) async => []),
        scopedAlbumPageProvider.overrideWith(
          (ref, query) =>
              (offset, limit) async => [
                if (offset == 0)
                  AlbumDto(
                    id: 1,
                    title: '${query.$1.pluginId ?? query.$1.kind.name} album',
                    artistLine: '',
                    trackCount: 1,
                  ),
              ],
        ),
        albumArtworkProvider.overrideWith((ref, id) async => null),
      ],
    );
    await tester.pumpWidget(app(container, const LibraryPage()));
    await tester.pumpAndSettle();
    ScopedLibraryView body() =>
        tester.widget<ScopedLibraryView>(find.byType(ScopedLibraryView));
    expect(body().scope, const LibraryScope.local());
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    for (final (label, scope) in [
      ('NAS', const LibraryScope.nas()),
      ('Bilibili', const LibraryScope.plugin('test.bilibili')),
    ]) {
      await tester.tap(find.byKey(const ValueKey('library-title')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(body().scope, scope);
      expect(body().segment, LibrarySegment.artists);
    }
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cover Flow'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CoverFlowPage>(find.byType(CoverFlowPage)).scope,
      const LibraryScope.plugin('test.bilibili'),
    );
    expect(find.text('test.bilibili album'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(body().scope, const LibraryScope.plugin('test.bilibili'));
    expect(body().segment, LibrarySegment.albums);
  });

  testWidgets('Library YouTube search is real and independent of Search tab', (
    tester,
  ) async {
    final requests = <(String, String)>[];
    final container = ProviderContainer.test(
      overrides: [
        pluginListProvider.overrideWith(Sources.new),
        searchQueryProvider.overrideWith(() => SimpleValue('standalone query')),
        searchSourceProvider.overrideWith(
          () => SimpleValue<String?>('other.source'),
        ),
        librarySourceSearchProvider.overrideWith((ref, request) async {
          requests.add(request);
          return const SearchResultsDto(tracks: [], albums: [], artists: []);
        }),
      ],
    );
    await tester.pumpWidget(app(container, const LibraryHeader()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YouTube'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search online music'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SearchPage>(find.byType(SearchPage)).pluginId,
      'test.youtube',
    );
    expect(find.text('Search online music'), findsOneWidget);
    expect(find.text('Browse source'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'YOASOBI');
    await tester.pumpAndSettle();
    expect(requests, contains(('test.youtube', 'YOASOBI')));
    expect(find.text('No results for "YOASOBI"'), findsOneWidget);
    expect(container.read(searchQueryProvider), 'standalone query');
    expect(container.read(searchSourceProvider), 'other.source');
  });
}
