月兔音乐（Lekis Music）0.2.91 预览版，专辑和艺人详情会短暂缓存，来回切换更顺畅。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **专辑/艺人详情缓存**：专辑、艺人及其曲目/专辑数据短暂缓存 2 分钟，返回上一页或切换详情时不再立即重新查询；资料库变化时仍会失效。
- 包含 0.2.90 的时长统计缓存、0.2.89 的歌词来源标识和 0.2.88 的下载按艺人排序。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.91-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.91-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.91-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.91-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.91-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.91-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.91-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.91 preview release, caching album and artist details. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Album/artist detail cache**: album, artist, track-list and artist-album queries are briefly cached for two minutes, so going back or switching details does not immediately re-query; catalog changes still invalidate them.
- Includes the 0.2.90 duration cache, 0.2.89 lyrics source badge and 0.2.88 downloads-by-artist sort.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
