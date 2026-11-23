月兔音乐（Lekis Music）0.2.3 预览版。本版本修复 Windows 在线更新「下载完成但重启后仍是旧版」的问题，并改用更常规的安装包：macOS 只发 Apple Silicon 的 DMG / ZIP，Windows 提供安装器 EXE，Linux 提供 AppImage。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

> **Windows 用户注意**：0.2.2 及更早版本的在线更新在退出时会崩溃，脚本没机会替换文件，所以这次请**手动安装 0.2.3 一次**（下载 `lekis-0.2.3-windows-x64-setup.exe`，或解压便携 ZIP 覆盖原目录）。装好 0.2.3 之后，后续版本可以正常在线更新。

*English summary below.*

## 修复

- **Windows 在线更新原地踏步**：从 0.2.1 / 0.2.2 点「立即重启更新」时，主程序在退出阶段崩在 `cnativeapi.dll`（`0xc0000005`），更新脚本没来得及运行，重启后仍是旧版。现在更新器改为像托盘「退出」一样正常关闭窗口，替换脚本会等待进程退出、复制失败自动重试 60 次（约 30 秒），并把过程写到 `%LOCALAPPDATA%\Lekis\update.log`；复制失败会重新拉起旧版，不再静默消失。
- **Android 安装兼容性**：release APK 同时使用 v1 / v2 / v3 签名，避免部分国产 ROM 安装器只看 `META-INF` 里的 JAR 证书、把 v2-only 安装包误报为「未包含开发者证书」。签名证书不变，覆盖升级不受影响。

## 发布格式

- **macOS**：只提供 Apple Silicon（arm64），新增 DMG（打开后把 Lekis 拖进 Applications），ZIP 继续保留给应用内更新。
- **Windows**：新增每用户安装器 `*-setup.exe`（装到 `%LOCALAPPDATA%\Programs\Lekis`，不需要管理员权限，应用内更新有写权限）；便携 ZIP 继续保留。
- **Linux**：新增单文件 AppImage，`.tar.gz` 继续保留给应用内更新。
- 应用内更新会优先选择可解压的 ZIP / tar.gz，不会误选 DMG、AppImage 或安装器。

### 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.3-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.3-windows-x64-setup.exe` | 推荐：每用户安装器，支持后续在线更新 |
| Windows x64 | `lekis-0.2.3-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.3-macos-arm64.dmg` | 打开后拖入 Applications；未签名，首次右键 → 打开 |
| macOS（Apple Silicon） | `lekis-0.2.3-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.3-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.3-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.3 preview release. This fixes Windows in-app updates that downloaded successfully but restarted into the old build, and moves to conventional packages: Apple Silicon DMG/ZIP for macOS, an installer EXE for Windows, and an AppImage for Linux.

> **Windows note:** in-app update in 0.2.2 and earlier crashes while exiting, so the helper never replaces the files. Please **install 0.2.3 manually once** (`lekis-0.2.3-windows-x64-setup.exe`, or extract the portable ZIP over the old folder). After 0.2.3, in-app updates work normally.

**Fixes**

- **Windows in-app update stuck on the old build**: clicking "Restart to Update" in 0.2.1/0.2.2 crashed the app during shutdown in `cnativeapi.dll` (`0xc0000005`) before the helper could run. The updater now closes the window gracefully (like the tray Quit item), the helper waits for the process, retries the copy up to 60 times (~30 s), logs to `%LOCALAPPDATA%\Lekis\update.log`, and relaunches the old build if the copy still fails instead of leaving the app closed.
- **Android install compatibility**: release APKs now carry v1 + v2 + v3 signatures, so OEM installers that only inspect `META-INF` JAR certificates no longer report "no developer certificate" for a v2-only package. The signing certificate is unchanged; updates keep working.

**Packages**

- **macOS**: Apple Silicon only. New DMG (drag Lekis into Applications) plus the ZIP used by in-app updates.
- **Windows**: new per-user installer `*-setup.exe` (installs to `%LOCALAPPDATA%\Programs\Lekis`, no admin prompt, writable for in-app updates) plus the portable ZIP.
- **Linux**: new single-file AppImage plus the `.tar.gz` used by in-app updates.
- The updater prefers extractable ZIP / tar.gz assets and never picks a DMG, AppImage or installer by mistake.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
