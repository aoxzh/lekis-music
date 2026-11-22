月兔音乐（Lekis Music）第一个发布到 GitHub 的预览版。这是 Alpha：日常听歌已经能用，但仍会有粗糙的地方，欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

*The first published preview of Lekis Music. English summary below.*

## 亮点

- **桌面迷你播放器**（Windows / macOS / Linux）：点桌面播放条最右侧的按钮，主窗口缩成置顶小条，只留封面、歌名 / 艺人、上一首 / 播放 / 下一首和进度。小条可以拖到任何位置，下次会回到同一个地方；点右上角按钮回到完整窗口，原来的窗口大小和打开的页面都还在。
- **macOS 与 Linux 桌面版**：除 Android 和 Windows 外，首次提供 macOS Universal（Apple Silicon + Intel）和 Linux x64 包。
- **检查更新**：「设置 → 关于」里可以检查 GitHub 上的新版本。
- **重复歌曲清理**：「资料库检查 → 重复歌曲」可一键删除低音质版本，可选同时删除本地 / NAS 上的源文件。
- **封面与歌词补全**：新增 6 个免 API Key 的歌词和封面源，日系 / ACG 专辑命中率更高（日区 iTunes、VocaDB），补全时显示实时进度，可选只补封面或只补歌词。
- **中英双语界面**，以及黑胶 / 磁带播放页样式、桌面悬浮歌词（Windows）、局域网设备遥控（Connect）、多设备同步。
- **浅色模式对比度**全应用修复。

完整变化见 [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md)。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.1.0-alpha.2-android-arm64-v8a.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.1.0-alpha.2-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS | `lekis-0.1.0-alpha.2-macos-universal.zip` | 未签名公证：首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine lekis.app` |
| Linux x64 | `lekis-0.1.0-alpha.2-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 里是所有文件的 SHA-256 校验和。

## 已知限制

- Alpha 版：数据库迁移只增不改，可以从开发版直接升级，但请对重要歌单做好备份。
- 媒体服务器源（Jellyfin / Emby / Plex / OpenSubsonic）还在完善中。
- macOS 包没有签名和公证。

---

## English

**Highlights**

- **Desktop mini player** (Windows / macOS / Linux): the button at the far right of the desktop player bar shrinks the window into an always-on-top strip with the cover, title / artist, previous / play / next and progress. Drag it anywhere; it remembers its spot. The corner button brings back the full window as you left it.
- **macOS (Universal) and Linux x64** desktop builds, alongside Android and Windows.
- **Update check** under Settings → About.
- **Duplicate cleanup**: delete lower-quality copies of a song, optionally including the files on disk / NAS.
- **Artwork and lyrics enrichment**: six more sources that need no API key, better hits for Japanese / ACG releases, live progress, and cover-only or lyrics-only runs.
- English and Simplified Chinese UI, vinyl and cassette now-playing styles, Windows desktop lyrics, LAN remote control (Connect), multi-device sync, and light-mode contrast fixes.

**Downloads:** Android arm64 APK, Windows x64 zip (portable, run `lekis.exe`), macOS Universal zip (unsigned: right-click → Open the first time), Linux x64 tar.gz. Checksums are in `SHA256SUMS.txt`.

See [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md) for everything else.
