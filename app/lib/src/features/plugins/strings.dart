// 插件管理页的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class PluginStrings {
  static const title = '插件';
  static const manageTitle = '本地插件';
  static const install = '安装插件';
  static const installFolder = '从文件夹安装';
  static const installZip = '从 .zip 安装';
  static const installHint = '插件包根目录需要有 plugin.json，也可以放在唯一的顶层文件夹里。';
  static const installCancel = '取消';
  static const installed = '插件已安装';
  static const installFailed = '安装插件失败';
  static const installInvalid = '插件包无效，或这个插件已经安装';
  static const installNoPath = '没有拿到文件路径';
  static const installFolderUnsupported =
      'Android 上无法直接读取系统文件夹，请把插件文件夹压缩成 .zip 再安装。';

  static const emptyTitle = '还没有安装插件';
  static const emptyHint = '插件可以添加歌词、封面、音源等能力；安装后会保存在应用的插件目录里。';
  static const loadFailed = '读取插件列表失败';
  static const retry = '重试';
  static const refresh = '刷新';

  static const enabled = '已启用';
  static const disabled = '已停用';
  static const remove = '移除插件';
  static const removeTitle = '移除插件？';
  static String removeBody(String name) => '将删除“$name”及其插件数据，此操作不可撤销。';
  static const cancel = '取消';
  static const confirmRemove = '移除';
  static const removed = '插件已移除';
  static const removeFailed = '移除插件失败';
  static const actionFailed = '操作失败';

  static const manifestError = '清单错误';
  static const invalidManifest = '清单无效';
  static const details = '详情与设置';
  static const info = '信息';
  static const id = 'ID';
  static const version = '版本';
  static const kind = '类型';
  static const runtime = '运行时';
  static const author = '作者';
  static const homepage = '主页';
  static const directory = '目录';
  static const entry = '入口文件';
  static const permissions = '权限';
  static const noPermissions = '无额外权限';
  static const network = '网络';
  static const requestHeaders = '请求头';
  static const process = '外部程序';
  static const webSignIn = '网页登录';
  static const storage = '存储';
  static const settings = '插件设置';
  static const noSettings = '这个插件没有可配置的设置项。';
  static const settingsLoadFailed = '读取插件设置失败';
  static const saveSettings = '保存设置';
  static const settingsSaved = '插件设置已保存';
  static const settingsFailed = '保存插件设置失败';
  static const secretKept = '留空保留已保存的值';
  static const secretSaved = '已保存（不会回显）';
  static const settingKey = '设置键';
  static const help = '帮助';

  static const pluginDir = '插件目录';
  static const pluginDirHint = '把插件文件夹或 .zip 放到这里也可以在下次启动时被扫描到。';
  static const copyPath = '复制路径';
  static const copied = '已复制';
  static const openInExplorer = '在资源管理器中打开';
  static const close = '关闭';

  static String versionLine(String version) =>
      version.isEmpty ? invalidManifest : 'v$version';
  static String installedCount(int count) =>
      count == 0 ? '未安装插件' : '已安装 $count 个插件';
  static const settingsEmpty = '这个插件没有声明设置项';
}
