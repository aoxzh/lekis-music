月兔音乐（Lekis Music）0.6.0 预览版：新增 Android 桌面小组件、Chromecast / DLNA 投放、APE / TTA / DSD 与 CUE 整轨播放、交叉淡入淡出、NAS 流媒体播放缓存、存储管理与统一资料库自动合并。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### Android 桌面小组件

- 提供 4×1 紧凑条与拉高后的大封面两种自适应布局，配色跟随系统深浅色。
- 播放/暂停、上一首、下一首走与通知栏、蓝牙按键一致的媒体控制通道；点按主体打开「正在播放」页。
- 可在「设置 → 外观」直接点击「桌面小组件 · 添加」添加到桌面。

### Chromecast 与 DLNA / UPnP 投放

- 播放设备选择面板新增「Chromecast / DLNA 音箱」区域，自动发现局域网内的 Chromecast 与支持 UPnP AVTransport 的音箱、功放、Hi-Fi 数播。
- 直接复用本机局域网 HTTP Range 流服务推送音频，支持暂停/继续、音量滑块调节与停止投放。

### APE / TTA / DSD 与 CUE 整轨支持

- 原生纯 Rust 解码 `.ape`（Monkey's Audio）、`.tta`（True Audio）和 `.dsf` / `.dff`（DSD 转 PCM），无需外部 FFmpeg。
- 自动解析 `.cue` 分轨表（支持 GBK / 日文 / UTF-8 编码自动识别，并兼容 `.cue` 引用 `.wav` 而实际音频是 `.ape` / `.flac` 的命名），将整轨拆分为多首独立曲目播放与精准定位。

### 交叉淡入淡出

- 真正的等功率（cos/sin）双轨交叉淡入淡出，结合 EBU R128 响度检测曲目尾声静音提前过渡；同专辑连续曲目仍自动保持无缝播放。
- 可在「设置 → 播放」中调节淡入时长（关闭 / 1–12 秒）与智能跳过尾声静音。

### NAS 流媒体播放缓存与存储管理

- 播放 NAS / 媒体服务器曲目时在后台自动缓存到本地，支持配置上限（默认 2 GB，可选关闭 / 512 MB – 10 GB）并按最近使用自动淘汰；断网或外出时优先播放已缓存曲目。
- 「设置 → 高级 → 存储管理」按类别展示封面缓存、流媒体播放缓存、离线下载、其他临时缓存与数据库占用，支持按类别清理与一键清理全部缓存。

### 统一资料库自动合并

- 扫描完成后自动合并多个音源里的同一首歌，播放时自动选择音质最好且可达的源；已手动拆分的曲目不会被重新合并。
- 「设置 → 整理资料库」支持开关自动合并，并可手动运行「快速标签合并」或基于 Chromaprint 的「深度音频指纹合并」。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.6.0-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.6.0-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.6.0-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.6.0-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.6.0-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.6.0-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.6.0-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.6.0 preview release adds the Android home screen widget, Chromecast & DLNA casting, native APE / TTA / DSD & CUE sheet playback, equal-power crossfade, NAS streaming playback cache, storage management, and unified library auto-merge. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Android home screen widget**: adaptive 4×1 compact bar and taller cover layout following system light/dark theme, using the same media-button controls as notifications and Bluetooth; add directly from Settings → Appearance.
- **Chromecast & DLNA/UPnP casting**: discover LAN Chromecast devices and DLNA/UPnP speakers & receivers in the device picker, stream via the local HTTP Range server, and control play/pause, volume, and stop.
- **Native APE / TTA / DSD & CUE sheet playback**: pure-Rust decoders for `.ape`, `.tta`, `.dsf`, and `.dff` (no FFmpeg required), plus automatic `.cue` sheet parsing (with UTF-8/GBK/CJK charset detection and stem fallback) splitting single-file albums into individual seekable tracks.
- **Real crossfade**: equal-power dual-track mixing with EBU R128 trailing-silence detection (consecutive tracks on the same album stay gapless); configurable in Settings → Playback.
- **NAS streaming playback cache & storage management**: automatic LRU background cache for remote/NAS playback with offline fallback and configurable size limit (Settings → Advanced → Storage Management), plus category storage breakdown and one-tap cache cleanup.
- **Unified library auto-merge**: automatically merges matching tracks across sources after scans while respecting manual splits, with optional on-demand Quick Metadata or Chromaprint Audio Fingerprint merge in Settings → Library Tools.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
