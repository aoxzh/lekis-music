// 插件清单字段的展示文案。放在单独文件里，设置页和测试都可以直接用。

import '../../l10n/app_l10n.dart';
import '../../rust/api/dto.dart';
import 'strings.dart';

/// 插件类型的本地化名称。
String pluginKindLabel(String kind) => switch (kind) {
  'source' => L10n.tr('音源', 'Source'),
  'lyrics' => L10n.tr('歌词', 'Lyrics'),
  'artwork' => L10n.tr('封面', 'Artwork'),
  'metadata' => L10n.tr('元数据', 'Metadata'),
  'scrobbler' => L10n.tr('听歌记录', 'Scrobbler'),
  'playlist_importer' => L10n.tr('歌单导入', 'Playlist Importer'),
  'theme' => L10n.tr('主题', 'Theme'),
  'lyrics_style' => L10n.tr('歌词样式', 'Lyrics Style'),
  'visualizer' => L10n.tr('可视化', 'Visualizer'),
  _ => kind.isEmpty ? PluginStrings.invalidManifest : kind,
};

/// 多个类型的展示文案。
String pluginKindsLabel(List<String> kinds) => kinds.isEmpty
    ? PluginStrings.invalidManifest
    : kinds.map(pluginKindLabel).join(' · ');

/// 运行时名称。
String pluginRuntimeLabel(String runtime) => switch (runtime) {
  'js' => 'JavaScript',
  'wasm' => 'WebAssembly',
  'none' => L10n.tr('无代码（主题）', 'No Code (Theme)'),
  _ => runtime.isEmpty ? PluginStrings.invalidManifest : runtime,
};

/// 版本的展示文案。
String pluginVersionLabel(String version) =>
    version.isEmpty ? PluginStrings.invalidManifest : 'v$version';

/// 权限摘要。只展示声明过的能力，不展示请求头的值。
String pluginPermissionSummary(PluginPermissionsDto permissions) {
  final parts = <String>[];
  if (permissions.network.isNotEmpty) {
    parts.add('${PluginStrings.network}：${permissions.network.join('、')}');
  }
  if (permissions.requestHeaderHosts.isNotEmpty) {
    parts.add(
      '${PluginStrings.requestHeaders}：${permissions.requestHeaderHosts.join('、')}',
    );
  }
  if (permissions.process.isNotEmpty) {
    parts.add('${PluginStrings.process}：${permissions.process.join('、')}');
  }
  if (permissions.nativeAndroid) {
    parts.add(L10n.tr('Android 原生扩展', 'Android native extension'));
  }
  if (permissions.webSignIn) parts.add(PluginStrings.webSignIn);
  final storage = _storageLabel(permissions.storageKb);
  if (parts.isEmpty) {
    return '${PluginStrings.noPermissions} · ${PluginStrings.storage} $storage';
  }
  return '${parts.join('；')} · ${PluginStrings.storage} $storage';
}

String _storageLabel(int kb) {
  if (kb >= 1024 && kb % 1024 == 0) return '${kb ~/ 1024} MB';
  return '$kb KB';
}

/// 列表里的一行摘要：版本 · 类型。
String pluginSummaryLine(PluginInfoDto plugin) {
  final kind = pluginKindsLabel(plugin.kinds);
  if (plugin.version.isEmpty) return kind;
  return '${pluginVersionLabel(plugin.version)} · $kind';
}
