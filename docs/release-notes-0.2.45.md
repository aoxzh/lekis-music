月兔音乐（Lekis Music）0.2.45 预览版，失败下载可以一键全部重试。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **重试全部失败下载**：下载页批量菜单新增重试全部失败项，逐条重新入队并提示成功数量；仍失败的条目会留在列表里，可继续单条重试或清理。
- 包含 0.2.44 的清理失败记录、0.2.43 的复制歌单和 0.2.42 的歌词翻译开关。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.45-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.45-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.45-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.45-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.45-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.45-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.45-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.45 preview release, adding a retry-all-failed-downloads action. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Retry all failed downloads**: the Downloads batch menu re-queues every failed item one by one and reports how many were accepted; anything still failing stays in the list for individual retry or clearing.
- Includes the 0.2.44 clear-failed-records, 0.2.43 duplicate playlist and 0.2.42 lyric translation switch.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
