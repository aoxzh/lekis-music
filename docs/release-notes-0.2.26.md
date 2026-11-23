月兔音乐（Lekis Music）0.2.26 预览版，桌面端扩大封面解码缓存，大专辑墙滚动更少重复解码。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **桌面封面解码缓存**：桌面端把 Flutter 图片缓存上限从默认约 100 MB 提高到 192 MB，大专辑墙快速滚动时更少反复解码封面；手机仍使用平台默认值，避免占用过多内存。
- 包含 0.2.25 的正在播放快速均衡器、0.2.24 的一键扫描全部音源和 0.2.23 的音质标签来源入口。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.26-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.26-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.26-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.26-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.26-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.26-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.26-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.26 preview release, enlarging the desktop artwork decode cache so large album walls stop re-decoding covers while scrolling. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Desktop artwork cache**: the desktop Flutter image-cache budget rises from the default ~100 MB to 192 MB, reducing repeated cover decodes when scrolling big album walls quickly. Phones keep the platform default to stay memory-friendly.
- Includes the 0.2.25 Now Playing equalizer shortcut, 0.2.24 scan-all-sources and 0.2.23 quality-badge source entry.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
