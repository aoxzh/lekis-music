月兔音乐（Lekis Music）0.2.96 预览版，播放历史查询会短暂缓存并在切歌时刷新。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **播放历史缓存**：播放历史查询缓存 30 秒，返回页面时复用数据；切歌时自动失效刷新。
- 包含 0.2.95 的下载按专辑排序、0.2.94 的播放历史搜索与复制和 0.2.93 的队列移到顶部/底部。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.96-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.96-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.96-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.96-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.96-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.96-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.96-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.96 preview release, caching playback history briefly. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Playback-history cache**: the recent-history query is cached for 30 seconds and refreshed when the playing track changes.
- Includes the 0.2.95 downloads-by-album sort, 0.2.94 history search/copy and 0.2.93 queue move-to-top/bottom.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
