月兔音乐（Lekis Music）0.2.36 预览版，给音源维护和未见到文件清理补上源优先索引。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 性能

- **音源维护索引**：新增 `track_file(source_id, track_id)` 与 `file(source_id, last_seen_at)` 索引，删除音源、清理未见到文件和大型曲库增量扫描时不再按源全表扫描；升级后第一次启动自动建立。
- 包含 0.2.35 的清空播放队列、0.2.34 的独占模式 HQ 标志和 0.2.33 的封面预取防抖。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.36-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.36-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.36-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.36-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.36-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.36-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.36-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.36 preview release, adding source-first indexes for library maintenance and unseen-file cleanup. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Performance**

- **Source maintenance indexes**: new `track_file(source_id, track_id)` and `file(source_id, last_seen_at)` indexes avoid source-wide table scans when removing a source, cleaning unseen files or incrementally rescanning a large library. They are created on the first launch after upgrading.
- Includes the 0.2.35 clear queue, 0.2.34 exclusive-mode HQ indicator and 0.2.33 cover-prefetch debounce.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
