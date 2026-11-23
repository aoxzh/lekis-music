月兔音乐（Lekis Music）0.2.29 预览版，睡眠定时可以再延长 15 分钟，并减少不必要的后台计时。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **睡眠定时延长 15 分钟**：已设置限时睡眠定时时，月亮菜单底部新增「再延长 15 分钟」，从原截止时间往后顺延，并重新安排淡出。
- **定时按钮只在需要时计时**：没有限时定时器时不再每 30 秒唤醒刷新倒计时，减少后台无意义的重建。
- 包含 0.2.28 的五种强调色预设、0.2.27 的歌词下一首预取和 0.2.26 的桌面封面缓存。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.29-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.29-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.29-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.29-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.29-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.29-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.29-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.29 preview release, adding a 15-minute sleep-timer extension and avoiding idle background ticking. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Extend the sleep timer by 15 minutes**: when a timed sleep timer is active, the moon menu now offers "Extend 15 min", pushing the deadline back and rescheduling the fade-out.
- **Tick only when needed**: with no timed sleep timer, the button no longer wakes every 30 seconds to refresh a countdown that is not shown.
- Includes the 0.2.28 accent presets, 0.2.27 next-lyrics prefetch and 0.2.26 desktop artwork cache.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
