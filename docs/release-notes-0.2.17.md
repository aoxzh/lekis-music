月兔音乐（Lekis Music）0.2.17 预览版，正在播放显示当前音质，并减少每次启动时不必要的数据库统计维护。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **启动时不再每次维护统计信息**：`PRAGMA optimize` 只在本次启动确实执行了数据库迁移后运行；已经升级过的资料库再次启动时不再做这份额外工作，新索引仍然在升级后的第一次启动生效。

## 新增

- **正在播放显示音质**：标题下的「艺人 · 专辑」行会追加当前曲目的音质标签（如 FLAC 24/96），选源结果更直观。
- 包含 0.2.16 的扫描剩余时间、0.2.15 的搜索结果分类筛选和 0.2.14 的最近搜索。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.17-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.17-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.17-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.17-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.17-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.17-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.17-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.17 preview release, showing the current audio quality in Now Playing and avoiding unnecessary database statistics work on every launch. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **No stats maintenance on every launch**: `PRAGMA optimize` now runs only when this launch actually applied a database migration. Already-upgraded libraries no longer pay that cost on every start; new indexes still take effect on the first launch after upgrading.

**New**

- **Audio quality in Now Playing**: the artist · album line now appends the current track's quality badge (for example FLAC 24/96), making source selection visible at a glance.
- Includes the 0.2.16 remaining scan time, 0.2.15 search result filters, and 0.2.14 recent searches.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
