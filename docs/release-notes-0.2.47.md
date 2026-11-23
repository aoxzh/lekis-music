月兔音乐（Lekis Music）0.2.47 预览版，艺人页可以一键下载全部歌曲。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **艺人页下载全部歌曲**：艺人标题栏的播放/随机旁边新增下载按钮，一次把该艺人的全部歌曲加入离线下载；全部已下载时按钮显示为完成状态。
- **批量下载按钮更快**：判断“是否已全部下载”时改用集合查找，大艺人、大歌单不再为每首歌线性扫描下载列表。
- 包含 0.2.46 的下载列表刷新优化、0.2.45 的重试全部失败下载和 0.2.44 的清理失败记录。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.47-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.47-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.47-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.47-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.47-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.47-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.47-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.47 preview release, adding download-all for an artist. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Download all songs on an artist page**: a download button sits next to Play / Shuffle in the artist header and queues every song by that artist; once everything is offline the button shows a completed state.
- **Faster batch download buttons**: the "all downloaded" check now uses a set lookup, so large artists and playlists no longer scan the download list once per track.
- Includes the 0.2.46 downloads refresh optimization, 0.2.45 retry-all-failed and 0.2.44 clear-failed-records.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
