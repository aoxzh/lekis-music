月兔音乐（Lekis Music）0.2.4 预览版。本版本重新整理资料库在窄窗口下的分类导航，移动端音源选择改成底部面板，专辑与艺人详情统一为可关闭的分栏视图；同时包含 0.2.3 的 Windows 在线更新修复和新的安装包格式。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

> **Windows 用户注意**：0.2.2 及更早版本的在线更新在退出时会崩溃，这次请**手动安装 0.2.4 一次**（`lekis-0.2.4-windows-x64-setup.exe`，或解压便携 ZIP 覆盖原目录）。装好 0.2.4 之后，后续版本可以正常在线更新。

*English summary below.*

## 变更

- **资料库窄屏分类条**：窄窗口下分类改为横向可滚动的 chip 条，选中的分类会自动滚入可见区域；标题和工具按钮按页边距对齐，宽屏继续使用整排 SegmentedButton。
- **音源选择面板**：移动端 / 窄窗口的音源选择改为带当前项勾选的底部面板，桌面端保留下拉框；切换音源时清空已选专辑和艺人，避免详情残留。
- **专辑 / 艺人统一分栏**：宽屏和折叠屏展开时，专辑 / 艺人列表与详情并排显示，详情右上角可关闭；窄屏仍保持页面跳转。
- 包含 0.2.3 的修复：Windows 在线更新改为正常关窗退出，替换脚本增加等待、重试和 `%LOCALAPPDATA%\Lekis\update.log` 日志；Android APK 启用 v1 / v2 / v3 签名。

## 安装包

- **Windows**：`*-setup.exe` 每用户安装器（装到 `%LOCALAPPDATA%\Programs\Lekis`，无需管理员权限）或便携 ZIP。
- **macOS**：Apple Silicon（arm64）DMG（拖入 Applications）或 ZIP。
- **Linux**：单文件 AppImage 或 `.tar.gz`。
- **Android**：arm64 APK。

### 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.4-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.4-windows-x64-setup.exe` | 推荐：每用户安装器，支持后续在线更新 |
| Windows x64 | `lekis-0.2.4-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.4-macos-arm64.dmg` | 打开后拖入 Applications；未签名，首次右键 → 打开 |
| macOS（Apple Silicon） | `lekis-0.2.4-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.4-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.4-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.4 preview release. This reworks library category navigation on narrow windows, moves the mobile source picker into a bottom sheet, and unifies album/artist details into a closable split view. It also includes the Windows updater fix and package formats from 0.2.3.

> **Windows note:** in-app update in 0.2.2 and earlier crashes while exiting. Please **install 0.2.4 manually once** (`lekis-0.2.4-windows-x64-setup.exe`, or extract the portable ZIP over the old folder). After 0.2.4, in-app updates work normally.

**Changes**

- **Compact library category strip**: categories become a horizontally scrollable chip strip on narrow windows, and the selected chip scrolls into view. Title and tools now align to the page gutter; wide layouts keep the SegmentedButton.
- **Source picker sheet**: mobile/narrow layouts pick the library source from a bottom sheet with a check on the current item; desktop keeps the combo box. Switching sources clears the selected album/artist so stale details do not linger.
- **Unified album/artist split view**: wide and unfolded layouts show the list and details side by side, with a close button in the details pane; narrow layouts still navigate to a page.
- Includes 0.2.3 fixes: Windows in-app updates close the window gracefully, the helper waits/retries and logs to `%LOCALAPPDATA%\Lekis\update.log`; Android APKs carry v1 / v2 / v3 signatures.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
