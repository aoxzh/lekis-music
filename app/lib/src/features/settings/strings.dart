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
  static String get appearanceHint => L10n.tr(
    '主题、语言、播放页、显示样式与歌词',
    'Theme, language, Now Playing, chrome & lyrics',
  );
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
  static String get aboutHint =>
      L10n.tr('版本、作者、问题反馈与项目信息', 'Version, author, bug reports & project info');
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

  // USB DAC 比特完美直出（Android 14+）。
  static String get usbBitPerfect =>
      L10n.tr('USB DAC 比特完美直出', 'USB DAC bit-perfect output');
  static String get usbBitPerfectHint => L10n.tr(
    'Android 14+：绕过系统混音器，按原始采样率和位深直送 USB DAC。直出时音量、ReplayGain、均衡器和淡入淡出不生效，也没有无缝播放。',
    'Android 14+: bypasses the system mixer and sends the original sample rate and bit depth to the USB DAC. While active, volume, ReplayGain, EQ and crossfade are bypassed and gapless playback is unavailable.',
  );
  static String get usbStatus => L10n.tr('直出状态', 'Direct output status');
  static String get usbStatusUnavailable =>
      L10n.tr('此平台不支持', 'Not available on this platform');
  static String get usbStatusNoDevice => L10n.tr(
    '没有连接 USB 音频设备，正在使用普通输出',
    'No USB audio device connected; using normal output',
  );
  static String usbStatusOldAndroid(int sdk) => L10n.tr(
    '需要 Android 14 或更高（当前 API $sdk），正在使用普通输出',
    'Requires Android 14 or later (this device is API $sdk); using normal output',
  );
  static String usbStatusUnsupported(String device) => L10n.tr(
    '$device 不支持比特完美输出，正在使用普通输出',
    '$device does not support bit-perfect output; using normal output',
  );
  static String usbStatusFormatFallback(
    String device,
    String format,
  ) => L10n.tr(
    '$device 不支持本曲格式（$format），本曲使用普通输出',
    '$device does not support this track\'s format ($format); using normal output for it',
  );
  static String usbStatusReady(String device) => L10n.tr(
    '已就绪：$device，下一首开始直出',
    'Ready: $device — direct output starts with the next track',
  );
  static String usbStatusActive(String device, String format) =>
      L10n.tr('正在直出：$device · $format', 'Direct to $device · $format');
  static String usbStatusFailed(String reason) => L10n.tr(
    '直出失败，本曲使用普通输出：$reason',
    'Direct output failed, using normal output for this track: $reason',
  );
  static String get usbUnknownDevice => L10n.tr('USB 设备', 'USB device');
  static String usbContainer(int bits) =>
      L10n.tr('设备 $bits 位容器', '$bits-bit container');
  static String get usbBypassedNote => L10n.tr(
    '音量、ReplayGain、均衡器、淡入淡出已旁路；无缝播放不可用。',
    'Volume, ReplayGain, EQ and crossfade are bypassed; gapless is unavailable.',
  );
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
  static String get themeOled => L10n.tr('纯黑', 'OLED');
  static String get accentColor => L10n.tr('强调色', 'Accent color');
  static String get accentColorHint => L10n.tr(
    '选择应用内的高亮颜色，按钮、进度条和选中状态都会跟着变化',
    'Pick the highlight color used by buttons, progress bars and selected states',
  );
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
  static String get lyricsRuby => L10n.tr('注音歌词', 'Ruby Lyrics');
  static String get lyricsRubyHint => L10n.tr(
    '在汉字上方标出拼音，本地计算、不联网；经典歌词视图生效',
    'Show pinyin above each character, computed on device. Classic lyrics view.',
  );
  static String get rubyOff => L10n.tr('关闭', 'Off');
  static String get rubyPlain => L10n.tr('拼音', 'Pinyin');
  static String get rubyTone => L10n.tr('带声调', 'With Tones');
  static String get rubyToneNum => L10n.tr('声调数字', 'Tone Numbers');

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
  static String get sourcesHint => L10n.tr(
    '管理本地文件夹、NAS 和媒体服务器',
    'Manage local folders, NAS & media servers',
  );
  static String get enrichReview => L10n.tr('待确认的补全', 'Metadata Review');
  static String get enrichReviewHint =>
      L10n.tr('检查自动找到的封面、歌词和标签', 'Review auto-matched artwork, lyrics & tags');
  static String get libraryHealth => L10n.tr('资料库检查', 'Library Health');
  static String get libraryHealthHint => L10n.tr(
    '查找重复歌曲、缺失标签 / 封面 / 歌词和不可读文件',
    'Find duplicates, missing tags / artwork / lyrics, and unreadable files',
  );
  static String get writeEnrichSidecars =>
      L10n.tr('补全结果写入音源目录', 'Save Enrichment to Source Folders');
  static String get writeEnrichSidecarsHint => L10n.tr(
    '封面写成 cover.jpg / 同名图片，歌词写成同名 .lrc；升级后会后台把已有结果写回一次，只读共享和媒体服务器会跳过',
    'Write covers as cover.jpg / track images and lyrics as matching .lrc files; existing results are migrated once in the background. Read-only shares and media servers are skipped',
  );
  static String get sidecarBackfillDone => L10n.tr(
    '已有补全结果已写回音源目录',
    'Existing enrichment has been written to source folders',
  );
  static String get sidecarBackfillPending => L10n.tr(
    '启动后会在后台把已有补全结果写回一次',
    'Existing enrichment will be migrated once in the background after startup',
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
  static String pluginsInstalled(int n) => L10n.tr(
    '已安装 $n 个插件',
    n == 1 ? '1 plugin installed' : '$n plugins installed',
  );

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
  static String get scrobbleAccount =>
      L10n.tr('账号与凭据', 'Account & Credentials');
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
  static String get scrobbleSaved =>
      L10n.tr('听歌记录设置已保存', 'Scrobbling settings saved');
  static String get scrobbleTestOk => L10n.tr('连接正常', 'Connection OK');
  static String get scrobbleTestFailed =>
      L10n.tr('连接测试失败', 'Connection failed');
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
  static String get appVersion => L10n.tr('应用版本', 'App Version');
  static String get coreVersion => L10n.tr('核心版本', 'Core Version');
  static String get author => L10n.tr('作者', 'Author');
  static String get githubRepo => L10n.tr('GitHub 仓库', 'GitHub Repository');
  static String get reportBug => L10n.tr('提交 Bug / 反馈建议', 'Report a Bug');
  static String get reportBugHint => L10n.tr(
    '前往 GitHub Issues 提交问题或功能建议',
    'Open GitHub Issues to report bugs or request features',
  );
  static String get checkUpdates => L10n.tr('检查更新', 'Check for Updates');
  static String get checkUpdatesHint => L10n.tr(
    '从 GitHub Releases 检测新版本并获取安装包',
    'Check GitHub Releases for a newer version',
  );
  static String get checkingUpdates =>
      L10n.tr('正在检查更新…', 'Checking for updates…');
  static String upToDate(String v) =>
      L10n.tr('已是最新版本（v$v）', 'You are up to date (v$v)');
  static String updateAvailableTitle(String v) =>
      L10n.tr('发现新版本 v$v', 'Update Available: v$v');
  static String updateAvailableSubtitle(String v) =>
      L10n.tr('新版本 v$v 可用，点击更新', 'Version v$v is available — tap to update');
  static String updateReadySubtitle(String v) =>
      L10n.tr('v$v 已下载就绪，点击立即重启更新', 'v$v is ready — tap to restart and update');
  static String get downloadUpdate => L10n.tr('立即下载升级', 'Download Update');
  static String get downloadAndUpdate => L10n.tr('下载并更新', 'Download & Update');
  static String get restartToUpdate => L10n.tr('立即重启更新', 'Restart to Update');
  static String get restartingToUpdate =>
      L10n.tr('正在重启并应用更新…', 'Restarting to apply update…');
  static String get updateReadyHint => L10n.tr(
    '新版本已校验并解压完成，重启应用即可生效。',
    'Verified and unpacked. Restart Lekis to finish updating.',
  );
  static String get verifyingUpdate =>
      L10n.tr('正在校验 SHA-256…', 'Verifying SHA-256…');
  static String get extractingUpdate =>
      L10n.tr('正在解压更新包…', 'Extracting update…');
  static String get downloadingUpdate =>
      L10n.tr('正在下载更新…', 'Downloading update…');
  static String get later => L10n.tr('稍后', 'Later');
  static String get retry => L10n.tr('重试', 'Retry');
  static String get cancel => L10n.tr('取消', 'Cancel');
  static String get viewReleasePage => L10n.tr('查看发布页', 'Release Notes');
  static String get updateCheckFailed =>
      L10n.tr('检查更新失败，请稍后重试', 'Update check failed. Please try again later.');
  static String get license => L10n.tr('开源协议', 'License');
  static String get nameOriginTitle => L10n.tr('名字由来', 'Why "Lekis"?');
  static String get nameOriginBody => L10n.tr(
    '灵感源自雷克斯兽（Lekismon / レキスモン）与雷克斯兔（Rex rabbit），希望它像月下奔跑的兔影一样轻盈、敏捷而通透。',
    'Inspired by Lekismon (レキスモン) and the Rex rabbit — crafted to feel swift, lightweight, and luminous.',
  );
  static String get linkCopiedFallback => L10n.tr(
    '无法直接打开浏览器，已复制链接到剪贴板',
    'Could not open browser; link copied to clipboard',
  );
  static String get deviceId => L10n.tr('设备 ID', 'Device ID');
  static String get copy => L10n.tr('复制', 'Copy');
  static String get copied => L10n.tr('已复制', 'Copied');
  static String get unavailable => L10n.tr('不可用', 'Unavailable');
  static String get saveFailed => L10n.tr('保存设置失败', 'Failed to save setting');
}
