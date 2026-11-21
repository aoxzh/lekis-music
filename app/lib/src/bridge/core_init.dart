// Starts the Rust core with platform paths. Call after `RustLib.init()`.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:lekis/src/rust/api/core.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// Resolves app directories and initialises the core (idempotent on the
/// Rust side; repeated calls return immediately).
Future<void> initLekisCore() async {
  // 测试用：--dart-define=LEKIS_DATA_DIR=<目录> 换一个数据库（例如 10 万首假歌的性能测试库）。
  const dataDirOverride = String.fromEnvironment('LEKIS_DATA_DIR');
  final dataDir = dataDirOverride.isNotEmpty
      ? Directory(dataDirOverride)
      : await getApplicationSupportDirectory();
  final cacheDir = await getApplicationCacheDirectory();
  await Future.wait([
    dataDir.create(recursive: true),
    cacheDir.create(recursive: true),
  ]);

  await initCore(
    config: CoreConfigDto(
      dataDir: dataDir.path,
      cacheDir: cacheDir.path,
      deviceName: await _deviceName(),
      platform: _platform(),
    ),
  );
}

/// Cache directory path, for resolving relative artwork paths from the core.
/// Resolved once and memoised.
Future<String> lekisCacheDir() =>
    _cacheDir ??= getApplicationCacheDirectory().then((d) => d.path);
Future<String>? _cacheDir;

PlatformDto _platform() {
  if (Platform.isAndroid) return PlatformDto.android;
  if (Platform.isWindows) return PlatformDto.windows;
  return PlatformDto.linux;
}

Future<String> _deviceName() async {
  if (Platform.isAndroid) {
    // Android 的主机名对每个 App 都是 "localhost"：问系统要用户起的设备名。
    try {
      final name = await const MethodChannel(
        'dev.lekis.lekis/discovery',
      ).invokeMethod<String>('deviceName');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } on Object {
      // 通道不可用（测试环境）时走下面的兜底。
    }
  }
  try {
    final name = Platform.localHostname.trim();
    if (name.isNotEmpty && name.toLowerCase() != 'localhost') return name;
  } on Object {
    // Some sandboxes refuse hostname lookup; fall through.
  }
  return Platform.isAndroid ? 'Android 设备' : Platform.operatingSystem;
}
