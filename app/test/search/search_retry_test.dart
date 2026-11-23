import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/search/search_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/api/error.dart';
import 'package:lekis/src/rust/frb_generated.dart';

class _UnavailableSource implements RustLibApi {
  var calls = 0;

  @override
  Future<SearchResultsDto> crateApiCoreSearchPlugin({
    required String pluginId,
    required String query,
    required int limit,
  }) async {
    calls++;
    throw const CoreError(
      kind: ErrorKind.plugin,
      detail: 'ContentNotAvailableException: Video unavailable',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('failed source request stays terminal until manual retry', (
    tester,
  ) async {
    final api = _UnavailableSource();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    container
        .read(searchSourceProvider.notifier)
        .set('dev.lekis.youtube-music');
    container
        .read(searchQueryProvider.notifier)
        .set('https://www.youtube.com/watch?v=unavailable');
    final subscription = container.listen(searchResultsProvider, (_, _) {});
    addTearDown(subscription.close);

    await tester.pump(searchDebounce);
    await tester.pump();
    expect(api.calls, 1);
    expect(container.read(searchResultsProvider).hasError, isTrue);
    expect(container.read(searchResultsProvider).isLoading, isFalse);

    // Riverpod's default exponential retry would return this request to a
    // loading state and call the native plugin again during this interval.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(api.calls, 1);
    expect(container.read(searchResultsProvider).hasError, isTrue);
    expect(container.read(searchResultsProvider).isLoading, isFalse);

    container.invalidate(searchResultsProvider);
    await tester.pump();
    await tester.pump(searchDebounce);
    await tester.pump();
    expect(api.calls, 2);
    expect(container.read(searchResultsProvider).hasError, isTrue);
    expect(container.read(searchResultsProvider).isLoading, isFalse);
  });
}
