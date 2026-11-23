import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/plugins/plugins_providers.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/ui_profile.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

PluginInfoDto source(String id, {String compatibility = 'lekis'}) =>
    PluginInfoDto(
      id: id,
      name: id,
      compatibility: compatibility,
      version: '1',
      apiVersion: '1',
      runtime: 'js',
      kinds: const ['source'],
      entry: 'index.js',
      enabled: true,
      nativeAndroidGranted: false,
      directory: id,
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
  Future<List<PluginInfoDto>> build() async => [source('YouTube')];
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
      'Library source uses original picker and isolates categories desktop=$desktop',
      (tester) async {
        UiProfile.debugOverride = desktop
            ? UiProfile.desktop
            : UiProfile.mobile;
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var sources = [source('YouTube')];
        final container = ProviderContainer.test(
          overrides: [
            librarySourcePluginsProvider.overrideWith((ref) => sources),
          ],
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
        container.read(selectedAlbumProvider.notifier).set(42);
        container.read(selectedArtistProvider.notifier).set(43);
        if (desktop) {
          await tester.tap(
            find.descendant(of: picker, matching: find.byType(OutlinedButton)),
          );
        } else {
          await tester.tap(
            find.descendant(of: picker, matching: find.byType(FilledButton)),
          );
        }
        await tester.pumpAndSettle();
        if (desktop) {
          await tester.tap(
            find.byKey(const ValueKey('settings-choice-YouTube')),
          );
        } else {
          await tester.tap(
            find.byKey(const ValueKey('library-source-YouTube')),
          );
        }
        await tester.pumpAndSettle();
        expect(container.read(effectiveLibrarySourceProvider), 'YouTube');
        expect(container.read(selectedAlbumProvider), isNull);
        expect(container.read(selectedArtistProvider), isNull);
        expect(
          find.byKey(const ValueKey('library-category-select')),
          findsNothing,
        );
        expect(find.byIcon(Icons.sort_rounded), findsNothing);
        expect(
          find.byType(SettingsComboBox<String>),
          desktop ? findsOneWidget : findsNothing,
        );
        sources = [];
        container.invalidate(librarySourcePluginsProvider);
        await tester.pumpAndSettle();
        expect(container.read(effectiveLibrarySourceProvider), isNull);
        expect(
          find.byKey(const ValueKey('library-category-select')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    await tester.pumpWidget(
      app(container, const SearchPage(pluginId: 'YouTube')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Search online music'), findsOneWidget);
    expect(find.text('Browse source'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'YOASOBI');
    await tester.pumpAndSettle();
    expect(requests, contains(('YouTube', 'YOASOBI')));
    expect(find.text('No results for "YOASOBI"'), findsOneWidget);
    expect(container.read(searchQueryProvider), 'standalone query');
    expect(container.read(searchSourceProvider), 'other.source');
  });
}
