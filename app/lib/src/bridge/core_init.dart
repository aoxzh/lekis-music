// Starts the Rust core with platform paths. Call after `RustLib.init()`.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart';
import 'package:lekis/src/rust/api/dto.dart';

/// Dev / screenshot overrides: `--dart-define=LEKIS_DATA_DIR=<dir>` swaps the
/// database and `LEKIS_CACHE_DIR=<dir>` keeps its artwork cache self-contained.
/// Both are empty in normal builds.
const _dataDirOverride = String.fromEnvironment('LEKIS_DATA_DIR');
const _cacheDirOverride = String.fromEnvironment('LEKIS_CACHE_DIR');

/// Resolves app directories and initialises the core (idempotent on the
/// Rust side; repeated calls return immediately).
Future<void> initLekisCore() async {
  // 三个平台查询互不依赖；Android 上每次都是独立的 method-channel 往返，
  // 并行解析可以缩短首帧前的串行等待。
  final resolved = await Future.wait<Object>([
    _dataDirOverride.isNotEmpty
        ? Future<Directory>.value(Directory(_dataDirOverride))
        : getApplicationSupportDirectory(),
    _cacheDirOverride.isNotEmpty
        ? Future<Directory>.value(Directory(_cacheDirOverride))
        : getApplicationCacheDirectory(),
    _deviceName(),
  ]);
  final dataDir = resolved[0] as Directory;
  final cacheDir = resolved[1] as Directory;
  final deviceName = resolved[2] as String;
  await Future.wait([
    dataDir.create(recursive: true),
    cacheDir.create(recursive: true),
  ]);

  await initCore(
    config: CoreConfigDto(
      dataDir: dataDir.path,
      cacheDir: cacheDir.path,
      deviceName: deviceName,
      platform: _platform(),
    ),
  );
}

/// Cache directory path, for resolving relative artwork paths from the core.
/// Resolved once and memoised.
Future<String> lekisCacheDir() =>
    _cacheDir ??= (_cacheDirOverride.isNotEmpty
            ? Future<String>.value(_cacheDirOverride)
            : getApplicationCacheDirectory().then((d) => d.path));
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
      final name = await const MethodChannel('dev.lekis.lekis/discovery')
          .invokeMethod<String>('deviceName');
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
  return Platform.isAndroid
      ? L10n.tr('Android 设备', 'Android Device')
      : Platform.operatingSystem;
}
