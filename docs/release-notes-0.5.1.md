月兔音乐（Lekis Music）0.5.1 预览版：新增新版主动提醒与自定义插件源。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **新版主动提醒**：启动后静默检查 GitHub Releases，发现新版本时主动提示升级。
  - **稍后**：本次运行不再打扰，下次启动再提醒。
  - **忽略此版本**：记住该版本，之后不再提示；出现更新版本时会再次提醒。
  - **立即更新**：桌面端应用内下载并校验后一键重启更新；Android 打开 APK 下载。
  - 迷你播放器模式下会等到窗口展开再提示。
- **自定义插件源**：插件页可以添加任意 HTTPS 插件目录（`catalog.json`），与内置社区目录并列浏览，每个源可单独刷新或移除。
  - 地址校验只接受 HTTPS，拒绝带用户名或密码的链接。
  - 插件包按各自源的目录解析，安装前仍校验 SHA-256。
  - 插件源列表保存在本地设置，不会上传。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.1-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.1-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.1-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.1-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.1-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.1-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.1-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.1 preview release adds proactive update reminders and custom plugin sources. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Proactive update reminders**: a quiet check runs after startup; when a new release is available, choose **Later**, **Ignore this version**, or **Update now**. Ignored versions are remembered and a newer release will prompt again. Desktop downloads and restarts in place; Android opens the APK download.
- **Custom plugin sources**: add any HTTPS plugin catalog (`catalog.json`) next to the built-in community source, browse each source separately, and remove user-added sources. Only HTTPS URLs without credentials are accepted; packages resolve relative to their own catalog and are still verified with SHA-256.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
