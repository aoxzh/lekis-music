月兔音乐（Lekis Music）0.5.0 预览版：合并 PR #12，改进音源添加、播放队列、手机播放页、曲库搜索和设置搜索。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **首次添加音源**：首页和曲库空状态可以一键进入添加流程；手机推入添加页，桌面展开右侧面板。
- **队列连续移除**：连续点击立即按位置移除，支持重复曲目和列表刷新期间的操作。
- **手机播放页**：窄屏标题占满两行，操作按钮移到艺人行；单人曲直达艺人页，多人曲可选择艺人。
- **曲库搜索**：本地搜索没有结果时，可以沿用关键词搜索指定的已启用在线音源，点击后才联网。
- **设置搜索**：手机和桌面共用歌词、音频输出、插件的设置索引，点击结果会滚动到目标控件并高亮。
- **曲目副标题**：省略与曲名相同的专辑名，保留不同的专辑名。

## 修复

- 插件页和安装确认框明确声明：插件均由社区第三方制作和维护，不是月兔音乐官方提供，与应用及内容权益方无隶属、合作或背书关系。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.0-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.0-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.0-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.0-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.0-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.0-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.0-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.0 preview release merges PR #12 with improvements to adding sources, the playback queue, the mobile player, library search and settings search. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **First source setup**: add a source in one tap from the home or library empty state; phones push the add page, desktops open the right-hand panel.
- **Continuous queue removal**: repeated taps remove entries immediately by position, including duplicate tracks and while the list refreshes.
- **Mobile player**: the title fills two lines on narrow screens and the actions move to the artist row; single-artist tracks jump straight to the artist, multi-artist tracks let you choose.
- **Library search**: when local results are empty, search the selected enabled online sources with the same keyword; the network is only used after you tap.
- **Settings search**: phones and desktops share an index for lyrics, audio output and plugin settings; tapping a result scrolls to and highlights the control.
- **Track subtitles**: hide the album name when it matches the title, keep it otherwise.

**Fixes**

- The plugin page and install confirmation now state that plugins are made and maintained by third-party community contributors, are not provided by Lekis Music, and are unaffiliated with the app or any content rights holder.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
