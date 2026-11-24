import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/collection_subscriptions.dart';
import 'package:lekis/src/rust/frb_generated.dart';

class _Settings implements RustLibApi {
  String? value;

  @override
  Future<String?> crateApiCoreGetSetting({required String key}) async => value;

  @override
  Future<void> crateApiCoreSetSetting({
    required String key,
    required String value,
  }) async {
    this.value = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('subscriptions preserve opaque paths and survive reload and simultaneous saves', () async {
    RustLib.initMock(api: _Settings());
    addTearDown(RustLib.dispose);
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final provider = collectionSubscriptionsProvider;
    const first = (plugin: 'one', path: 'chart:/a?b', title: 'Weekly');
    const second = (plugin: 'two', path: 'chart:/a?b', title: 'Singles');
    final subscriptions = container.read(provider.notifier);
    await Future.wait([
      subscriptions.setSubscribed(first, true),
      subscriptions.setSubscribed(second, true),
    ]);
    await subscriptions.setSubscribed(first, true);
    expect(
      await container.refresh(provider.future),
      unorderedEquals([first, second]),
    );
    await container.read(provider.notifier).setSubscribed(first, false);
    expect(await container.refresh(provider.future), [second]);
  });
}
