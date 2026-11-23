月兔音乐（Lekis Music）0.2.21 预览版，播放时会在后台预取下一首封面，切歌更少出现空白封面。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **预取下一首封面**：播放当前曲目时会在后台解析下一首的封面并让核心缓存；切歌时在线封面更少出现空白/加载，使用体验更接近本地库。
- 包含 0.2.20 的队列长按直达专辑 / 艺人，以及 0.2.19 的队列长按收藏 / 排序 / 移除。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.21-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.21-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.21-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.21-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.21-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.21-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.21-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.21 preview release, prefetching the next track's artwork in the background so track changes show a cover sooner. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Next-cover prefetch**: while the current track plays, the app resolves the next queue item's artwork in the background and warms the core cache. Online covers show up sooner when the queue advances.
- Includes the 0.2.20 queue long-press album/artist links and the 0.2.19 favorite/reorder/remove actions.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
