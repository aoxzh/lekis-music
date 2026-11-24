import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.lekis/bilibili_video');
final _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');

Future<void> openBilibiliVideo({required String bvid, required int page}) async {
  if (bvid.length != 12 || !_bvidPattern.hasMatch(bvid)) {
    throw ArgumentError.value(bvid, 'bvid', 'Expected a Bilibili BV ID');
  }
  if (page < 1) {
    throw RangeError.range(page, 1, null, 'page');
  }
  await _channel.invokeMethod<void>('open', {'bvid': bvid, 'page': page});
}
