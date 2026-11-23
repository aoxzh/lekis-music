月兔音乐（Lekis Music）0.2.35 预览版，桌面播放队列可以一键清空并停止播放。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **清空播放队列**：桌面队列标题栏新增清空按钮，确认后立即停止播放并清空队列。核心里 `play_tracks([])` 现在作为清队指令，不需要逐首删除，十万首队列也能立刻清空。
- 包含 0.2.34 的独占模式 HQ 标志、0.2.33 的封面预取防抖和 0.2.32 的歌词字号。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.35-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.35-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.35-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.35-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.35-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.35-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.35-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.35 preview release, adding a one-click clear-queue action to the desktop queue. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Clear the queue**: the desktop queue header now has a clear button; after confirmation playback stops and the queue is emptied. The core treats `play_tracks([])` as a clear command, so even a 100k-track queue is cleared instantly instead of one row at a time.
- Includes the 0.2.34 exclusive-mode HQ indicator, 0.2.33 cover-prefetch debounce and 0.2.32 lyric text size.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
