// Starts the Rust core with platform paths. Call after `RustLib.init()`.

import 'dart:io';

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
      deviceName: _deviceName(),
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

String _deviceName() {
  try {
    final name = Platform.localHostname.trim();
    if (name.isNotEmpty) return name;
  } on Object {
    // Some sandboxes refuse hostname lookup; fall through.
  }
  return Platform.operatingSystem;
}
