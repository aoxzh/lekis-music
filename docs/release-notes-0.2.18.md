月兔音乐（Lekis Music）0.2.18 预览版，睡眠定时按钮会显示剩余分钟数。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **睡眠定时倒计时**：正在播放的月亮按钮会显示剩余整分钟数，提示文字包含「剩余约 X 分钟」；分钟数每 30 秒刷新一次，迷你播放器保持紧凑不显示数字。
- 包含 0.2.17 的在播放页显示音质标签，以及只在迁移后维护数据库统计的启动优化。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.18-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.18-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.18-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.18-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.18-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.18-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.18-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.18 preview release, adding a remaining-minute countdown to the sleep timer button. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Sleep timer countdown**: the moon button on Now Playing shows the remaining whole minutes, with "about X min left" in its tooltip. The badge refreshes every 30 seconds; the compact mini player stays uncluttered.
- Includes the 0.2.17 audio-quality badge and the startup optimization that only maintains database statistics after migrations.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
