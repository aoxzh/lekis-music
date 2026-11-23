月兔音乐（Lekis Music）0.2.61 预览版，下载状态查询改为 O(1)，长下载库更顺畅。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **下载状态查找更快**：下载状态改为懒加载索引，长下载库中每首曲目查询下载状态从线性扫描变为 O(1)；进度更新仍复用不可变状态。
- 包含 0.2.60 的下载行操作/失败原因、0.2.59 的专辑/艺人总时长和 0.2.58 的歌单总时长。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.61-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.61-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.61-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.61-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.61-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.61-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.61-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.61 preview release, making download status lookups O(1). Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Faster download lookups**: download state now builds a lazy index, so checking a track's download status in a large library is O(1) instead of a linear scan; progress updates still reuse immutable state.
- Includes the 0.2.60 download-row actions/failure details, 0.2.59 album/artist durations and 0.2.58 playlist duration.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
