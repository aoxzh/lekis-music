月兔音乐（Lekis Music）0.2.46 预览版，下载列表刷新更省资源。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **下载列表刷新更快**：下载进行中时列表会频繁刷新，现在复用已加载的曲目信息，只查询新增条目，并把并发桥接调用限制为 8 个；大下载库不再因为每次进度变化而重复拉取全部曲目。
- 包含 0.2.45 的重试全部失败下载、0.2.44 的清理失败记录和 0.2.43 的复制歌单。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.46-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.46-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.46-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.46-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.46-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.46-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.46-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.46 preview release, making the downloads list cheaper to refresh. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Faster downloads refresh**: while downloads are running the list refreshes often. It now reuses track metadata already on screen, resolves only new entries, and limits bridge calls to eight at a time, so large download libraries no longer re-fetch every track on each progress change.
- Includes the 0.2.45 retry-all-failed, 0.2.44 clear-failed-records and 0.2.43 duplicate playlist.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
