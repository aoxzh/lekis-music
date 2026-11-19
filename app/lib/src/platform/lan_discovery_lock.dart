// Android 上接收 mDNS / SSDP 组播需要 WifiManager.MulticastLock。
//
// 这里只做「尽量持有」：没有 Wi-Fi、系统不允许、通道不可用时都静默继续，
// 发现仍然会跑，只是可能少收几个组播包。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('dev.lekis.lekis/discovery');

bool get _needsLock => !kIsWeb && Platform.isAndroid;

/// 在 [body] 运行期间持有 Android 组播锁；其他平台直接运行。
Future<T> withLanMulticastLock<T>(Future<T> Function() body) async {
  if (!_needsLock) return body();
  final held = await _invoke('acquire');
  try {
    return await body();
  } finally {
    if (held) await _invoke('release');
  }
}

Future<bool> _invoke(String method) async {
  try {
    return await _channel.invokeMethod<bool>(method) ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (e) {
    debugPrint('lan discovery: multicast lock $method failed: ${e.message}');
    return false;
  }
}
