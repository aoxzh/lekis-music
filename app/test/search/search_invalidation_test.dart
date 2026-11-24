import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';

final _results = SearchResultsDto(
  tracks: [
    TrackRowDto(
      id: 1,
      title: 'Evening light',
      artistLine: 'Demo artist',
      durationMs: BigInt.from(208000),
      loved: false,
      isLocal: false,
    ),
  ],
  albums: [],
  artists: [],
);

class _Api implements RustLibApi {
  _Api(this.events);

  final StreamController<CoreEventDto> events;
  var pluginCalls = 0;
  var libraryCalls = 0;

  @override
  Future<SearchResultsDto> crateApiCoreSearch({
    required String text,
    required int limit,
  }) async {
    libraryCalls++;
    return _results;
  }

  @override
  Future<SearchResultsDto> crateApiCoreSearchPlugin({
    required String pluginId,
    required String query,
    required int limit,
  }) async {
    pluginCalls++;
    // The core imports source rows and reports the catalog change before the
    // search future completes.
    events.add(
      const CoreEventDto.libraryChanged(scope: LibraryScopeDto.catalog),
    );
    return _results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    _Api api,
    String? source,
  ) async {
    final container = ProviderContainer.test(
      overrides: [coreEventSourceProvider.overrideWithValue(api.events.stream)],
    );
    container.read(searchSourceProvider.notifier).set(source);
    container.read(searchQueryProvider.notifier).set('evening');
    container.listen(searchResultsProvider, (_, _) {});
    await tester.pump(searchDebounce);
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('source search ignores the catalog change it causes itself', (
    tester,
  ) async {
    final events = StreamController<CoreEventDto>.broadcast();
    addTearDown(events.close);
    final api = _Api(events);
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);

    final container = await mount(tester, api, 'dev.mygo.bilibili');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }

    expect(api.pluginCalls, 1);
    expect(container.read(searchResultsProvider).value, _results);
    expect(container.read(searchResultsProvider).isLoading, isFalse);
  });

  testWidgets('library search still refreshes on catalog changes', (
    tester,
  ) async {
    final events = StreamController<CoreEventDto>.broadcast();
    addTearDown(events.close);
    final api = _Api(events);
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);

    await mount(tester, api, null);
    expect(api.libraryCalls, 1);

    events.add(
      const CoreEventDto.libraryChanged(scope: LibraryScopeDto.catalog),
    );
    await tester.pump();
    await tester.pump(searchDebounce);
    await tester.pump();

    expect(api.libraryCalls, 2);
  });
}
