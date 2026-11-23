月兔音乐（Lekis Music）0.2.64 预览版，多个下载同时进行时界面更新更平滑。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **下载进度更新节流**：多个下载同时进行时，进度事件先合并，最多每 200ms 刷新一次界面；批量更新只重建一次状态与索引。
- 包含 0.2.63 的下载搜索、0.2.62 的下载分组缓存和 0.2.61 的 O(1) 下载状态索引。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.64-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.64-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.64-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.64-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.64-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.64-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.64-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.64 preview release, smoothing the UI while several downloads run. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Throttled download progress**: progress events are coalesced and the UI refreshes at most every 200 ms; a batch update rebuilds the state and index once.
- Includes the 0.2.63 download search, 0.2.62 cached download groups and 0.2.61 O(1) download lookup.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
