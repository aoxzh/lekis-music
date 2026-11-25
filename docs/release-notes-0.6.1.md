月兔音乐（Lekis Music）0.6.1 预览版：修复插件音源误触发封面补全，新增正在播放页封面搜索/上传/编辑面板，优化在线更新 Markdown 显示与手机端每日自动检测提示。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

### 正在播放页封面补全与编辑

- 正在播放页「更多」菜单新增「补全封面 / 编辑封面」入口（无封面时直接显示「补全封面」并自动检索候选）。
- 支持按歌名、艺人、专辑在线搜索高清封面并大图预览选用，也支持上传本地图片、粘贴图片链接、勾选同时应用到整张专辑、移除当前封面以及操作后一键撤销。

## 改进

### 在线更新体验优化

- 更新弹窗现已完整渲染 Markdown（支持标题、列表、加粗、行内代码、可点击链接、分割线与表格），不再直接显示原始 `#` / `**` 文本。
- 启动及每次打开「设置」页时，按本地自然日每天最多静默检测一次更新；发现新版本后手机端与桌面端均主动弹窗提醒，并在「设置 → 关于」显示更新标记。当天不再重复弹窗检测，用户仍可手动点击「检查更新」。

## 修复

### 补全封面范围限定

- 封面自动补全与资料库健康「缺失封面」检测现已严格限定在本地音乐与 NAS 文件系统音源（Local / SMB / WebDAV / NFS / SFTP），不再对已有独立封面逻辑的插件音源触发封面补全，同时自动清理历史残留的插件封面待确认候选。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.6.1-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.6.1-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.6.1-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.6.1-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.6.1-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.6.1-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.6.1-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.6.1 preview release restricts automatic artwork enrichment to local and NAS libraries, adds a cover search/upload/edit sheet to Now Playing, renders Markdown release notes in the update dialog, and checks for updates once per day when opening Settings on mobile and desktop. Please [open an issue](https://github.com/aoxzh/lekis-music/issues) for problems.

**New**

- **Now Playing artwork search, upload & edit**: open the Now Playing “More” menu to fetch missing covers or edit existing artwork — search online covers by title/artist/album with preview, upload a local image, paste an image URL, optionally apply to the whole album, remove artwork, or undo.

**Improved**

- **Rendered Markdown release notes**: the in-app update dialog now renders headings, lists, bold text, inline code, tappable links, dividers, and tables instead of raw Markdown.
- **Once-daily update check on mobile & desktop**: opening Settings (or launching the app) checks for updates silently at most once per calendar day, prompting proactively when a newer release is available and showing a badge on About. Manual checks remain available anytime.

**Fixed**

- **Local & NAS only artwork enrichment**: plugin sources with their own artwork logic are no longer counted as missing covers in Library Health or queued for automatic artwork enrichment, and stale plugin artwork review candidates are automatically dismissed.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
