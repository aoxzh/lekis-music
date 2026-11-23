月兔音乐（Lekis Music）0.2.37 预览版，调整 SQLite WAL 检查点，减少大库批量写入时的磁盘同步。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **减少 WAL 检查点**：写连接改为每 2000 页才自动 checkpoint（约 8 MB），并把 WAL 文件上限设为 32 MB。大库扫描和批量写入时 fsync 次数更少，同时不会让 `-wal` 文件无限增长。
- 包含 0.2.36 的音源维护索引、0.2.35 的清空播放队列和 0.2.34 的独占模式 HQ 标志。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.37-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.37-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.37-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.37-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.37-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.37-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.37-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.37 preview release, tuning SQLite WAL checkpoints for large-library batch writes. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Fewer WAL checkpoints**: the writer checkpoints every 2000 pages (about 8 MB) instead of every 1000, and the WAL file is capped at 32 MB. Large scans and batch writes perform fewer fsyncs while the `-wal` file stays bounded.
- Includes the 0.2.36 source-maintenance indexes, 0.2.35 clear queue and 0.2.34 exclusive-mode HQ indicator.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
