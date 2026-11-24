import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../rust/api/core.dart' as core;

/// Official "视频播放" compatibility plugin bundled with the app.
const officialVideoPluginId = 'dev.lekis.video-playback';

const _assetRoot = 'assets/plugins/video-playback';
const _entries = ['plugin.json', 'index.js'];

/// Installs the bundled video plugin once and enables it by default.
///
/// Existing installations (including a user-disabled one) are left untouched,
/// so the plugin's own switch keeps working after the first install.
Future<void> ensureOfficialPlugins() async {
  Directory? staging;
  try {
    final installed = await core.plugins();
    if (installed.any((plugin) => plugin.id == officialVideoPluginId)) return;

    final temp = await getTemporaryDirectory();
    staging = Directory(
      '${temp.path}${Platform.pathSeparator}lekis-official-$officialVideoPluginId',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final name in _entries) {
      final content = await rootBundle.loadString('$_assetRoot/$name');
      await File('${staging.path}${Platform.pathSeparator}$name')
          .writeAsString(content);
    }
    await core.installPluginFromPath(path: staging.path);
    await core.setPluginEnabled(pluginId: officialVideoPluginId, enabled: true);
  } catch (error, stack) {
    debugPrint('official plugin install failed: $error\n$stack');
  } finally {
    try {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    } catch (_) {
      // A stale temp directory is harmless; the next run removes it.
    }
  }
}
