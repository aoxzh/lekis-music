月兔音乐（Lekis Music）0.2.5 预览版，修复「补全缺失封面 / 歌词」每次只处理 50 首的问题。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 修复

- **补全不再只处理 50 首**：旧逻辑写死了 `batchLimit = 50`，只读健康报告第一页就停。现在按 200 条一页读取，收集整个资料库的缺失曲目后一次任务补完；进度条显示总数，随时可以取消。
- 仅补全封面时仍按专辑去重，同一张缺封面的专辑只查一首代表曲目，避免重复请求和重复候选。
- 包含 0.2.4 的资料库窄屏分类条、移动端音源选择面板、专辑/艺人统一分栏，以及 0.2.3 的 Windows 在线更新修复和 Android v1 / v2 / v3 签名。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.5-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.5-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.5-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.5-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.5-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.5-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.5-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.5 preview release, fixing "Fetch Missing Covers / Lyrics" stopping after 50 tracks.

**Fix**

- **The whole library is processed now**: the old code hard-coded `batchLimit = 50` and read only the first health-report page. It now pages through the health report (200 rows per page), collects every missing track, and runs one enrichment job with a total progress bar and cancel support.
- Artwork-only runs still deduplicate by album: one representative track per album is enough because applying the cover updates the album.
- Includes the 0.2.4 library navigation improvements (compact category strip, mobile source picker, unified album/artist split view) and the 0.2.3 Windows updater fix plus Android v1/v2/v3 signing.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
