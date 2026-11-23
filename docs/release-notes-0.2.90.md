月兔音乐（Lekis Music）0.2.90 预览版，专辑/艺人/歌单的总时长改为缓存计算。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **时长统计缓存**：专辑、艺人和歌单的总时长改由 provider 缓存，只在曲目数据变化时重新求和，搜索/过滤/进度刷新不再重复遍历。
- 包含 0.2.89 的歌词来源标识、0.2.88 的下载按艺人排序和 0.2.87 的最近搜索逐条删除。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.90-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.90-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.90-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.90-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.90-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.90-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.90-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.90 preview release, caching total-duration calculations. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Cached duration totals**: album, artist and playlist running times are now memoized providers that recompute only when the track data changes, not on search, filtering, or progress refreshes.
- Includes the 0.2.89 lyrics source badge, 0.2.88 downloads-by-artist sort and 0.2.87 per-item recent-search removal.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
