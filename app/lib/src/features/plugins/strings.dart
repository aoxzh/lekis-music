// 插件管理页的全部双语文案。

import '../../l10n/app_l10n.dart';

abstract final class PluginStrings {
  static String get title => L10n.tr('插件', 'Plugins');
  static String get manageTitle => L10n.tr('本地插件', 'Local Plugins');
  static String get install => L10n.tr('安装插件', 'Install Plugin');
  static String get installFolder => L10n.tr('从文件夹安装', 'Install from Folder');
  static String get installZip => L10n.tr('从 .zip 安装', 'Install from .zip');
  static String get importSource =>
      L10n.tr('导入在线音源', 'Import an online source');
  static String get installLink => L10n.tr('从链接安装', 'Install from link');
  static String get browse => L10n.tr('浏览插件目录', 'Browse plugin catalog');
  static String get catalogTitle => L10n.tr('可安装插件', 'Plugin catalog');
  static String get defaultSource =>
      L10n.tr('默认社区目录', 'Default community catalog');
  static String get addSource => L10n.tr('添加插件源', 'Add plugin source');
  static String get sourceUrlLabel =>
      L10n.tr('插件目录 HTTPS 地址', 'Plugin catalog HTTPS URL');
  static String get sourceUrlHint => L10n.tr(
    'https://example.com/catalog.json',
    'https://example.com/catalog.json',
  );
  static String get sourceInvalid => L10n.tr(
    '插件源地址无效，或已经添加过了',
    'Invalid plugin source URL, or it is already added',
  );
  static String get sourceAdded => L10n.tr('插件源已添加', 'Plugin source added');
  static String get sourceRemoved => L10n.tr('插件源已移除', 'Plugin source removed');
  static String get removeSource => L10n.tr('移除插件源', 'Remove plugin source');
  static String get sourceLoadFailed =>
      L10n.tr('无法读取插件源', 'Could not load plugin source');
  static String get sourceEmpty =>
      L10n.tr('这个插件源暂无插件', 'This plugin source has no plugins');
  static String get catalogLoading =>
      L10n.tr('正在读取插件目录…', 'Loading plugin catalog…');
  static String get catalogFailed =>
      L10n.tr('无法读取插件目录', 'Could not load the plugin catalog');
  static String get catalogEmpty => L10n.tr('目录中暂无插件', 'The catalog is empty');
  static String get downloadInstall => L10n.tr('下载并安装', 'Download and install');
  static String get checksumMismatch => L10n.tr(
    '插件包的 SHA-256 与目录不符，已停止安装。',
    'The package SHA-256 does not match the catalog. Installation stopped.',
  );
  static String get providerNotice => L10n.tr(
    '插件均由社区第三方制作和维护，不是月兔音乐官方提供。月兔音乐与插件的内容权益方（如哔哩哔哩）均与插件无任何隶属、合作或背书关系；插件的内容与服务由插件作者和相应权益方负责。',
    'Plugins are made and maintained by third-party community contributors, not by Lekis Music. Neither Lekis Music nor any content rights holder (such as Bilibili) is affiliated with, endorses, or is connected to these plugins; the plugin author and the respective rights holders are responsible for the content and services they provide.',
  );
  static String get sourceHint => L10n.tr(
    '安装音源插件后，可在「搜索」中选择对应音源。也可以使用插件作者提供的 ZIP 安装包或 HTTPS 下载链接。',
    'After installing a source plugin, select it in Search. You can also install a ZIP or use an HTTPS link from the plugin author.',
  );
  static String get installHint => L10n.tr(
    '插件包根目录需要有 plugin.json，也可以放在唯一的顶层文件夹里。',
    'The package must contain plugin.json at its root or inside a single top-level folder.',
  );
  static String get installCancel => L10n.tr('取消', 'Cancel');
  static String get installed => L10n.tr('插件已安装', 'Plugin installed');
  static String get installFailed =>
      L10n.tr('安装插件失败', 'Failed to install plugin');
  static String get installInvalid =>
      L10n.tr('插件包无效，或这个插件已经安装', 'Invalid plugin package or already installed');
  static String get installNoPath =>
      L10n.tr('没有拿到文件路径', 'No file path selected');
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
  static String get removeFailed =>
      L10n.tr('移除插件失败', 'Failed to remove plugin');
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
  static String get settingsSaved =>
      L10n.tr('插件设置已保存', 'Plugin settings saved');
  static String get settingsFailed =>
      L10n.tr('保存插件设置失败', 'Failed to save plugin settings');
  static String get secretKept =>
      L10n.tr('留空保留已保存的值', 'Leave blank to keep saved value');
  static String get secretSaved => L10n.tr('已保存（不会回显）', 'Saved (hidden)');
  static String get settingKey => L10n.tr('设置键', 'Key');
  static String get help => L10n.tr('帮助', 'Help');

  static String get pluginDir => L10n.tr('本地插件文件夹', 'Local plugins folder');
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
