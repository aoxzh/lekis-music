月兔音乐（Lekis Music）0.5.5 预览版：统一操作菜单与二级面板，修复 Android 详情返回，并让大字号界面不再裁切。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 说明

本版合并了 PR #13（hal-pixel），把资料库、播放队列、搜索、播客、设置、音源、歌词和歌单编辑里的操作菜单、二级页面与返回动效统一起来。

## 改进

### 资料库菜单与返回

- 专辑、艺人和文件夹补齐「更多」菜单，长按和右键同样可以打开。
- 艺人和文件夹详情改用资料库导航栈，按系统返回时回到原来的列表位置。
- 专辑的导出和复制收进详情菜单。

### 统一的二级面板

- 曲目、歌单、节目、设置项和插件操作的列表在手机端使用底部面板，桌面端沿用锚定菜单。
- 需要输入或确认的流程在同一个面板里切换步骤，并遵循系统的「减少动效」设置。
- 窄屏听歌统计重新排列，信息不再互相挤压。

### 歌词与编辑流程

- 歌词预览返回后保留草稿和滚动位置。
- 写入标签的确认与结果、M3U / XSPF 导入结果沿用当前面板。
- 批量任务结束时只关闭该任务的进度面板，不再连带关掉其他面板。

### 设置与音源

- 统一列表行、单选项、输入框和确认面板的外观与返回方式。
- 远程目录可以逐层返回，插件详情里的选择流程与返回顺序理顺。

## 修复

- **大字号下的界面裁切**：把系统字体调大（Windows「文本大小」、Android「字体大小」）后，桌面播放条、迷你播放器、歌曲列表、正在播放页的「艺人 · 专辑 · 音质」行、播放队列和均衡器不再溢出或被裁切。
- **窄窗口播放条**：桌面播放条在窗口收窄时先隐藏随机 / 循环等次要开关，并让右侧操作区等比收缩，不再出现黄色溢出条。
- **官网无障碍**：官网支持 `prefers-reduced-motion`，补齐键盘焦点框、界面预览标签页语义与方向键切换，语言切换会同步 `<html lang>` 并记住选择；首屏吉祥物新增 2× 响应式图源。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.5.5-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.5.5-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.5.5-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.5.5-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.5.5-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.5.5-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.5.5-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.5.5 preview release unifies action menus and second-level sheets, fixes Android detail back navigation, and stops large accessibility text sizes from clipping the interface. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**Notes**

This release merges PR #13 (hal-pixel), bringing the action menus, second-level pages and back transitions in the library, queue, search, podcasts, settings, sources, lyrics and playlist editing under one set of behaviours.

**Improved**

- **Library menus and back**: albums, artists and folders gain a “More” menu that also opens on long press and right-click. Artist and folder details use the library navigation stack, so system back returns to the previous list position. Album export and copy move into the detail menu.
- **Shared second-level sheets**: track, playlist, episode, setting and plugin actions use a bottom sheet on phones and an anchored menu on desktop; flows that need input or confirmation switch steps inside the same sheet, and follow the system reduce-motion setting. Narrow listening-stats layouts are rearranged.
- **Lyrics and editing**: the lyrics preview keeps its draft and scroll position when you go back. Tag-write confirmations and results, and M3U / XSPF import results, stay in the current sheet, and a finished batch task closes only its own progress panel.
- **Settings and sources**: list rows, radio options, inputs and confirmation panels share the same look and back behaviour; remote folders climb one level at a time, and plugin detail selection follows the expected order.

**Fixed**

- **Large text sizes**: with the system font scaled up (Windows “Text size”, Android “Font size”), the desktop player bar, mini player, track list, the Now Playing “artist · album · quality” line, the queue and the equalizer no longer overflow or clip.
- **Narrow player bar**: secondary toggles (shuffle / repeat) fold away first as the window narrows, and the right-hand actions scale down, so the bar no longer shows an overflow stripe.
- **Website accessibility**: the site respects `prefers-reduced-motion`, adds keyboard focus rings, tab semantics and arrow-key switching for the interface previews, syncs `<html lang>` with the language choice and remembers it, and serves a 2× hero mascot on high-DPI screens.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
