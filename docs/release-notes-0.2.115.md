月兔音乐（Lekis Music）0.2.115 预览版，启动初始化更紧凑。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **启动初始化并行化**：应用数据目录、缓存目录和设备名改为并行解析，缩短首帧前的串行等待。
- 包含 0.2.114 的资料库多选加入歌单、0.2.113 的喜欢页保存为歌单和 0.2.112 的播放历史保存为歌单。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.115-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.115-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.115-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.115-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.115-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.115-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.115-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.115 preview release, with a tighter startup initialization. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Parallel startup initialization**: the app data directory, cache directory and device name are resolved concurrently, shortening the serial wait before the first frame.
- Includes the 0.2.114 library multi-select add-to-playlist, 0.2.113 Liked Songs save-as-playlist and 0.2.112 history save-as-playlist.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
