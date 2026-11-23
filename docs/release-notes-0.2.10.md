月兔音乐（Lekis Music）0.2.10 预览版，把「放完这首」睡眠定时也做成平滑淡出，并在桌面播放栏显示当前定时状态。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **「放完这首」也会淡出**：睡眠定时选择「放完这首」时，最后 8 秒按剩余时长平滑淡出；往后拖进度会取消本次淡出并恢复音量；淡出期间手动调音量仍然以手动值为准。
- **播放栏显示定时状态**：睡眠定时激活后，桌面播放栏会出现月亮按钮，可直接改时间或关闭，不必先打开正在播放页。
- 包含 0.2.9 的 SQLite 大库性能优化、队列定位到正在播放，以及 0.2.8 的睡眠定时 / 播放重试 / NAS 超时。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.10-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.10-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.10-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.10-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.10-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.10-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.10-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.10 preview release, adding fade-out for the "End of Track" sleep timer and a timer indicator in the desktop player bar. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **End-of-Track fade-out**: when the sleep timer is set to "End of Track", the last 8 seconds fade smoothly according to the remaining time. Seeking back cancels this fade and restores the volume; manual volume changes still win.
- **Timer indicator in the player bar**: while a sleep timer is active, the desktop player bar shows a moon button for changing or cancelling it without opening Now Playing.
- Includes the 0.2.9 SQLite large-library performance work and queue jump-to-current, plus the 0.2.8 sleep timer / playback retry / NAS timeout.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
