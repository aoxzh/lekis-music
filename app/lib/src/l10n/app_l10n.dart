// 轻量级中英双语本地化层（简体中文默认，English 完整对照）。
//
// 通过 [LekisLocale]（由 [LekisApp] 注入）驱动 `context.l10n` 与静态文案表 `L10n.tr(zh, en)`；
// 无 [LekisLocale] 祖先（如未配置本地化的独立组件测试）时默认返回简体中文，
// 保证所有默认中文体验与既有组件测试 100% 稳定。

import 'package:material_ui/material_ui.dart';

class LekisLocale extends StatefulWidget {
  const LekisLocale({super.key, required this.locale, required this.child});

  final Locale locale;
  final Widget child;

  static Locale? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_LekisLocaleScope>()
          ?.locale;

  @override
  State<LekisLocale> createState() => _LekisLocaleState();
}

class _LekisLocaleState extends State<LekisLocale> {
  Locale? _previous;

  @override
  void initState() {
    super.initState();
    _previous = L10n._activeLocale;
    L10n._activeLocale = widget.locale;
  }

  @override
  void didUpdateWidget(LekisLocale oldWidget) {
    super.didUpdateWidget(oldWidget);
    L10n._activeLocale = widget.locale;
  }

  @override
  void dispose() {
    L10n._activeLocale = _previous;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    L10n._activeLocale = widget.locale;
    return _LekisLocaleScope(locale: widget.locale, child: widget.child);
  }
}

class _LekisLocaleScope extends InheritedWidget {
  const _LekisLocaleScope({required this.locale, required super.child});

  final Locale locale;

  @override
  bool updateShouldNotify(_LekisLocaleScope oldWidget) =>
      locale != oldWidget.locale;
}

class L10n {
  const L10n({required this.isEnglish});

  static Locale? _activeLocale;

  final bool isEnglish;

  /// 当前生效语种是否为英文（供静态文案表与枚举 label 使用）。
  static bool get isEnglishActive => _activeLocale?.languageCode == 'en';

  /// 静态中英双语选择，配合 [LekisLocale] 实时切换。
  static String tr(String zh, String en) => isEnglishActive ? en : zh;

  static L10n of(BuildContext context) {
    final locale = LekisLocale.maybeOf(context);
    return L10n(isEnglish: locale?.languageCode == 'en');
  }

  String pick(String zh, String en) => isEnglish ? en : zh;

  // 品牌名
  String get appName => pick('月兔音乐', 'Lekis Music');
  String get brandShort => pick('月兔音乐', 'Lekis');

  // 顶层导航
  String get navHome => pick('首页', 'Home');
  String get navLibrary => pick('资料库', 'Library');
  String get navSearch => pick('搜索', 'Search');
  String get navPodcasts => pick('播客', 'Podcasts');
  String get navSources => pick('音源', 'Sources');
  String get navSettings => pick('设置', 'Settings');

  // 首页
  String get listeningStats => pick('听歌统计', 'Stats');
  String get continueListening => pick('继续收听', 'CONTINUE LISTENING');
  String get recentlyPlayed => pick('最近播放', 'Recently Played');
  String get recentlyAdded => pick('最近添加', 'Recently Added');
  String get mostPlayed => pick('最常播放', 'Most Played');
  String get seeAll => pick('查看全部', 'See All');
  String get quickShuffle => pick('随机漫游', 'Shuffle All');
  String get quickLiked => pick('我的喜欢', 'Liked');
  String get quickMostPlayed => pick('常听精选', 'Top Tracks');
  String get unknownArtist => pick('未知艺人', 'Unknown Artist');
  String get welcomeTitle => pick('欢迎使用月兔音乐', 'Welcome to Lekis Music');
  String get welcomeMessage => pick(
    '在「音源」里添加本地文件夹、NAS 或媒体服务器，即可开始聆听。',
    'Add a local folder, NAS, or media server in Sources to start listening.',
  );

  String greetingFor(DateTime now) {
    final hour = now.hour;
    if (hour < 5) return pick('夜深了', 'Late Night');
    if (hour < 11) return pick('早上好', 'Good Morning');
    if (hour < 14) return pick('中午好', 'Good Afternoon');
    if (hour < 18) return pick('下午好', 'Good Afternoon');
    return pick('晚上好', 'Good Evening');
  }

  // 资料库
  String get segAlbums => pick('专辑', 'Albums');
  String get segArtists => pick('艺人', 'Artists');
  String get segSongs => pick('歌曲', 'Songs');
  String get segGenres => pick('流派', 'Genres');
  String get segPlaylists => pick('歌单', 'Playlists');
  String get segLiked => pick('喜欢', 'Liked');
  String get segFolders => pick('文件夹', 'Folders');
  String get coverFlow => pick('封面流', 'Cover Flow');

  // 播放器 & 正在播放
  String get lyrics => pick('歌词', 'Lyrics');
  String get hideLyrics => pick('隐藏歌词', 'Hide Lyrics');
  String get queue => pick('播放队列', 'Queue');
  String get hideQueue => pick('隐藏播放队列', 'Hide Queue');
  String get outputDevice => pick('输出设备', 'Output Device');
  String get mute => pick('静音', 'Mute');
  String get unmute => pick('取消静音', 'Unmute');
  String get noLyrics => pick('暂无歌词', 'No Lyrics');
  String get notPlaying => pick('未在播放', 'Not Playing');
  String volumeTooltip(int pct) => pick('音量 $pct%', 'Volume $pct%');

  // 设置：通用与外观
  String get settingsTitle => pick('设置', 'Settings');
  String get groupMusic => pick('音乐', 'Music');
  String get groupGeneral => pick('通用', 'General');
  String get groupMore => pick('更多', 'More');
  String get searchSettingsHint => pick('查找设置', 'Search settings');
  String get language => pick('语言', 'Language');
  String get languageHint =>
      pick('切换应用界面语言，立即生效。', 'Switch interface language immediately.');
  String get languageSystem => pick('跟随系统', 'System');
  String get languageZh => '简体中文';
  String get languageEn => 'English';

  String get nowPlayingStyle => pick('播放页样式', 'Now Playing Style');
  String get nowPlayingStyleHint => pick(
    '切换正在播放页的主视觉呈现：经典封面、黑胶唱片（带旋转与唱臂）或复古磁带。',
    'Choose the Now Playing visual: classic cover, spinning vinyl with tonearm, or cassette.',
  );
  String get styleCover => pick('封面', 'Cover');
  String get styleVinyl => pick('黑胶唱片', 'Vinyl');
  String get styleCassette => pick('磁带', 'Cassette');

  String get appearance => pick('外观', 'Appearance');
  String get playback => pick('播放', 'Playback');
  String get organize => pick('整理资料库', 'Library Tools');
  String get multiDeviceSync => pick('多设备同步', 'Multi-Device Sync');
  String get connect => pick('在其他设备上播放', 'Play on Other Devices');
  String get advanced => pick('高级', 'Advanced');
  String get about => pick('关于', 'About');
}

extension LekisL10nX on BuildContext {
  L10n get l10n => L10n.of(this);
}
