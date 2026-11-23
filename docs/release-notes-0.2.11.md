月兔音乐（Lekis Music）0.2.11 预览版，把扫描流程里最慢的读标签阶段改成受控并行，大库和 NAS 全量扫描更快。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **扫描时并行读取标签**：目录遍历完成后，读取文件头尾和解析标签会按音源建议的并发度并行执行（上限 16）；写库仍按原顺序批量提交，进度保持单调。机械盘 / 网络共享上的全量扫描不再串行等待每个文件。
- 包含 0.2.10 的「放完这首」淡出、播放栏定时状态，0.2.9 的 SQLite 大库优化和 0.2.8 的 NAS 超时 / 播放重试。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.11-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.11-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.11-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.11-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.11-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.11-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.11-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.11 preview release, making the slowest part of scanning — reading tags — run with bounded concurrency, so large libraries and NAS scans finish sooner. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Parallel tag reads during scans**: after the directory walk, head/tail reads and tag parsing run concurrently up to the source's suggested concurrency (capped at 16). Database writes still happen in the original order and in batches, and progress stays monotonic. Full scans on spinning disks and network shares no longer wait for one file at a time.
- Includes the 0.2.10 End-of-Track fade and player-bar timer status, the 0.2.9 SQLite large-library work, and the 0.2.8 NAS timeout / playback retry.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
