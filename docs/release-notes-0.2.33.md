月兔音乐（Lekis Music）0.2.33 预览版，快速连续切歌时不再为每一首发起封面预取。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **封面预取防抖**：快速连续切歌时不会为每一首立即发起下一首封面请求，只有当前曲目稳定 350ms 后才预取，减少无意义的网络与磁盘抖动。
- 包含 0.2.32 的歌词字号、0.2.31 的播放栏独占模式快捷开关和 0.2.30 的来源列表直达音源详情。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.33-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.33-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.33-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.33-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.33-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.33-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.33-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.33 preview release, debouncing next-cover prefetch during rapid track skipping. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Debounced cover prefetch**: rapidly skipping tracks no longer starts a next-cover request for every track. Prefetch starts only after the current track has been stable for 350 ms, avoiding unnecessary network and disk churn.
- Includes the 0.2.32 lyric text size, 0.2.31 player-bar exclusive-mode toggle and 0.2.30 source list → source detail link.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
