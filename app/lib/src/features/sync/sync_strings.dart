// 多设备同步（SYN-*）的全部文案。

abstract final class SyncStrings {
  static const title = '多设备同步';
  static const hint = '通过 NAS 或共享目录同步喜欢、歌单与听歌记录';
  static const sectionChannel = '同步目录';
  static const channelHint =
      '选择一个所有设备都能访问的文件系统音源（如 NAS 的 SMB / WebDAV 共享）。'
      'Lekis 会在其 .lekis/sync/ 目录下写入增量操作日志，不需要服务器或账号。';
  static const sourceLabel = '用于同步的音源';
  static const sourceNone = '未启用同步';
  static const noFilesystemSources =
      '还没有可用的文件系统音源（本地文件夹 / SMB / WebDAV / NFS / SFTP）。';
  static const addSourceHint = '先在「音源」页添加 NAS 共享目录，再回来这里选择。';

  static const sectionStatus = '同步状态';
  static const syncNow = '立即同步';
  static const syncing = '正在同步…';
  static const idle = '已就绪';
  static const unavailable = '上次同步失败或共享目录不可达';
  static const autoOnLaunch = '启动时自动同步';
  static const autoOnLaunchHint = '打开 Lekis 时自动与所选目录同步一次';
  static const neverSynced = '尚未同步过';
  static const whatIsSyncedTitle = '同步内容';
  static const whatIsSyncedBody =
      '喜欢、1–5 星评分、歌单与排序、播放次数、歌词偏移量与手工标签覆盖；音频文件与本机设置不同步。';

  static String report(int pushed, int pulled, int applied) =>
      '推送 $pushed 条 · 拉取 $pulled 条 · 应用 $applied 项变更';

  static String lastSynced(String summary) => '上次同步：$summary';
  static String failed(String detail) => '同步失败：$detail';
}
