// 设置页的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class SettingsStrings {
  static const title = '设置';

  // 顶层结构：分组 + 进入下一级的行。
  static const groupMusic = '音乐';
  static const groupGeneral = '通用';
  static const groupMore = '更多';
  static const playbackHint = '输出设备、无缝播放、均衡器、睡眠定时';
  static const appearanceHint = '主题和标签栏';
  static const lyrics = '歌词';
  static const lyricsHint = '歌词样式和舞台效果';
  static const organize = '整理资料库';
  static const organizeHint = '资料库检查和待确认的补全';
  static const advanced = '高级';
  static const advancedHint = '独占输出、ReplayGain、听歌记录、插件、备份、日志';
  static const aboutHint = '版本和设备信息';
  static String sourcesCount(int n) => '$n 个音源';
  static const sourcesNone = '还没有音源，从这里添加音乐文件夹';
  static const setupTitle = '先把音乐加进来';
  static const setupBody = '添加这台设备上的音乐文件夹，或者连接 NAS / 媒体服务器。Lekis 会自动扫描并整理。';
  static const setupAction = '添加音乐';
  static const normalize = '音量平衡';
  static const normalizeHint = '让不同歌曲的响度更接近（ReplayGain）';
  static const audioOutput = '音频输出';
  static const servicesGroup = '服务与扩展';
  static const scrobbleHint = '把听过的歌上报到 Last.fm / ListenBrainz';
  static const dataGroup = '数据';

  static const playback = '播放';
  static const outputDevice = '输出设备';
  static const systemDefault = '跟随系统默认';
  static String defaultSuffix(String name) => '$name（默认）';
  static const noDevices = '没有找到可用的输出设备';
  static const refreshDevices = '刷新设备列表';
  static const outputMode = '输出模式';
  static const modeShared = '共享';
  static const modeExclusive = '独占';
  static const modeSharedHint = '和其他应用一起出声，系统会混音并可能重采样。';
  static const modeExclusiveHint =
      '独占输出设备，音频不经系统混音、按原始采样率直送（比特完美）。独占播放时音量与 ReplayGain 不生效；播放期间其他应用将无法出声。';
  static const exclusiveUnsupported = '当前设备不支持独占模式';
  static const gapless = '无缝播放';
  static const gaplessHint = '去掉曲目之间的静音间隙，现场专辑和古典乐更连贯';
  static const replayGain = 'ReplayGain 模式';
  static const replayGainHint = '按文件里的 ReplayGain 信息统一响度：按曲目让每首一样响，按专辑保留专辑内的起伏';
  static const rgTrack = '按曲目';
  static const rgAlbum = '按专辑';
  static const rgOff = '关闭';
  static const sleepTimer = '睡眠定时';
  static const sleepTimerHint = '到点自动暂停播放；只在本机生效。';

  static const appearance = '外观';
  static const theme = '主题';
  static const themeSystem = '跟随系统';
  static const themeLight = '浅色';
  static const themeDark = '深色';
  static const themeOled = '纯黑';
  static const themeOledHint = '纯黑适合 OLED 屏幕，更省电';
  static const tabBarStyle = '标签栏样式';
  static const tabBarStyleHint = '液态玻璃有模糊、流动高光与弹簧；扁平更利落、开销更低。';
  static const tabBarLiquid = '液态玻璃';
  static const tabBarLiquidHint = '模糊 · 流动 · 弹簧';
  static const tabBarFlat = '扁平';
  static const tabBarFlatHint = '纯色 · 快速 · 低开销';
  static const lyricsStage = '歌词样式';
  static const lyricsStageHint =
      '经典是 Apple Music 那样的逐行滚动歌词（默认）；流动 / 阶梯 / 倾斜是逐字跟唱的舞台。';
  static const styleClassic = '经典';
  static const styleFlow = '流动';
  static const styleSteps = '阶梯';
  static const styleTilt = '倾斜';
  static const lyricsSparks = '火花';
  static const lyricsSparksHint = '舞台样式下，唱到每个字时飞出细小的光点，最后一句更明显';

  static const system = '系统';
  static const desktopTrayEnabled = '显示托盘图标';
  static const desktopTrayEnabledHint =
      '在 Windows 通知区域显示 Lekis，可右键控制播放，双击恢复窗口。';
  static const desktopTrayCloseToTray = '关闭窗口时最小化到托盘';
  static const desktopTrayCloseToTrayHint = '点关闭按钮只隐藏窗口，音乐继续播放；请从托盘菜单退出以结束进程。';
  static const desktopTrayNeedsIcon = '先启用托盘图标，隐藏窗口后才有入口恢复。';

  static const library = '资料库';
  static const sources = '音源';
  static const sourcesHint = '管理本地文件夹、NAS 和媒体服务器';
  static const enrichReview = '待确认的补全';
  static const enrichReviewHint = '检查自动找到的封面、歌词和标签';
  static const libraryHealth = '资料库检查';
  static const libraryHealthHint = '查找重复歌曲、缺失标签 / 封面 / 歌词和不可读文件';
  static String pendingCount(int n) => '$n 条待确认';
  static const downloads = '下载';
  static const downloadsHint = '离线缓存、下载队列和失败重试';
  static String downloadsSummary(int count, String size, int active) =>
      '$count 首 · $size${active > 0 ? ' · $active 首下载中' : ''}';

  static const plugins = '插件';
  static const pluginsEmpty = '未安装插件';
  static const pluginLoadFailed = '读取插件列表失败';
  static String pluginsInstalled(int n) => '已安装 $n 个插件';

  static const scrobbling = '听歌记录';
  static const scrobbleEnable = '上报听歌记录';
  static const scrobbleEnableHint =
      '按 Last.fm 规则（超过 30 秒，且听满一半或 4 分钟）自动上报；断网时排队，联网后补报。';
  static const scrobbleService = '服务';
  static const scrobbleLastFm = 'Last.fm';
  static const scrobbleListenBrainz = 'ListenBrainz';
  static const scrobbleLibreFm = 'Libre.fm';
  static const scrobbleAccount = '账号与凭据';
  static const scrobbleUsername = '用户名';
  static const scrobbleApiKey = 'API key';
  static const scrobbleApiSecret = 'API secret';
  static const scrobbleSessionKey = 'Session key';
  static const scrobbleUserToken = 'User token';
  static const scrobbleNowPlaying = '发送“正在播放”';
  static const scrobbleNowPlayingHint = '播放开始时把当前曲目显示在服务上';
  static const scrobbleSave = '保存';
  static const scrobbleTest = '测试连接';
  static const scrobbleTesting = '正在测试…';
  static const scrobbleSaved = '听歌记录设置已保存';
  static const scrobbleTestOk = '连接正常';
  static const scrobbleTestFailed = '连接测试失败';
  static const scrobbleClearSecrets = '清除已保存的凭据';
  static const scrobbleSecretKept = '留空保留已保存的值';
  static const scrobbleNotConfigured = '缺少凭据，尚未启用上报';
  static const scrobbleDisabled = '未启用';
  static const scrobbleReady = '已就绪';
  static String scrobbleQueue(int n) => n > 0 ? '待补报 $n 条' : '队列为空';
  static const scrobbleLastSuccess = '最近成功';

  static const backup = '备份与恢复';
  static const diagnostics = '诊断';
  static const diagnosticLogs = '诊断日志';
  static const diagnosticLogsHint = '查看最近的核心日志并复制；敏感字段已自动打码';
  static const about = '关于';
  static const coreVersion = '核心版本';
  static const deviceId = '设备 ID';
  static const copy = '复制';
  static const copied = '已复制';
  static const unavailable = '不可用';
  static const saveFailed = '保存设置失败';
}
