月兔音乐（Lekis Music）0.2.7 预览版，修复播放命令异步失败被吞掉、界面「点了没反应」的问题，并补上侧车迁移状态显示。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 修复

- **播放失败不再静默**：播放 / 暂停 / 切歌 / 跳转 / 音量等核心命令是异步的，旧代码用同步 `try/catch` 包住，Promise 失败会变成未处理异常，用户看不到原因。现在统一捕获并在任意页面弹出 SnackBar，例如 NAS 断连或音源凭据失效时能直接看到提示。
- **侧车迁移状态**：设置 → 整理资料库 →「补全结果写入音源目录」会根据核心的迁移 marker 显示「启动后会在后台写回一次」或「已有补全结果已写回音源目录」。
- 包含 0.2.6 的 NAS 播放修复：播放前重新校验并重开失效的 VFS，文件系统副本不可用时继续尝试其他来源。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.7-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.7-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.7-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.7-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.7-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.7-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.7-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.7 preview release, fixing async playback-command failures that were swallowed (the UI appeared to do nothing) and adding sidecar migration status.

**Fixes**

- **Playback failures are visible now**: play / pause / next / seek / volume commands are async, but the old code wrapped them in a synchronous `try/catch`; a rejected Future became an unhandled error. Failures are now caught and shown in a SnackBar on any page, including NAS disconnects and expired source credentials.
- **Sidecar migration status**: Settings → Library Tools → "Save Enrichment to Source Folders" shows whether existing results will be migrated after startup or have already been written.
- Includes the 0.2.6 NAS playback fix: re-check and reopen stale VFS connections before playing, and try another copy when a filesystem copy is unavailable.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
