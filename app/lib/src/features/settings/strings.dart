// 设置页全部文案（中英双语，简体中文默认，切至 English 实时生效）。

import '../../l10n/app_l10n.dart';

abstract final class SettingsStrings {
  static String get title => L10n.tr('设置', 'Settings');

  // 顶层结构：分组 + 进入下一级的行。
  static String get groupMusic => L10n.tr('音乐', 'Music');
  static String get groupGeneral => L10n.tr('通用', 'General');
  static String get groupMore => L10n.tr('更多', 'More');
  static String get playbackHint =>
      L10n.tr('输出设备、无缝播放、均衡器、睡眠定时', 'Output device, gapless, EQ, sleep timer');
  static String get appearanceHint =>
      L10n.tr('主题、语言、播放页、显示样式与歌词', 'Theme, language, Now Playing, chrome & lyrics');
  static String get appearanceHintDesktop =>
      L10n.tr('主题、语言、播放页样式与歌词', 'Theme, language, Now Playing style & lyrics');
  static String get searchHint => L10n.tr('查找设置', 'Search settings');
  static String get searchEmpty => L10n.tr('没有匹配的设置', 'No matching settings');
  static String get lyrics => L10n.tr('歌词', 'Lyrics');
  static String get lyricsHint =>
      L10n.tr('歌词样式和舞台效果', 'Lyrics layout and word-by-word stage');
  static String get organize => L10n.tr('整理资料库', 'Library Tools');
  static String get organizeHint =>
      L10n.tr('资料库检查和待确认的补全', 'Library health checks and metadata review');
  static String get advanced => L10n.tr('高级', 'Advanced');
  static String get advancedHint => L10n.tr(
    '独占输出、ReplayGain、听歌记录、插件、备份、日志',
    'Exclusive audio, ReplayGain, scrobbling, plugins, backup & logs',
  );
  static String get aboutHint => L10n.tr('版本和设备信息', 'Version and device info');
  static String sourcesCount(int n) =>
      L10n.tr('$n 个音源', n == 1 ? '1 source' : '$n sources');
  static String get sourcesNone =>
      L10n.tr('还没有音源，从这里添加音乐文件夹', 'No sources yet — add a music folder here');
  static String get setupTitle => L10n.tr('先把音乐加进来', 'Add your music first');
  static String get setupBody => L10n.tr(
    '添加这台设备上的音乐文件夹，或者连接 NAS / 媒体服务器。Lekis 会自动扫描并整理。',
    'Add a local folder on this device, or connect a NAS / media server. Lekis scans and organizes automatically.',
  );
  static String get setupAction => L10n.tr('添加音乐', 'Add Music');
  static String get normalize => L10n.tr('音量平衡', 'Volume Normalization');
  static String get normalizeHint => L10n.tr(
    '让不同歌曲的响度更接近（ReplayGain）',
    'Keep track loudness consistent (ReplayGain)',
  );
  static String get audioOutput => L10n.tr('音频输出', 'Audio Output');
  static String get servicesGroup => L10n.tr('服务与扩展', 'Services & Extensions');
  static String get scrobbleHint => L10n.tr(
    '把听过的歌上报到 Last.fm / ListenBrainz',
    'Scrobble played tracks to Last.fm / ListenBrainz',
  );
  static String get dataGroup => L10n.tr('数据', 'Data');

