月兔音乐（Lekis Music）0.6.4 预览版：歌词能从投稿和视频标题里识别歌名，设置里可以打包诊断信息并提交问题，无缝播放开关和平板界面也已修正。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **反馈问题**：在设置中保存诊断包（版本、界面配置、已脱敏的最近日志），再打开预填好的 GitHub Issue。不会自动上传；设备 ID 默认不附带。
- **插件目录开关**：插件管理移到「设置 → 通用」。关闭后不再读取内置社区插件目录，自己添加的插件源和已安装插件保持可用。

## 改进

- **歌词匹配**：从投稿和视频标题中提取歌名与艺人。置信度不够的候选留在待确认列表，需要时再查看。
- **空状态吉祥物**：资料库、歌单等空页面显示月兔状态图。

## 修复

- **无缝播放开关生效**：设置中的无缝播放会作用到播放引擎。
- **平板保持手机界面**：平板和展开的折叠屏继续使用移动端界面。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.6.4-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.6.4-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.6.4-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.6.4-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.6.4-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.6.4-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.6.4-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.6.4 preview improves lyric matching for upload and video titles, adds a diagnostics bundle for bug reports, and fixes the gapless toggle and tablet layout. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Added**

- **Report a problem**: save a diagnostics bundle (versions, UI settings, redacted recent logs) and open a prefilled GitHub issue. Nothing is uploaded automatically, and the device ID is off by default.
- **Plugin catalog toggle**: plugin management now lives under Settings → General. Turning off the built-in community catalog leaves your own sources and installed plugins alone.

**Improved**

- **Lyric matching**: song and artist names are read from upload and video titles. Uncertain matches stay in the review list instead of being written automatically.
- **Empty-state mascot**: empty library and playlist screens show the moon-rabbit mascot.

**Fixed**

- **Gapless toggle**: the playback setting now reaches the engine.
- **Tablet layout**: tablets and unfolded foldables stay on the mobile shell.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
