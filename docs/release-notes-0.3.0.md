月兔音乐（Lekis Music）0.3.0 预览版：把 0.2.27 – 0.2.119 的连续更新合并成一次发布。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 合并说明

之前每个提交都会发布一个小版本，Releases 页面因此堆了上百个条目。0.3.0 把这些版本的内容收拢成一个版本，旧的 tag 与 Release 已删除；逐版本的详细记录仍保留在 [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md)。

## 新增

- **播放与队列**：资料库长列表可从任意位置展开完整队列；歌单、喜欢、历史、搜索和下载页支持一键播放/随机播放；队列可清理重复、清除未播放、打乱后续、移到顶部/底部、查找跳转、复制和保存为歌单。
- **歌单管理**：合并歌单、排序/反转/随机顺序、复制、清理缺失和重复曲目、批量移除、多选加入歌单，以及把喜欢的歌曲/播放历史保存为歌单。
- **下载**：按标题、艺人、专辑、最新添加或文件大小排序；支持搜索和「全部 / 队列 / 失败 / 已下载」筛选；可批量重试和清理；下载行可直接播放、在文件夹中显示或用其他应用打开。
- **歌词**：来源与格式标识、字号档位、翻译开关、偏移快捷条、复制纯文本、下一首歌词预取。
- **资料库与搜索**：分页预取与缓存、搜索结果加载更多、搜索结果批量保存/下载、专辑页「更多来自」、艺人页展开全部歌曲与整组下载。
- **统计、首页与电台**：最常听曲目/艺人/专辑直达与一键播放、首页歌架播放/随机、电台本地搜索与排序。
- **外观与桌面**：五种强调色、WASAPI 独占快捷开关与 HQ 标识、播放快捷键帮助、图片缓存管理、Windows 托盘显示当前歌曲。
- **性能**：启动路径并行解析，播放历史、搜索、详情、时长、下载状态等多处缓存与索引，WAL checkpoint 调优。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.3.0-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.3.0-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.3.0-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.3.0-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.3.0-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.3.0-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.3.0-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.3.0 preview release folds the continuous 0.2.27 – 0.2.119 updates into a single version. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**About the merge**

Previously every commit published its own small release, leaving over a hundred entries on the Releases page. 0.3.0 consolidates their contents into one version; the old tags and releases were removed, and the per-version history remains in [CHANGELOG.md](https://github.com/aoxzh/lekis-music/blob/main/CHANGELOG.md).

**New**

- **Playback and queue**: expand the full queue from any row in long library lists; play/shuffle everything from playlists, liked songs, history, search and downloads; clear duplicates or unplayed tracks, shuffle the rest, move to top/bottom, find in queue, copy the queue and save it as a playlist.
- **Playlist management**: merge playlists, sort / reverse / shuffle order, duplicate, remove missing and duplicate tracks, multi-select removal, multi-select add to playlist, and save liked songs or history as a playlist.
- **Downloads**: sort by title, artist, album, newest or size; search and filter by all / queued / failed / downloaded; bulk retry and cleanup; play, reveal in folder, or open with another app.
- **Lyrics**: source and format labels, font-size presets, translation toggle, offset quick bar, copy as plain text, prefetch the next track's lyrics.
- **Library and search**: paged prefetch and caches, load more search results, batch save/download search results, "more from this artist" on albums, expand all songs and bulk download on artist pages.
- **Stats, home and radio**: jump to and play top tracks/artists/albums, play/shuffle from home shelves, local radio search and sorting.
- **Appearance and desktop**: five accent colors, WASAPI exclusive-mode shortcut with HQ badge, playback shortcut help, image cache management, current track in the Windows tray tooltip.
- **Performance**: parallelized startup, caches and indexes for history, search, details, durations and download state, WAL checkpoint tuning.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
