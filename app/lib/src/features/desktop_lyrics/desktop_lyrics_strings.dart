// 桌面悬浮歌词（UIX-07）文案（中英双语）。

import '../../l10n/app_l10n.dart';

abstract final class DesktopLyricsStrings {
  static String get title => L10n.tr('桌面歌词', 'Desktop Lyrics');
  static String get toggleTooltip => L10n.tr('桌面歌词', 'Desktop Lyrics');
  static String get show => L10n.tr('显示桌面歌词', 'Show Desktop Lyrics');
  static String get menuBarShow => L10n.tr('显示菜单栏歌词', 'Show Menu Bar Lyrics');
  static String get menuBarHint => L10n.tr(
    '在 macOS 菜单栏显示当前一句，点击可控制播放；可与桌面歌词同时开启',
    'Show the current line in the macOS menu bar; click for playback controls. Works independently of the desktop overlay.',
  );
  static String get showHint => L10n.tr(
    '使用独立歌词面板，可与菜单栏歌词同时开启',
    'A compact lyrics panel, independent of menu bar lyrics',
  );
  static String get locked =>
      L10n.tr('锁定窗口（鼠标穿透）', 'Lock Overlay (Click-Through)');
  static String get lockedHint => L10n.tr(
    '锁定后点击会穿透到下层窗口，把鼠标移到锁图标上可随时解锁',
    'Clicks pass through when locked; hover the lock icon to unlock anytime',
  );
  static String get twoLine => L10n.tr('双行显示', 'Two-Line Display');
  static String get twoLineHint =>
      L10n.tr('同时显示翻译或下一句歌词', 'Show translation or next lyric line');
  static String get fontSize => L10n.tr('字号', 'Font Size');
  static String get opacity => L10n.tr('不透明度', 'Opacity');
}
