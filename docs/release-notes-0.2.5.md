月兔音乐（Lekis Music）0.2.5 预览版，修复「补全缺失封面 / 歌词」每次只处理 50 首的问题，并把补全结果写回音源目录。有问题欢迎[提 issue](https://github.com/aoxzh/lekis-music/issues)。

## 新增

- **补全结果写入音源目录**：补全或接受候选后，封面写成专辑目录的 `cover.jpg`（单曲用 `<歌曲名>.jpg`），歌词写成与音频同名的 `.lrc`（TTML / 纯文本同理）。重新添加资料库或扫描时直接读取侧车文件，不用再补一遍。仅处理可写的文件系统音源（本地 / SMB / WebDAV / SFTP / NFS）；只读共享和媒体服务器自动跳过。设置 → 整理资料库 新增开关，默认开启。
- **官网吉祥物**：官网首页、下载、FAQ 和「为什么叫 Lekis」用上了新的月兔角色插画；站内使用裁剪压缩版，原始素材留在 `website/kit`。

## 修复

- **补全不再只处理 50 首**：旧逻辑写死了 `batchLimit = 50`，只读健康报告第一页就停。现在按 200 条一页读取，收集整个资料库的缺失曲目后一次任务补完；进度条显示总数，随时可以取消。
- **源头限流**：核心为每个来源单独限速（LRCLIB / Cover Art Archive 各约 1 次/秒、iTunes 约 20 次/分钟等），429 / 503 会按 Retry-After 和指数退避处理；UI 再每 50 首停 2 秒，遇到 `rateLimited` 额外停 10 秒。
- 仅补全封面时仍按专辑去重，同一张缺封面的专辑只查一首代表曲目，避免重复请求和重复候选。
- 包含 0.2.4 的资料库窄屏分类条、移动端音源选择面板、专辑/艺人统一分栏，以及 0.2.3 的 Windows 在线更新修复和 Android v1 / v2 / v3 签名。

## 下载

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（arm64） | `lekis-0.2.5-android-arm64.apk` | 64 位 ARM 手机 / 平板 |
| Windows x64 | `lekis-0.2.5-windows-x64-setup.exe` | 每用户安装器，支持在线更新 |
| Windows x64 | `lekis-0.2.5-windows-x64.zip` | 免安装：解压后运行 `lekis.exe` |
| macOS（Apple Silicon） | `lekis-0.2.5-macos-arm64.dmg` | 打开后拖入 Applications |
| macOS（Apple Silicon） | `lekis-0.2.5-macos-arm64.zip` | 应用内更新载荷，也可手动解压 |
| Linux x64 | `lekis-0.2.5-linux-x64.AppImage` | 单文件，`chmod +x` 后直接运行 |
| Linux x64 | `lekis-0.2.5-linux-x64.tar.gz` | 解压后运行目录里的 `lekis` |

`SHA256SUMS.txt` 包含所有文件的 SHA-256 校验和。

---

## English

Lekis Music 0.2.5 preview release, fixing "Fetch Missing Covers / Lyrics" stopping after 50 tracks and persisting enrichment results next to the source files.

**Added**

- **Enrichment is saved into source folders**: covers become `cover.jpg` in the album folder (or `<track>.jpg` for a single track), and lyrics become a matching `.lrc` (TTML / plain text likewise). Re-adding or rescanning the library picks them up, so nothing has to be fetched again. Only writable filesystem sources (local / SMB / WebDAV / SFTP / NFS) are touched; read-only shares and media servers are skipped. A new toggle under Settings → Library Tools is on by default.
- **Website mascot art**: the home, download, FAQ and "Why Lekis" sections now use the new rabbit character illustrations; the site serves cropped, compressed derivatives and keeps the originals in `website/kit`.

**Fixes**

- **The whole library is processed now**: the old code hard-coded `batchLimit = 50` and read only the first health-report page. It now pages through the health report (200 rows per page), collects every missing track, and runs one enrichment job with a total progress bar and cancel support.
- **Source rate limits**: the core already throttles each provider (LRCLIB / Cover Art Archive ~1 request/s, iTunes ~20/min) and retries 429 / 503 with Retry-After and exponential backoff; the UI additionally pauses 2 seconds every 50 tracks and 10 seconds on `rateLimited`, so one run cannot drain the quota.
- Artwork-only runs still deduplicate by album: one representative track per album is enough because applying the cover updates the album.
- Includes the 0.2.4 library navigation improvements (compact category strip, mobile source picker, unified album/artist split view) and the 0.2.3 Windows updater fix plus Android v1/v2/v3 signing.

**Downloads:** Android arm64 APK; Windows x64 installer or portable ZIP; macOS arm64 DMG or ZIP; Linux x64 AppImage or tar.gz. Checksums are in `SHA256SUMS.txt`.
