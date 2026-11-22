// 插件管理页的全部双语文案。

import '../../l10n/app_l10n.dart';

abstract final class PluginStrings {
  static String get title => L10n.tr('插件', 'Plugins');
  static String get manageTitle => L10n.tr('本地插件', 'Local Plugins');
  static String get install => L10n.tr('安装插件', 'Install Plugin');
  static String get installFolder => L10n.tr('从文件夹安装', 'Install from Folder');
  static String get installZip => L10n.tr('从 .zip 安装', 'Install from .zip');
  static String get installHint => L10n.tr(
    '插件包根目录需要有 plugin.json，也可以放在唯一的顶层文件夹里。',
    'The package must contain plugin.json at its root or inside a single top-level folder.',
  );
  static String get installCancel => L10n.tr('取消', 'Cancel');
  static String get installed => L10n.tr('插件已安装', 'Plugin installed');
  static String get installFailed => L10n.tr('安装插件失败', 'Failed to install plugin');
  static String get installInvalid =>
      L10n.tr('插件包无效，或这个插件已经安装', 'Invalid plugin package or already installed');
  static String get installNoPath => L10n.tr('没有拿到文件路径', 'No file path selected');
  static String get installFolderUnsupported => L10n.tr(
    'Android 上无法直接读取系统文件夹，请把插件文件夹压缩成 .zip 再安装。',
    'On Android, zip the plugin folder and install from .zip.',
  );

  static String get emptyTitle => L10n.tr('还没有安装插件', 'No Plugins Installed');
  static String get emptyHint => L10n.tr(
    '插件可以添加歌词、封面、音源等能力；安装后会保存在应用的插件目录里。',
    'Plugins add extra lyrics, artwork, or source providers.',
  );
  static String get loadFailed => L10n.tr('读取插件列表失败', 'Failed to load plugins');
  static String get retry => L10n.tr('重试', 'Retry');
  static String get refresh => L10n.tr('刷新', 'Refresh');

  static String get enabled => L10n.tr('已启用', 'Enabled');
  static String get disabled => L10n.tr('已停用', 'Disabled');
  static String get remove => L10n.tr('移除插件', 'Remove Plugin');
  static String get removeTitle => L10n.tr('移除插件？', 'Remove Plugin?');
  static String removeBody(String name) => L10n.tr(
    '将删除“$name”及其插件数据，此操作不可撤销。',
    '"$name" and its data will be removed. This cannot be undone.',
  );
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get confirmRemove => L10n.tr('移除', 'Remove');
  static String get removed => L10n.tr('插件已移除', 'Plugin removed');
  static String get removeFailed => L10n.tr('移除插件失败', 'Failed to remove plugin');
  static String get actionFailed => L10n.tr('操作失败', 'Action failed');

  static String get manifestError => L10n.tr('清单错误', 'Manifest Error');
  static String get invalidManifest => L10n.tr('清单无效', 'Invalid Manifest');
  static String get details => L10n.tr('详情与设置', 'Details & Settings');
  static String get info => L10n.tr('信息', 'Info');
  static const id = 'ID';
  static String get version => L10n.tr('版本', 'Version');
  static String get kind => L10n.tr('类型', 'Type');
  static String get runtime => L10n.tr('运行时', 'Runtime');
  static String get author => L10n.tr('作者', 'Author');
  static String get homepage => L10n.tr('主页', 'Homepage');
  static String get directory => L10n.tr('目录', 'Directory');
  static String get entry => L10n.tr('入口文件', 'Entry');
  static String get permissions => L10n.tr('权限', 'Permissions');
  static String get noPermissions => L10n.tr('无额外权限', 'No extra permissions');
  static String get network => L10n.tr('网络', 'Network');
  static String get requestHeaders => L10n.tr('请求头', 'Request Headers');
  static String get process => L10n.tr('外部程序', 'External Process');
  static String get webSignIn => L10n.tr('网页登录', 'Web Sign-In');
  static String get storage => L10n.tr('存储', 'Storage');
  static String get settings => L10n.tr('插件设置', 'Plugin Settings');
  static String get noSettings =>
      L10n.tr('这个插件没有可配置的设置项。', 'This plugin has no configurable settings.');
  static String get settingsLoadFailed =>
      L10n.tr('读取插件设置失败', 'Failed to load plugin settings');
  static String get saveSettings => L10n.tr('保存设置', 'Save Settings');
  static String get settingsSaved => L10n.tr('插件设置已保存', 'Plugin settings saved');
  static String get settingsFailed =>
      L10n.tr('保存插件设置失败', 'Failed to save plugin settings');
  static String get secretKept =>
      L10n.tr('留空保留已保存的值', 'Leave blank to keep saved value');
  static String get secretSaved => L10n.tr('已保存（不会回显）', 'Saved (hidden)');
  static String get settingKey => L10n.tr('设置键', 'Key');
  static String get help => L10n.tr('帮助', 'Help');

  static String get pluginDir => L10n.tr('插件目录', 'Plugins Folder');
  static String get pluginDirHint => L10n.tr(
    '把插件文件夹或 .zip 放到这里也可以在下次启动时被扫描到。',
    'You can also drop plugin folders or .zip files here for next launch.',
  );
  static String get copyPath => L10n.tr('复制路径', 'Copy Path');
  static String get copied => L10n.tr('已复制', 'Copied');
  static String get openInExplorer => L10n.tr('在资源管理器中打开', 'Open in Explorer');
  static String get close => L10n.tr('关闭', 'Close');

  static String versionLine(String version) =>
      version.isEmpty ? invalidManifest : 'v$version';
  static String installedCount(int count) => count == 0
      ? L10n.tr('未安装插件', 'No plugins installed')
      : L10n.tr(
          '已安装 $count 个插件',
          count == 1 ? '1 plugin installed' : '$count plugins installed',
        );
  static String get settingsEmpty =>
      L10n.tr('这个插件没有声明设置项', 'No settings declared');
}
