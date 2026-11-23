月兔音乐（Lekis Music）0.2.34 预览版，正在播放会显示当前是否处于独占输出。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **正在播放显示独占模式**：使用 WASAPI 独占 / bit-perfect 输出时，标题下的音质行会追加 HQ 图标与说明，方便确认当前确实绕过了系统混音。
- 包含 0.2.33 的封面预取防抖、0.2.32 的歌词字号和 0.2.31 的播放栏独占模式快捷开关。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.34-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.34-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.34-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.34-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.34-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.34-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.34-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.34 preview release, showing when Now Playing is using exclusive output. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Exclusive-mode indicator**: when WASAPI exclusive / bit-perfect output is active, an HQ icon and explanation appear on the quality line under the title, confirming that the system mixer is bypassed.
- Includes the 0.2.33 cover-prefetch debounce, 0.2.32 lyric text size and 0.2.31 player-bar exclusive-mode toggle.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
