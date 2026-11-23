月兔音乐（Lekis Music）0.2.62 预览版，下载页的分组与数量改用缓存，长列表更省。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **下载列表派生状态缓存**：下载页的「队列 / 失败 / 已下载」分组改为懒加载列表，每次进度更新不再重复过滤全部下载记录；数量徽标也直接复用缓存。
- 包含 0.2.61 的 O(1) 下载状态索引、0.2.60 的下载行操作和 0.2.59 的专辑/艺人总时长。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.62-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.62-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.62-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.62-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.62-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.62-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.62-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.62 preview release, caching the derived download groups. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Cached download groups**: Queue / Failed / Downloaded are now lazy lists, so progress updates no longer refilter every download record; the filter counts reuse the same cache.
- Includes the 0.2.61 O(1) download lookup, 0.2.60 download-row actions and 0.2.59 album/artist durations.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
