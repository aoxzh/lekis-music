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
}
