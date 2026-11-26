月兔音乐（Lekis Music）0.6.3 预览版：全平台优化系统级应用显示名称——中文系统显示为「月兔音乐」，英文及其他系统显示为「Lekis Music」，方便用户在设备搜索框中直接搜「音乐」或「music」找到应用，包名与安装路径保持不变。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 改进

### 全平台应用名称按系统语言显示

- **Android**：桌面图标、系统应用列表与多任务卡片按系统语言显示「月兔音乐」或「Lekis Music」；通知渠道与小组件英文文案同步统一（应用包名 `dev.lekis.lekis` 保持不变，直接覆盖安装保留全部数据）。
- **macOS**：补充 `InfoPlist.strings`（`en` / `zh-Hans` / `zh-Hant`）与 `LSHasLocalizedDisplayName`，在访达、启动台、Spotlight、菜单栏与窗口标题栏按系统语言显示「月兔音乐」或「Lekis Music」。
- **Windows**：安装器按系统界面语言创建「月兔音乐」或「Lekis Music」开始菜单与桌面快捷方式，窗口标题与系统托盘提示实时跟随语言切换，并补充双语可执行文件版本信息。
- **Linux**：AppImage `.desktop` 补充中文名称与中英文搜索关键词（`music;audio;player;lekis;音乐;播放器;月兔;`），GTK 窗口标题同步按系统语言显示。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.6.3-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.6.3-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.6.3-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.6.3-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.6.3-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.6.3-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.6.3-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.6.3 preview release localizes the OS-level app display name across all platforms — **月兔音乐** on Chinese systems and **Lekis Music** on English/other systems — so searching "音乐" or "music" in your device launcher finds it immediately, while keeping all package names and bundle IDs unchanged. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Improved**

- **Localized system app display name**:
  - **Android**: launcher icon, Settings app list, recent tasks, and notification channel display **月兔音乐** on Chinese locales and **Lekis Music** on English/other locales (`dev.lekis.lekis` unchanged).
  - **macOS**: added `InfoPlist.strings` (`en`, `zh-Hans`, `zh-Hant`) and `LSHasLocalizedDisplayName` for Finder, Launchpad, Spotlight, menu bar, and window title.
  - **Windows**: localized Start Menu / Desktop shortcuts, uninstall entry, window title (updating live when switching language), system tray tooltip, and executable metadata.
  - **Linux**: localized AppImage `.desktop` entry with English and Chinese search keywords and locale-aware GTK window title.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
