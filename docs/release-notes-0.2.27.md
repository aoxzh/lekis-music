月兔音乐（Lekis Music）0.2.27 预览版，歌词面板会在后台预取下一首歌词，切歌更顺滑。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **歌词页预取下一首歌词**：歌词面板打开时会在后台预取下一首队列曲目的歌词，切歌时更少从加载状态开始；只预取下一首，失败静默忽略。
- 包含 0.2.26 的桌面封面解码缓存、0.2.25 的快速均衡器和 0.2.24 的一键扫描全部音源。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.27-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.27-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.27-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.27-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.27-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.27-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.27-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.27 preview release, prefetching the next track's lyrics while the lyrics pane is open. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Next-lyrics prefetch**: when the lyrics pane is visible, the app quietly fetches the next queue item's lyrics so track changes start with less loading. Only one item ahead is prefetched; failures are ignored.
- Includes the 0.2.26 desktop artwork cache, 0.2.25 quick equalizer and 0.2.24 scan-all-sources.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
