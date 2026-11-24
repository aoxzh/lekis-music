import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/player/bilibili_video_ref.dart';

void main() {
  const video = 'BV1Ab2Cd3Ef4';
  BilibiliVideoRef? parse(String? externalId) => BilibiliVideoRef.tryParse(
    sourcePluginId: 'dev.mygo.bilibili',
    externalId: externalId,
  );

  test('bare plugin ID preserves BV case and selects the default part', () {
    final ref = parse(video)!;
    expect(ref.bvid, video);
    expect(ref.cid, isNull);
    expect(ref.resolvePage(videoBvid: video, pagesByCid: {}), 1);
  });

  test('CID stays exact and resolves by identity, independent of order', () {
    const cid = '9007199254740993';
    final ref = parse('$video|$cid')!;
    expect(ref.bvid, video);
    expect(ref.cid, cid);
    expect(ref.resolvePage(videoBvid: video, pagesByCid: {cid: 3, '8': 1}), 3);
  });

  test('unmatched or invalid page metadata never defaults to part one', () {
    final ref = parse('$video|42')!;
    expect(
      ref.resolvePage(videoBvid: 'BV9Ab2Cd3Ef4', pagesByCid: {'42': 2}),
      isNull,
    );
    expect(ref.resolvePage(videoBvid: video, pagesByCid: {'2': 42}), isNull);
    expect(ref.resolvePage(videoBvid: video, pagesByCid: {'42': 0}), isNull);
  });

  test('only the normalized Bilibili source can identify a video', () {
    for (final source in [null, '', 'Bilibili', 'bilibili', 'dev.mygo.other']) {
      expect(
        BilibiliVideoRef.tryParse(sourcePluginId: source, externalId: video),
        isNull,
      );
    }
  });

  test('rejects malformed IDs, display text and URL-shaped input', () {
    for (final value in [
      null,
      '',
      'av123',
      'bv1Ab2Cd3Ef4',
      '${video}x',
      'BV123',
      '$video|',
      '$video|0',
      '$video|-3',
      '$video|2|3',
      '$video|01',
      '$video\n',
      'P2 $video',
      'https://example.invalid/video/$video?p=2',
    ]) {
      expect(parse(value), isNull);
    }
  });

  test('reads only the canonical Rust Bilibili track UID', () {
    const prefix = 'plugin:dev.mygo.bilibili:';
    expect(BilibiliVideoRef.fromTrackUid('$prefix$video')!.bvid, video);
    expect(BilibiliVideoRef.fromTrackUid('$prefix$video%7C987')!.cid, '987');
    for (final uid in [
      'server:1:$video',
      'plugin:dev.mygo.other:$video',
      '$prefix$video|987',
      '$prefix$video%257C987',
      '$prefix$video%7C7%7C8',
      '$prefix$video%',
      '$prefix%42${video.substring(1)}',
      '$prefix$video%7C0',
    ]) {
      expect(BilibiliVideoRef.fromTrackUid(uid), isNull);
    }
  });

  test('default part needs no metadata request', () async {
    expect(
      await parse(video)!
          .playbackPage(createClient: () => fail('unexpected request')),
      1,
    );
  });

  const cid = '9007199254740993';
  Future<int> fetch(
    _Response response, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final client = _Client(response);
    try {
      return await parse('$video|$cid')!
          .playbackPage(createClient: () => client, timeout: timeout);
    } finally {
      expect(
        client.uri,
        Uri.https('api.bilibili.com', '/x/web-interface/view', {'bvid': video}),
      );
      expect(client.request.followRedirects, isFalse);
      expect(client.forceClosed, isTrue);
    }
  }

  _Response metadata(
    List<Object?> pages, {
    String bvid = video,
    int code = 0,
  }) => _Response(
    Stream.value(
      utf8.encode(
        jsonEncode({
          'code': code,
          'data': {'bvid': bvid, 'pages': pages},
        }),
      ),
    ),
  );

  test(
    'official metadata uses exact CID and explicit page, not array index',
    () async {
      for (final id in [cid, int.parse(cid)]) {
        expect(
          await fetch(
            metadata([
              {'cid': id, 'page': 17},
              {'cid': 9007199254740992, 'page': 1},
            ]),
          ),
          17,
        );
      }
    },
  );

  test(
    'rejects missing, contradictory, wrong-video and failed metadata',
    () async {
      final part = {'cid': cid, 'page': 2};
      for (final response in [
        metadata([]),
        metadata([part], code: -1),
        metadata([part], bvid: 'BV9Ab2Cd3Ef4'),
        metadata([
          {'cid': 9007199254740992, 'page': 1},
        ]),
        metadata([
          {'cid': cid, 'page': 0},
        ]),
        metadata([
          part,
          {'cid': cid, 'page': 3},
        ]),
        _Response(Stream.value([0xff])),
        _Response(const Stream.empty(), statusCode: 302),
      ]) {
        await expectLater(fetch(response), throwsFormatException);
      }
    },
  );

  test('bounds declared and streamed sizes before parsing', () async {
    const limit = 2 * 1024 * 1024;
    Stream<List<int>> unread() async* {
      fail('body must stay unread');
    }

    await expectLater(
      fetch(_Response(unread(), contentLength: limit + 1)),
      throwsFormatException,
    );
    Stream<List<int>> chunks() async* {
      yield Uint8List(limit);
      yield [0];
      fail('must stop at the size limit');
    }

    await expectLater(fetch(_Response(chunks())), throwsFormatException);
  });

  test('a stalled body hits the deadline and closes the client', () async {
    final stalled = StreamController<List<int>>();
    try {
      await expectLater(
        fetch(
          _Response(stalled.stream),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await stalled.close();
    }
  });
}

class _Client extends Fake implements HttpClient {
  _Client(_Response response) : request = _Request(response);
  final _Request request;
  Uri? uri;
  bool forceClosed = false;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uri = url;
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final _Response response;
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(super.stream, {this.statusCode = 200, this.contentLength = -1});
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
