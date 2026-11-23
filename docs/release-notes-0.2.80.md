月兔音乐（Lekis Music）0.2.80 预览版，下载页在进度更新时不再反复重排列表。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **下载页排序/过滤缓存**：下载页按结构版本缓存过滤和排序后的 ID；下载进度更新时只重新映射当前条目，不再每 200ms 重排整个列表。
- 包含 0.2.79 的统计页跳转、0.2.78 的歌单条目移到顶部/底部和 0.2.77 的下载排序。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.80-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.80-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.80-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.80-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.80-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.80-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.80-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.80 preview release, avoiding repeated downloads-list sorting on progress updates. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Cached downloads filtering/sorting**: the page caches filtered and sorted IDs by a structure version; progress updates only remap the current entries instead of re-sorting the whole list every 200 ms.
- Includes the 0.2.79 stats navigation, 0.2.78 playlist move-to-top/bottom and 0.2.77 downloads sorting.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
