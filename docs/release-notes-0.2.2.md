月兔音乐（Lekis Music）0.2.2 预览版。本版本新增 macOS 桌面歌词与菜单栏歌词、音源插件播放协议、插件资料库 / 搜索和注音歌词，并修复远程音频读取与迷你播放器恢复等问题。从本版本起，普通 0.x 版本按正式 GitHub Release 发布。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

*English summary below.*

## 新增

- **macOS 桌面歌词与菜单栏歌词**：独立开关控制桌面歌词面板和菜单栏歌词，支持逐词高亮、拖动、锁定，并恢复上次的位置与不透明度；菜单栏显示当前歌词，点击回到主窗口。
- **音源插件播放协议**：曲目用「插件 ID + 来源曲目 ID」稳定标识，播放前重新解析流地址并校验请求头和目标域名，链接过期后队列里的歌也能继续播。
- **插件资料库与搜索**：插件音源支持分页浏览、专辑目录、搜索与封面；在线曲目按稳定 ID 导入，列表、队列和播放器共用封面缓存。插件私有存储与逐项权限在安装时确认，Android 原生扩展需要单独授权。
- **资料库、专辑与歌词编辑**：窄窗口可通过菜单进入全部资料库分类；服务器专辑保留身份与多碟顺序，支持专辑目录查询；歌词编辑器支持候选预览、匹配和逐词时间轴解析。
- **注音歌词**：设置 → 外观 → 歌词 → 注音歌词，可在经典歌词的每个汉字上方显示拼音，支持不带声调 / 带声调符号 / 声调数字；离线计算，不联网、不加词典包。

## 修复

- **远程音频 Range 读取**：只允许 GET 的签名地址不再因 HEAD 被拒而打不开；连接提前关闭时最多重试一次，并保留 Range 与鉴权请求头。
- **迷你播放器**：退出迷你模式时恢复进入前的 macOS 全屏状态，窄窗口下播放控制仍可点到。
- **插件外部程序**：不再嵌套 Tokio 运行时；输出超过 8 MiB 时立即停止读取并结束子进程。
- **macOS 构建与运行库**：修正 Swift 并发运行库的 `@rpath` 配置位置，测试二进制和桌面歌词不再找不到 `libswift_Concurrency.dylib`。
- **macOS 应用图标**：换成完整的月兔品牌 AppIcon，不再显示 Flutter 默认图标。

## 发布

普通 0.x 版本现在是正式 Release（只有 `-beta` / `-rc` 标为 Pre-release），仓库首页会显示 Latest Release；应用内更新只在当前版本带 `-` 后缀时才考虑预发布版本。

### 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.2-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.2-windows-x64.zip` | 免安装：解压后运行 `lekis.exe`，支持应用内在线更新 |
| macOS | `lekis-0.2.2-macos-universal.zip` | 未签名公证：首次打开请右键 → 打开，或执行 `xattr -dr com.apple.quarantine lekis.app` |
| Linux x64 | `lekis-0.2.2-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。可直接覆盖安装 0.1.0-alpha.2 及之后的版本。

---

## English

Lekis Music 0.2.2 preview release, adding macOS desktop and menu bar lyrics, the source-plugin playback contract, plugin library browsing/search, and pinyin ruby lyrics. It also fixes ranged remote reads and mini-player restoration. Starting with this version, regular 0.x builds are published as normal GitHub Releases.

**Highlights**

- **macOS desktop & menu bar lyrics**: separate toggles, per-word highlighting, dragging, locking, restored position and opacity; the menu bar shows the current line and returns to the player on click.
- **Source-plugin playback contract**: tracks keep a stable plugin/source ID, resolve a fresh stream URL before every play, and validate headers and target hosts so expired links in the queue still work.
- **Plugin library & search**: paged browsing, album catalogues, search and artwork from source plugins; online tracks import with stable IDs and share the artwork cache across lists, queue and player. Plugin storage and per-item permissions are confirmed at install time; Android native extensions need a separate grant.
- **Library, albums & lyrics editing**: all library categories reachable from the narrow-layout menu; server albums keep their identity and disc order with catalogue queries; the lyrics editor previews candidates, matches them and parses per-word timing.
- **Pinyin ruby lyrics**: Settings → Appearance → Lyrics → Ruby lyrics draws pinyin above classic lyrics, offline, with optional tone marks or tone numbers.

**Fixes**

- **Ranged remote audio**: GET-only signed URLs no longer fail when HEAD is rejected; premature connection closes retry once while preserving Range and authorization headers.
- **Mini player**: leaving mini mode restores the previous macOS fullscreen state, and controls stay reachable in narrow windows.
- **Plugin external programs**: no nested Tokio runtime; output over 8 MiB stops reading and terminates the child immediately.
- **macOS runtime linking**: the Swift concurrency `@rpath` now lives in the repository-root Cargo config, so test binaries and desktop lyrics find `libswift_Concurrency.dylib`.
- **macOS app icon**: replaced the default Flutter icon with the full rabbit brand AppIcon.

**Downloads:** Android arm64 APK, Windows x64 zip (portable, run `lekis.exe`), macOS Universal zip (unsigned: right-click → Open the first time), Linux x64 tar.gz. Checksums are in `SHA256SUMS.txt`. Installs over 0.1.0-alpha.2 and later.
