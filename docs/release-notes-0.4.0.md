月兔音乐（Lekis Music）0.4.0 预览版：合并 PR #5，按音源浏览资料库、播放队列筛选、歌词来源与格式、导出与分享等一批功能。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 资料库与搜索

- 点击资料库标题打开音源选择器：本地存储、NAS 源和插件各自浏览，专辑/艺人详情、文件夹和播放队列都跟随当前音源。
- 搜索框与范围控件改为紧凑布局；桌面端 Find 快捷键会聚焦当前可见的搜索框。

### 播放与歌单

- 播放队列支持筛选、播放匹配项和「下一首播放」；清除筛选后恢复完整队列的当前顺序。
- 曲目可预览并记住备用在线音源；macOS 和 Android 支持在应用内打开 Bilibili 官方播放器（含多 P 视频）。
- 筛选后的歌单条目可以整组选择；「移到顶部」现在真的排到第一；删除选中项前会核对曲目身份，移动/排序后选择不再失效。

### 歌词

- 重新搜索可编辑歌名/艺人，对比并记住歌词版本；内置 QQ 音乐歌词源，改进了视频式标题的匹配。
- 支持本地 WebVTT、QRC、YRC、KRC 歌词；新增可分享的舞台预设、对唱/合唱舞台，以及带逐字时间的对开页布局。

### 导出与插件

- 按文件名模板把曲目/专辑导出到指定目录，可选封面和歌词。
- 浏览并订阅支持插件的集合。

### 界面

- 进度盘封面视图、全景迷你播放器布局；修复封面显示和资料库长按选择。

## 修复

- 批量加入歌单会去重并跳过已在歌单里的曲目。
- 长任务结束后只在页面仍存在时刷新列表，成功提示不再被吞。
- 进度对话框不会被系统返回键关闭，避免误 pop 下面的页面。
- 喜欢页的「保存/下载全部」分页到空页为止，不再受打开时的数量快照限制。
- 播放上下文失败会显示错误提示；迷你播放器横向滚动不再改变音量。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.4.0-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.4.0-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.4.0-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.4.0-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.4.0-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.4.0-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.4.0-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.4.0 preview release merges PR #5: per-source library browsing, queue filtering, lyric sources and formats, exports and sharing. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Library and search**

- The Library title opens the source picker: browse local storage, a NAS source, or a plugin, and have album/artist details, folders and playback queues follow the selected source.
- The search field and scope controls share a compact layout; the desktop Find shortcut focuses the visible search field.

**Playback and playlists**

- Filter the queue, play a matching entry, or move it to play next. Clearing the filter restores the full queue in its current order.
- Preview alternative online sources for a track and remember the selected version. Open the official Bilibili player for supported tracks on macOS and Android, including multipart videos.
- Select all filtered playlist entries, move an entry to the top, and check track identity before removing a selected entry (moves and sorts no longer break the selection).

**Lyrics and export**

- Search again with an edited title or artist, compare lyric versions, and remember a choice for the track. Add built-in QQ Music lyrics lookup and improve matching for video-style titles.
- Read local WebVTT, QRC, YRC and KRC lyrics. Add shareable stage presets, a duet/chorus stage, and a facing-page layout with word timing.
- Export a track or album to a chosen directory with a filename template, optional artwork and lyrics. Browse and subscribe to collections from supported plugins.

**Fixes**

- Batch add-to-playlist deduplicates and skips tracks already in the playlist.
- Long tasks only refresh providers while the page is still mounted, so success messages are no longer swallowed.
- Progress dialogs can't be dismissed with the system back button, so they no longer pop the page underneath.
- Liked-songs save/download-all pages until an empty page instead of a snapshot count.
- Failed playback contexts surface an error, and horizontal trackpad scrolling no longer changes the mini-player volume.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
