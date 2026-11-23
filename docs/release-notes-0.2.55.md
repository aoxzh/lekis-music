月兔音乐（Lekis Music）0.2.55 预览版，歌曲库可以一键播放或随机播放。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **歌曲库一键播放**：歌曲列表顶部新增「播放全部 / 随机播放」，通过核心的库上下文直接展开队列，不需要先把整个歌曲库的 ID 拉进内存。
- 包含 0.2.54 的 Windows 托盘当前歌曲、0.2.53 的复制歌词和 0.2.52 的流派页下载全部歌曲。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.55-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.55-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.55-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.55-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.55-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.55-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.55-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.55 preview release, adding play-all / shuffle-all to the Songs library. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Play the whole library in one tap**: the Songs list header now offers Play All and Shuffle All. The core expands the library context directly, so the UI never has to pull every track id into memory.
- Includes the 0.2.54 Windows tray now-playing tooltip, 0.2.53 copy lyrics and 0.2.52 genre download-all.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