  static String get playback => L10n.tr('播放', 'Playback');
  static String get outputDevice => L10n.tr('输出设备', 'Output Device');
  static String get systemDefault => L10n.tr('跟随系统默认', 'System Default');
  static String defaultSuffix(String name) =>
      L10n.tr('$name（默认）', '$name (Default)');
  static String get noDevices =>
      L10n.tr('没有找到可用的输出设备', 'No available output devices');
  static String get refreshDevices => L10n.tr('刷新设备列表', 'Refresh devices');
  static String get outputMode => L10n.tr('输出模式', 'Output Mode');
  static String get modeShared => L10n.tr('共享', 'Shared');
  static String get modeExclusive => L10n.tr('独占', 'Exclusive');
  static String get modeSharedHint => L10n.tr(
    '和其他应用一起出声，系统会混音并可能重采样。',
    'Mixes with other apps via the system mixer; resampling may occur.',
  );
  static String get modeExclusiveHint => L10n.tr(
    '独占输出设备，音频不经系统混音、按原始采样率直送（比特完美）。独占播放时音量与 ReplayGain 不生效；播放期间其他应用将无法出声。',
    'Bypasses the system mixer for bit-perfect output. Volume & ReplayGain are bypassed and other apps cannot play audio.',
  );
  static String get exclusiveUnsupported =>
      L10n.tr('当前设备不支持独占模式', 'Exclusive mode is not supported on this device');
  static String get gapless => L10n.tr('无缝播放', 'Gapless Playback');
  static String get gaplessHint => L10n.tr(
    '去掉曲目之间的静音间隙，现场专辑和古典乐更连贯',
    'Remove silence between consecutive tracks for live and classical albums',
  );
  static String get replayGain => L10n.tr('ReplayGain 模式', 'ReplayGain Mode');
  static String get replayGainHint => L10n.tr(
    '按文件里的 ReplayGain 信息统一响度：按曲目让每首一样响，按专辑保留专辑内的起伏',
    'Normalize loudness using ReplayGain tags: Track levels every song, Album preserves dynamics',
  );
  static String get rgTrack => L10n.tr('按曲目', 'Track');
  static String get rgAlbum => L10n.tr('按专辑', 'Album');
  static String get rgOff => L10n.tr('关闭', 'Off');
  static String get sleepTimer => L10n.tr('睡眠定时', 'Sleep Timer');
  static String get sleepTimerHint => L10n.tr(
    '到点自动暂停播放；只在本机生效。',
    'Automatically pause playback when time is up (this device only).',
  );

  static String get appearance => L10n.tr('外观', 'Appearance');
  static String get theme => L10n.tr('主题', 'Theme');
  static String get themeSystem => L10n.tr('跟随系统', 'System');
  static String get themeLight => L10n.tr('浅色', 'Light');
  static String get themeDark => L10n.tr('深色', 'Dark');
  static String get themeOled => L10n.tr('纯黑', 'OLED Black');
  static String get themeOledHint =>
      L10n.tr('纯黑适合 OLED 屏幕，更省电', 'True black saves power on OLED displays');
  static String get language => L10n.tr('语言', 'Language');
  static String get languageHint => L10n.tr(
    '切换界面语言（简体中文 / English），立即生效',
    'Switch interface language immediately (Chinese / English)',
  );
  static String get languageSystem => L10n.tr('跟随系统', 'System');
  static String get languageZh => '简体中文';
  static String get languageEn => 'English';
  static String get nowPlayingStyle => L10n.tr('播放页样式', 'Now Playing Style');
  static String get nowPlayingStyleHint => L10n.tr(
    '切换正在播放页主视觉：经典封面、黑胶唱片（带旋转与唱臂）或复古磁带',
    'Choose the Now Playing visual: classic cover, spinning vinyl with tonearm, or cassette',
  );
  static String get nowPlayingCover => L10n.tr('封面', 'Cover');
  static String get nowPlayingVinyl => L10n.tr('黑胶唱片', 'Vinyl');
  static String get nowPlayingCassette => L10n.tr('磁带', 'Cassette');
  static String get tabBarStyle => L10n.tr('显示样式', 'Display Style');
  static String get tabBarStyleHint => L10n.tr(
    '液态玻璃为悬浮导航、迷你播放器、索引条与胶囊按钮提供通透高光与弹簧动效；扁平更利落、开销更低。',
    'Liquid Glass gives floating chrome translucent highlights and spring motion; Flat is crisp and lighter.',
  );
  static String get tabBarLiquid => L10n.tr('液态玻璃', 'Liquid Glass');
  static String get tabBarLiquidHint =>
      L10n.tr('模糊 · 流动 · 弹簧', 'Blur · Fluid · Spring');
  static String get tabBarFlat => L10n.tr('扁平', 'Flat');
  static String get tabBarFlatHint =>
      L10n.tr('纯色 · 快速 · 低开销', 'Solid · Crisp · Light');
  static String get navBarPosition => L10n.tr('导航栏位置', 'Navigation Position');
  static String get navBarPositionHint => L10n.tr(
    '默认底部居中悬浮；选左侧或右侧时静态按钮自动避让，横滑画廊可从玻璃下方穿过。',
    'Bottom floating by default; left or right docks vertically while static controls stay clear.',
  );
  static String get navBarBottom => L10n.tr('底部', 'Bottom');
  static String get navBarLeft => L10n.tr('左侧', 'Left');
  static String get navBarRight => L10n.tr('右侧', 'Right');
  static String get lyricsStage => L10n.tr('歌词样式', 'Lyrics Style');
  static String get lyricsStageHint => L10n.tr(
    '经典是简洁的逐行滚动歌词（默认）；流动 / 阶梯 / 倾斜是逐字跟唱的舞台。',
    'Classic scrolls line by line (default); Flow / Steps / Tilt are word-by-word stages.',
  );
  static String get styleClassic => L10n.tr('经典', 'Classic');
  static String get styleFlow => L10n.tr('流动', 'Flow');
  static String get styleSteps => L10n.tr('阶梯', 'Steps');
  static String get styleTilt => L10n.tr('倾斜', 'Tilt');
  static String get lyricsSparks => L10n.tr('火花', 'Sparks');
  static String get lyricsSparksHint => L10n.tr(
    '舞台样式下，唱到每个字时飞出细小的光点，最后一句更明显',
    'Emit subtle light sparks on each sung word in stage modes',
  );

