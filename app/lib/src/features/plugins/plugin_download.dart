import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'strings.dart';

Uri? pluginPackageUri(String address) {
  final uri = Uri.tryParse(address.trim());
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

Future<T> readPluginResource<T>(
  Uri uri, {
  required int byteLimit,
  required Future<T> Function(Uri, Stream<List<int>>) read,
}) async {
  if (pluginPackageUri(uri.toString()) == null) {
    throw const FormatException('Expected an HTTPS URL');
  }
  const timeout = Duration(seconds: 30);
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    var current = uri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = await client.getUrl(current).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        final next = location == null
            ? null
            : pluginPackageUri(current.resolve(location).toString());
        if (next == null || redirects == 5) {
          throw const HttpException('Invalid HTTPS redirect');
        }
        await response.listen(null).cancel();
        current = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.contentLength > byteLimit) {
        throw FormatException('Download exceeds $byteLimit bytes');
      }
      var bytes = 0;
      return await read(
        current,
        response.timeout(timeout).map((chunk) {
          bytes += chunk.length;
          if (bytes > byteLimit) {
            throw FormatException('Download exceeds $byteLimit bytes');
          }
          return chunk;
        }),
      );
    }
    throw const HttpException('Too many redirects');
  } finally {
    client.close(force: true);
  }
}

Future<void> downloadPluginPackage(
  Uri uri,
  File destination, {
  String? expectedSha256,
}) async {
  await readPluginResource<void>(
    uri,
    byteLimit: 128 * 1024 * 1024,
    read: (_, chunks) => chunks.pipe(destination.openWrite()),
  );
  if (expectedSha256 == null) return;
  final digest = await crypto.sha256.bind(destination.openRead()).first;
  if (digest.toString() != expectedSha256.toLowerCase()) {
    throw FormatException(PluginStrings.checksumMismatch);
  }
}

Future<void> installRemotePluginPackage(
  Uri uri, {
  String? expectedSha256,
  required Future<void> Function(String path) install,
}) async {
  final temporary = await Directory.systemTemp.createTemp('lekis-plugin-');
  try {
    final zip = File.fromUri(temporary.uri.resolve('package.zip'));
    await downloadPluginPackage(uri, zip, expectedSha256: expectedSha256);
    await install(zip.path);
  } finally {
    await temporary.delete(recursive: true);
  }
}
