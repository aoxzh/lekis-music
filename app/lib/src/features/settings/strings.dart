// 设置页的全部文案。先写死简体中文，之后换 i18n 时只改这一个文件。

abstract final class SettingsStrings {
  static const title = '设置';

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
  static const replayGain = '音量平衡（ReplayGain）';
  static const replayGainHint = '按文件里的 ReplayGain 信息统一响度';
  static const rgTrack = '按曲目';
  static const rgAlbum = '按专辑';
  static const rgOff = '关闭';

  static const appearance = '外观';
  static const theme = '主题';
  static const themeSystem = '跟随系统';
  static const themeLight = '浅色';
  static const themeDark = '深色';
  static const themeOled = '纯黑';
  static const themeOledHint = '纯黑适合 OLED 屏幕，更省电';

  static const library = '资料库';
  static const sources = '音源';
  static const sourcesHint = '管理本地文件夹、NAS 和媒体服务器';
  static const enrichReview = '待确认的补全';
  static const enrichReviewHint = '检查自动找到的封面、歌词和标签';
  static String pendingCount(int n) => '$n 条待确认';

  static const about = '关于';
  static const coreVersion = '核心版本';
  static const deviceId = '设备 ID';
  static const copy = '复制';
  static const copied = '已复制';
  static const unavailable = '不可用';
  static const saveFailed = '保存设置失败';
}
