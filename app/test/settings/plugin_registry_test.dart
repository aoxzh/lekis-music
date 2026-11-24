import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/plugins/plugin_download.dart';
import 'package:lekis/src/features/plugins/plugin_registry.dart';

class _LoopbackClient extends Fake implements HttpClient {
  _LoopbackClient(this.client, this.base);
  final HttpClient client;
  final Uri base;
  final requests = <Uri>[];

  @override
  set connectionTimeout(Duration? _) {}

  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    requests.add(uri);
    return client.getUrl(base.replace(path: uri.path));
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final catalog = Uri.parse('https://registry.test/main/catalog.json');
  const hash =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  final entry = {
    'id': 'source.bilibili',
    'name': 'Bilibili',
    'description': '音源',
    'package': 'packages/bilibili.zip',
    'version': '1.0.0',
    'sha256': hash.toUpperCase(),
  };
  String document(List<Object?> entries) =>
      jsonEncode({'version': 1, 'plugins': entries});

  test('version 1 resolves package paths against the catalog and normalizes the digest', () {
    final plugin = parsePluginRegistry(document([entry]), catalog).single;
    expect(
      plugin.package.toString(),
      'https://registry.test/main/packages/bilibili.zip',
    );
    expect(plugin.sha256, hash);
    expect(parsePluginRegistry(document([]), catalog), isEmpty);
  });

  test(
    'invalid or ambiguous catalogs fail before packages can be selected',
    () {
      for (final invalid in [
        'not JSON',
        '{"version":2,"plugins":[]}',
        document([entry, entry]),
        document([
          {...entry, 'sha256': ''},
        ]),
        document([
          {...entry, 'version': 1},
        ]),
        document([
          {...entry, 'package': 'http://registry.test/plugin.zip'},
        ]),
        document([
          {...entry, 'package': 'https://user@registry.test/plugin.zip'},
        ]),
      ]) {
        expect(
          () => parsePluginRegistry(invalid, catalog),
          throwsFormatException,
        );
      }
    },
  );

  test('remote installer receives only verified bytes and can retry a failed download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = HttpClient();
    addTearDown(() async {
      transport.close(force: true);
      await server.close(force: true);
    });
    var body = 'changed';
    server.listen((request) async {
      if (request.uri.path == '/main/redirect') {
        await request.response.redirect(
          Uri.parse('http://registry.test/insecure'),
        );
        return;
      }
      request.response.write(body);
      await request.response.close();
    });
    final client = _LoopbackClient(
      transport,
      Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final installs = <File>[];
    Future<void> install(String path) async {
      final file = File(path);
      installs.add(file);
      expect(await file.readAsString(), 'abc');
    }

    await HttpOverrides.runZoned(() async {
      final package = catalog.resolve('plugin.zip');
      Future<void> download(Uri uri) => installRemotePluginPackage(
        uri,
        expectedSha256: hash,
        install: install,
      );
      await expectLater(download(package), throwsFormatException);
      expect(installs, isEmpty);
      await expectLater(
        download(catalog.resolve('redirect')),
        throwsA(isA<HttpException>()),
      );
      expect(installs, isEmpty);
      body = 'abc';
      await download(package);
      expect(await installs.single.parent.exists(), isFalse);
      expect(client.requests, [package, catalog.resolve('redirect'), package]);
    }, createHttpClient: (_) => client);
  });
}
