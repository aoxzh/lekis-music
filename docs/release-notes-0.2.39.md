月兔音乐（Lekis Music）0.2.39 预览版，下载页可以一次清理已完成的离线缓存。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **清理已完成下载**：下载页批量菜单新增「清理已完成的下载」，确认后一次删除本机离线缓存并显示清理数量；失败会提示，不影响未完成的下载。
- 包含 0.2.38 的同步歌词快捷偏移浮条、0.2.37 的 WAL 检查点优化和 0.2.36 的音源维护索引。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.39-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.39-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.39-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.39-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.39-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.39-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.39-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.39 preview release, adding one-click cleanup of completed offline downloads. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Clear completed downloads**: the Downloads batch menu now offers "Clear Completed Downloads"; after confirmation it deletes the local offline files and reports how many were removed. Failures are shown and in-progress downloads are untouched.
- Includes the 0.2.38 quick lyric-offset bar, 0.2.37 WAL checkpoint tuning and 0.2.36 source-maintenance indexes.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
