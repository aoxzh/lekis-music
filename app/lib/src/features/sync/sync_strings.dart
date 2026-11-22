// 多设备同步（SYN-*）的全部文案（中英双语）。

import '../../l10n/app_l10n.dart';

abstract final class SyncStrings {
  static String get title => L10n.tr('多设备同步', 'Multi-Device Sync');
  static String get hint => L10n.tr(
    '通过 NAS 或共享目录同步喜欢、歌单与听歌记录',
    'Sync favorites, playlists & history via NAS or shared folder',
  );
  static String get sectionChannel => L10n.tr('同步目录', 'Sync Folder');
  static String get channelHint => L10n.tr(
    '选择一个所有设备都能访问的文件系统音源（如 NAS 的 SMB / WebDAV 共享）。'
    'Lekis 会在其 .lekis/sync/ 目录下写入增量操作日志，不需要服务器或账号。',
    'Pick a filesystem source reachable by all devices (e.g. NAS SMB / WebDAV). '
    'Lekis stores incremental operation logs in .lekis/sync/ with no server or account.',
  );
  static String get sourceLabel => L10n.tr('用于同步的音源', 'Sync Source');
  static String get sourceNone => L10n.tr('未启用同步', 'Sync Disabled');
  static String get noFilesystemSources => L10n.tr(
    '还没有可用的文件系统音源（本地文件夹 / SMB / WebDAV / NFS / SFTP）。',
    'No filesystem sources available yet (Local / SMB / WebDAV / NFS / SFTP).',
  );
  static String get addSourceHint => L10n.tr(
    '先在「音源」页添加 NAS 共享目录，再回来这里选择。',
    'Add a shared folder in Sources first, then select it here.',
  );

  static String get sectionStatus => L10n.tr('同步状态', 'Sync Status');
  static String get syncNow => L10n.tr('立即同步', 'Sync Now');
  static String get syncing => L10n.tr('正在同步…', 'Syncing…');
  static String get idle => L10n.tr('已就绪', 'Ready');
  static String get unavailable =>
      L10n.tr('上次同步失败或共享目录不可达', 'Last sync failed or folder unreachable');
  static String get autoOnLaunch => L10n.tr('启动时自动同步', 'Auto-Sync on Launch');
  static String get autoOnLaunchHint =>
      L10n.tr('打开 Lekis 时自动与所选目录同步一次', 'Sync automatically when Lekis starts');
  static String get neverSynced => L10n.tr('尚未同步过', 'Never synced');
  static String get whatIsSyncedTitle => L10n.tr('同步内容', 'What Gets Synced');
  static String get whatIsSyncedBody => L10n.tr(
    '喜欢、1–5 星评分、歌单与排序、播放次数、歌词偏移量与手工标签覆盖；音频文件与本机设置不同步。',
    'Favorites, 1–5 star ratings, playlists, play counts, lyrics offsets & tag overrides; audio files and local settings stay per-device.',
  );

  static String report(int pushed, int pulled, int applied) => L10n.tr(
    '推送 $pushed 条 · 拉取 $pulled 条 · 应用 $applied 项变更',
    'Pushed $pushed · Pulled $pulled · Applied $applied',
  );

  static String lastSynced(String summary) =>
      L10n.tr('上次同步：$summary', 'Last sync: $summary');
  static String failed(String detail) =>
      L10n.tr('同步失败：$detail', 'Sync failed: $detail');
}
