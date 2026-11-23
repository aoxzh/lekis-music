月兔音乐（Lekis Music）0.2.9 预览版，重点优化大资料库的数据库读取和队列操作：更大的 SQLite 页缓存与内存映射、高频查询索引，以及队列一键定位到正在播放。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **SQLite 缓存与内存映射**：每个数据库连接使用 8 MiB 页缓存和 64 MiB 只读 mmap（默认约 2 MiB），减少十万首曲库翻页、搜索和统计时反复读 B 树；启动迁移后自动执行 `PRAGMA optimize`，让查询计划及时用上新索引。
- **高频索引**：流派页、专辑艺人页、单曲播放历史、歌单包含关系和补全候选查询不再全表扫描。升级后第一次打开会建立索引，之后只增量维护。

## 新增

- **队列定位到正在播放**：桌面队列标题栏新增定位按钮，手动滚动后可以一键回到当前曲目；打开队列时仍会自动定位一次。
- 包含 0.2.8 的睡眠定时淡出、播放失败重试和 NAS 文件校验超时。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.9-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.9-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.9-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.9-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.9-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.9-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.9-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.9 preview release, focused on large-library database reads and queue navigation: a larger SQLite page cache and memory map, indexes for hot queries, and a one-tap jump to the current track in the queue. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **SQLite cache and mmap**: every database connection now uses an 8 MiB page cache and a 64 MiB read-only mapping (up from the ~2 MiB default), reducing repeated B-tree reads while paging, searching and computing stats on 100k-track libraries. `PRAGMA optimize` runs after startup migrations so the planner sees new indexes promptly.
- **Hot-query indexes**: genre pages, album-artist pages, per-track play history, playlist membership and enrichment-candidate lookups no longer scan whole tables. The indexes are created on the first open after upgrading and then maintained incrementally.

**New**

- **Jump to Now Playing in the queue**: a locate button in the desktop queue header returns to the current track after manual scrolling; opening the queue still auto-locates once.
- Includes the 0.2.8 sleep-timer fade-out, playback retry and NAS file-check timeout.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
