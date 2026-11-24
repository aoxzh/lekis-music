import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class BilibiliVideoRef {
  const BilibiliVideoRef._(this.bvid, this.cid);

  static const pluginId = 'dev.mygo.bilibili';
  static final _externalId = RegExp(
    r'^(BV[0-9A-Za-z]{10})(?:\|([1-9][0-9]*))?$',
  );

  final String bvid;
  final String? cid;

  static BilibiliVideoRef? fromTrackUid(String uid) {
    const prefix = 'plugin:$pluginId:';
    if (!uid.startsWith(prefix)) return null;
    final encoded = uid.substring(prefix.length);
    if (encoded.contains('|')) return null;
    return tryParse(
      sourcePluginId: pluginId,
      externalId: encoded.replaceFirst('%7C', '|'),
    );
  }

  static BilibiliVideoRef? tryParse({
    required String? sourcePluginId,
    required String? externalId,
  }) {
    if (sourcePluginId != pluginId || externalId == null) return null;
    final match = _externalId.firstMatch(externalId);
    if (match == null || match.end != externalId.length) return null;
    return BilibiliVideoRef._(match.group(1)!, match.group(2));
  }

  int? resolvePage({
    required String videoBvid,
    required Map<String, int> pagesByCid,
  }) {
    if (videoBvid != bvid) return null;
    if (cid == null) return 1;
    final page = pagesByCid[cid];
    return page != null && page > 0 ? page : null;
  }

  Future<int> playbackPage({
    HttpClient Function()? createClient,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (cid == null) return 1;
    final client = createClient?.call() ?? HttpClient();
    try {
      client.userAgent = 'Lekis Music';
      return await _fetchPage(client).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException('Bilibili video metadata timed out');
    } on Exception {
      throw const FormatException('Unable to resolve the Bilibili video part');
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _fetchPage(HttpClient client) async {
    final request = await client.getUrl(
      Uri.https('api.bilibili.com', '/x/web-interface/view', {'bvid': bvid}),
    );
    request.followRedirects = false;
    final response = await request.close();
    const maxBytes = 2 * 1024 * 1024;
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > maxBytes) {
      throw const FormatException();
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > maxBytes - bytes.length) throw const FormatException();
      bytes.add(chunk);
    }
    final payload = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (payload
        case {
          'code': 0,
          'data': {'bvid': final String video, 'pages': final List pages},
        }
        when video == bvid) {
      int? matched;
      for (final entry in pages) {
        if (entry case {'cid': final id, 'page': final int page}
            when (id is int || id is String) && id.toString() == cid) {
          if (page <= 0 || (matched != null && matched != page)) {
            throw const FormatException();
          }
          matched = page;
        }
      }
      if (matched != null) return matched;
    }
    throw const FormatException();
  }
}