  static String get system => L10n.tr('系统', 'System');
  static String get desktopTrayEnabled => L10n.tr('显示托盘图标', 'Show Tray Icon');
  static String get desktopTrayEnabledHint => L10n.tr(
    '在 Windows 通知区域显示 Lekis，可右键控制播放，双击恢复窗口。',
    'Show Lekis in the Windows notification area with playback controls.',
  );
  static String get desktopTrayCloseToTray =>
      L10n.tr('关闭窗口时最小化到托盘', 'Minimize to Tray on Close');
  static String get desktopTrayCloseToTrayHint => L10n.tr(
    '点关闭按钮只隐藏窗口，音乐继续播放；请从托盘菜单退出以结束进程。',
    'Closing the window hides it while music keeps playing; quit from the tray menu.',
  );
  static String get desktopTrayNeedsIcon => L10n.tr(
    '先启用托盘图标，隐藏窗口后才有入口恢复。',
    'Enable the tray icon first so you can reopen the window after hiding it.',
  );

  static String get library => L10n.tr('资料库', 'Library');
  static String get sources => L10n.tr('音源', 'Sources');
  static String get sourcesHint =>
      L10n.tr('管理本地文件夹、NAS 和媒体服务器', 'Manage local folders, NAS & media servers');
  static String get enrichReview => L10n.tr('待确认的补全', 'Metadata Review');
  static String get enrichReviewHint =>
      L10n.tr('检查自动找到的封面、歌词和标签', 'Review auto-matched artwork, lyrics & tags');
  static String get libraryHealth => L10n.tr('资料库检查', 'Library Health');
  static String get libraryHealthHint => L10n.tr(
    '查找重复歌曲、缺失标签 / 封面 / 歌词和不可读文件',
    'Find duplicates, missing tags / artwork / lyrics, and unreadable files',
  );
  static String pendingCount(int n) => L10n.tr('$n 条待确认', '$n pending');
  static String get downloads => L10n.tr('下载', 'Downloads');
  static String get downloadsHint =>
      L10n.tr('离线缓存、下载队列和失败重试', 'Offline cache, download queue & retries');
  static String downloadsSummary(int count, String size, int active) => L10n.tr(
    '$count 首 · $size${active > 0 ? ' · $active 首下载中' : ''}',
    '$count tracks · $size${active > 0 ? ' · $active active' : ''}',
  );

