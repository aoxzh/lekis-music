// 本地插件列表的状态与操作。真正的工作都在 Rust 侧，这里只负责刷新和错误传递。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/core.dart' as core;
import '../../rust/api/dto.dart';

/// 已安装插件列表。安装 / 移除 / 切换启用后重新读取一次。
final pluginListProvider =
    AsyncNotifierProvider<PluginListNotifier, List<PluginInfoDto>>(
      PluginListNotifier.new,
    );

class PluginListNotifier extends AsyncNotifier<List<PluginInfoDto>> {
  @override
  Future<List<PluginInfoDto>> build() => core.plugins();

  Future<void> reload() async {
    state = const AsyncLoading<List<PluginInfoDto>>();
    state = await AsyncValue.guard(core.plugins);
  }

  /// 从文件夹或 zip 安装，然后刷新列表。
  Future<PluginInfoDto> install(String path) async {
    final plugin = await core.installPluginFromPath(path: path);
    await _reloadData();
    return plugin;
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    await core.setPluginEnabled(pluginId: pluginId, enabled: enabled);
    await _reloadData();
  }

  Future<void> remove(String pluginId) async {
    await core.removePlugin(pluginId: pluginId);
    await _reloadData();
  }

  Future<void> _reloadData() async {
    state = AsyncData(await core.plugins());
  }
}
