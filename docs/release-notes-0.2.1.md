月兔音乐（Lekis Music）0.2.1 预览版。本版本新增桌面端应用内在线自更新，并修复了补全封面候选确认时的报错问题。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

*English summary below.*

## 亮点

- **桌面端应用内在线更新**（Windows / macOS / Linux）：不用再手动跳浏览器下包覆盖。启动后静默检测新版本，在「设置 → 关于 → 检查更新」里即可直接下载（带进度条与速度）、自动校验 `SHA256SUMS.txt`、解压暂存并一键重启应用更新。若运行在只读目录（例如 macOS DMG 镜像或无写权限的目录），会自动回退为打开下载页。
- **Android 通知栏播放控件修复与美化**：修复 release 包因资源压缩误删播放按钮图标导致通知栏按钮空白的问题；换用自定义圆角矢量图标与单色小图标，暂停时保持前台服务常驻，并对通知封面做 300×300 限幅与多档缓存兜底，兼顾原生 Android 现代媒体卡片与 OriginOS / HyperOS / ColorOS / MagicOS 等国产 ROM。
- **修复补全封面候选确认报错**：修复在「待确认的补全」里接受专辑封面候选时，因为清理过期候选把自身一并标记导致返回 `NotFound` 的问题。

完整变化见 [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md)。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.1-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.1-windows-x64.zip` | 免安装：解压后运行 `lekis.exe`（后续版本支持应用内在线更新） |
| macOS | `lekis-0.2.1-macos-universal.zip` | 未签名公证：首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine lekis.app` |
| Linux x64 | `lekis-0.2.1-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 里是所有文件的 SHA-256 校验和。从 0.1.0-alpha.2 / 0.2.0 可以直接覆盖安装升级。

---

## English

Lekis Music 0.2.1 preview release, adding in-app self-updating on desktop and fixing an artwork candidate acceptance bug.

**Highlights**

- **Desktop in-app self-update** (Windows / macOS / Linux): checks quietly on startup and lets you download with live progress and speed, verify `SHA256SUMS.txt`, unpack to staging, and restart to apply right from Settings → About → Check for Updates. Falls back to the release page when running from a read-only location.
- **Android notification media controls**: fixed release builds stripping `audio_service` button drawables (blank buttons), replaced them with sleek rounded vector icons and a monochrome status icon, kept the foreground service active on pause, and added 300×300 artwork downscaling with bucket fallback for stock Android and OEM ROMs (OriginOS / HyperOS / ColorOS / MagicOS).
- **Fix artwork enrichment acceptance**: accepting a pending album cover candidate no longer fails with `NotFound` due to stale-candidate cleanup running before marking the candidate accepted.

**Downloads:** Android arm64 APK, Windows x64 zip (portable, run `lekis.exe`), macOS Universal zip (unsigned: right-click → Open the first time), Linux x64 tar.gz. Checksums are in `SHA256SUMS.txt`. Installs over 0.1.0-alpha.2 and 0.2.0.