  static String get plugins => L10n.tr('插件', 'Plugins');
  static String get pluginsEmpty => L10n.tr('未安装插件', 'No plugins installed');
  static String get pluginLoadFailed =>
      L10n.tr('读取插件列表失败', 'Failed to load plugins');
  static String pluginsInstalled(int n) =>
      L10n.tr('已安装 $n 个插件', n == 1 ? '1 plugin installed' : '$n plugins installed');

  static String get scrobbling => L10n.tr('听歌记录', 'Scrobbling');
  static String get scrobbleEnable => L10n.tr('上报听歌记录', 'Enable Scrobbling');
  static String get scrobbleEnableHint => L10n.tr(
    '按 Last.fm 规则（超过 30 秒，且听满一半或 4 分钟）自动上报；断网时排队，联网后补报。',
    'Automatically scrobble after 30s and half or 4 min played; queued offline.',
  );
  static String get scrobbleService => L10n.tr('服务', 'Service');
  static String get scrobbleLastFm => 'Last.fm';
  static String get scrobbleListenBrainz => 'ListenBrainz';
  static String get scrobbleLibreFm => 'Libre.fm';
  static String get scrobbleAccount => L10n.tr('账号与凭据', 'Account & Credentials');
  static String get scrobbleUsername => L10n.tr('用户名', 'Username');
  static String get scrobbleApiKey => 'API key';
  static String get scrobbleApiSecret => 'API secret';
  static String get scrobbleSessionKey => 'Session key';
  static String get scrobbleUserToken => 'User token';
  static String get scrobbleNowPlaying =>
      L10n.tr('发送“正在播放”', 'Send "Now Playing"');
  static String get scrobbleNowPlayingHint => L10n.tr(
    '播放开始时把当前曲目显示在服务上',
    'Update your profile with the currently playing track',
  );
  static String get scrobbleSave => L10n.tr('保存', 'Save');
  static String get scrobbleTest => L10n.tr('测试连接', 'Test Connection');
  static String get scrobbleTesting => L10n.tr('正在测试…', 'Testing…');
  static String get scrobbleSaved => L10n.tr('听歌记录设置已保存', 'Scrobbling settings saved');
  static String get scrobbleTestOk => L10n.tr('连接正常', 'Connection OK');
  static String get scrobbleTestFailed => L10n.tr('连接测试失败', 'Connection failed');
  static String get scrobbleClearSecrets =>
      L10n.tr('清除已保存的凭据', 'Clear Saved Credentials');
  static String get scrobbleSecretKept =>
      L10n.tr('留空保留已保存的值', 'Leave blank to keep saved value');
  static String get scrobbleNotConfigured =>
      L10n.tr('缺少凭据，尚未启用上报', 'Missing credentials');
  static String get scrobbleDisabled => L10n.tr('未启用', 'Disabled');
  static String get scrobbleReady => L10n.tr('已就绪', 'Ready');
  static String scrobbleQueue(int n) =>
      L10n.tr(n > 0 ? '待补报 $n 条' : '队列为空', n > 0 ? '$n queued' : 'Queue empty');
  static String get scrobbleLastSuccess => L10n.tr('最近成功', 'Last Success');

  static String get backup => L10n.tr('备份与恢复', 'Backup & Restore');
  static String get diagnostics => L10n.tr('诊断', 'Diagnostics');
  static String get diagnosticLogs => L10n.tr('诊断日志', 'Diagnostic Logs');
  static String get diagnosticLogsHint => L10n.tr(
    '查看最近的核心日志并复制；敏感字段已自动打码',
    'View and copy recent core logs (secrets automatically redacted)',
  );
  static String get about => L10n.tr('关于', 'About');
  static String get coreVersion => L10n.tr('核心版本', 'Core Version');
  static String get deviceId => L10n.tr('设备 ID', 'Device ID');
  static String get copy => L10n.tr('复制', 'Copy');
  static String get copied => L10n.tr('已复制', 'Copied');
  static String get unavailable => L10n.tr('不可用', 'Unavailable');
  static String get saveFailed => L10n.tr('保存设置失败', 'Failed to save setting');
}
