月兔音乐（Lekis Music）0.2.8 预览版，给睡眠定时加上淡出和播放页快捷入口，并让 NAS 掉线时更快报错、可直接重试。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **睡眠定时淡出**：正在播放页底部新增月亮按钮，可直接选择 15 / 30 / 60 / 90 分钟或「放完这首」，不用再进设置。倒计时最后 8 秒音量平滑降到 0 再暂停，暂停后恢复原音量，下次播放不会变成静音；淡出期间手动调音量会以手动值为准。
- **播放失败可重试**：失败提示条增加「重试」。NAS 短暂断连、切回局域网或重新挂载后，不用重新点进专辑。

## 修复

- **NAS 文件校验超时**：播放前 10 秒内无法确认目标文件可访问时，提示「音源响应超时，请检查 NAS 连接」，并丢弃失效的 VFS 连接，下次播放会按音源配置重开，不再无限转圈。
- 包含 0.2.7 的播放错误可见、侧车迁移状态，以及 0.2.6 的 NAS 播放重连修复。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.8-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.8-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.8-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.8-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.8-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.8-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.8-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.8 preview release, adding sleep-timer fade-out and a quick entry on Now Playing, plus faster NAS failure reporting and retry. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Sleep timer with fade-out**: a moon button at the bottom of Now Playing offers 15 / 30 / 60 / 90 minutes or "End of Track" without opening Settings. The last 8 seconds fade smoothly to silence, then playback pauses and the previous volume is restored; changing volume manually during the fade wins.
- **Retry playback failures**: the failure SnackBar now has a Retry action, useful after a brief NAS disconnect or remount.

**Fixes**

- **NAS file-check timeout**: if the target file cannot be confirmed within 10 seconds, playback fails with "source response timed out; check the NAS connection" and the stale VFS is dropped so the next attempt reopens it, instead of spinning forever.
- Includes the 0.2.7 visible playback errors and sidecar migration status, plus the 0.2.6 NAS reconnect fix.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
