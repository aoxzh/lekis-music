import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/plugin_sources.dart';

void main() {
  group('normalizePluginSourceUrl', () {
    test('accepts HTTPS catalogs', () {
      expect(
        normalizePluginSourceUrl(' https://example.com/catalog.json '),
        'https://example.com/catalog.json',
      );
      expect(
        normalizePluginSourceUrl('https://example.com/a/b?x=1'),
        'https://example.com/a/b?x=1',
      );
    });

    test('rejects plain HTTP, credentials and empty hosts', () {
      expect(
        normalizePluginSourceUrl('http://example.com/catalog.json'),
        isNull,
      );
      expect(
        normalizePluginSourceUrl('https://user:pass@example.com/catalog.json'),
        isNull,
      );
      expect(normalizePluginSourceUrl('https:///catalog.json'), isNull);
      expect(normalizePluginSourceUrl('not a url'), isNull);
      expect(normalizePluginSourceUrl('   '), isNull);
    });
  });

  group('parsePluginSourceUrls', () {
    test('reads valid URLs and drops malformed entries', () {
      expect(
        parsePluginSourceUrls(
          '["https://a.example/catalog.json","http://b.example/catalog.json",'
          '"https://a.example/catalog.json","https://c.example/catalog.json"]',
        ),
        ['https://a.example/catalog.json', 'https://c.example/catalog.json'],
      );
    });

    test('returns an empty list for missing or invalid content', () {
      expect(parsePluginSourceUrls(null), isEmpty);
      expect(parsePluginSourceUrls(''), isEmpty);
      expect(parsePluginSourceUrls('not json'), isEmpty);
      expect(parsePluginSourceUrls('{"url":"https://a.example"}'), isEmpty);
      expect(parsePluginSourceUrls('[1, true, null]'), isEmpty);
    });
  });

  group('built-in catalog switch', () {
    test('defaults to on; only an explicit false turns it off', () {
      expect(kPluginBuiltinSourceEnabledKey, 'plugins.builtinSource.enabled');
      expect(parsePluginBuiltinSourceEnabled(null), isTrue);
      expect(parsePluginBuiltinSourceEnabled(''), isTrue);
      expect(parsePluginBuiltinSourceEnabled('true'), isTrue);
      expect(parsePluginBuiltinSourceEnabled('garbage'), isTrue);
      expect(parsePluginBuiltinSourceEnabled('false'), isFalse);
      expect(parsePluginBuiltinSourceEnabled(' FALSE '), isFalse);
    });

    test('off drops the built-in source but keeps custom ones', () async {
      final container = ProviderContainer.test();
      expect(await container.read(pluginBuiltinSourceEnabledProvider.future),
          isTrue);
      var sources = await container.read(pluginSourcesProvider.future);
      expect(sources.single.builtIn, isTrue);

      final notifier = container.read(pluginSourcesProvider.notifier);
      expect(await notifier.add('https://mirror.example/catalog.json'), isTrue);
      await container
          .read(pluginBuiltinSourceEnabledProvider.notifier)
          .setEnabled(false);
      sources = await container.read(pluginSourcesProvider.future);
      expect(sources.map((s) => s.builtIn), [false]);
      expect(sources.single.url, 'https://mirror.example/catalog.json');

      // The built-in URL cannot sneak back in as a custom source.
      expect(
        await container
            .read(pluginSourcesProvider.notifier)
            .add(defaultPluginSourceUrl),
        isFalse,
      );
    });
  });
}
