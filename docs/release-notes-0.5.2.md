月兔音乐（Lekis Music）0.5.2 预览版：修复 Windows 应用内更新重启后仍是旧版的问题。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 修复

- **Windows 应用内更新不生效**：更新助手原来以普通的分离进程启动，Lekis 退出时会被系统一并结束，文件实际上从未被替换。现在改为通过 `cmd.exe start` 启动独立进程，等待 Lekis 退出后再覆盖安装目录并启动新版本。
- 更新过程写入 `%LOCALAPPDATA%\Lekis\update.log`，包含启动、文件替换和重启结果，方便排查。

> 如果你当前是 0.5.1 或更早版本，请先手动安装本版本一次；之后的在线更新会使用修复后的流程。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.2-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.2-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.2-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.2-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.2-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.2-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.2-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.2 preview release fixes in-app updates on Windows, where the app restarted into the old version. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Fix**

- The update helper used to be a plain detached process, so Windows terminated it together with Lekis and the files were never replaced. It is now launched through `cmd.exe start` in an independent process, waits for Lekis to exit, replaces the installation and starts the new version.
- Progress is logged to `%LOCALAPPDATA%\Lekis\update.log` (launch, replacement, relaunch).

> If you are on 0.5.1 or older, install this version manually once; later in-app updates will use the fixed flow.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
