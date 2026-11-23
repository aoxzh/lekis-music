月兔音乐（Lekis Music）0.2.38 预览版，同步歌词右下角新增快捷偏移浮条。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **歌词偏移快捷条**：同步歌词右下角新增小浮条，可直接「提前 0.5 秒 / 延后 0.5 秒 / 重置」，不必打开「更多」菜单；调整后立即刷新并写回当前歌词版本。
- 包含 0.2.37 的 WAL 检查点优化、0.2.36 的音源维护索引和 0.2.35 的清空播放队列。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.38-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.38-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.38-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.38-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.38-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.38-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.38-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.38 preview release, adding a quick lyric-offset bar over synced lyrics. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Quick lyric-offset bar**: synced lyrics now show a small floating control in the bottom-right with "0.5s earlier / 0.5s later / reset". It refreshes the lyrics and writes back to the active lyric version immediately, without opening the More menu.
- Includes the 0.2.37 WAL checkpoint tuning, 0.2.36 source-maintenance indexes and 0.2.35 clear queue.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
