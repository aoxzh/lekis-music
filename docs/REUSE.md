# 复用清单

> 规则见 [ADR-0007](adr/0007-license-and-reuse-first.md)：写新模块前先查这里。许可证是 2026-11-19 从 GitHub 查到的，引入前再确认一次。
>
> 档位：✅ 直接用（依赖或拷代码）· 🟡 有条件（LGPL，动态链接）· 🔒 只参考（GPL/AGPL，不拷代码）· ❌ 不碰（非商用、专有）

## 1. 最值得用的三个

| 项目 | 许可证 | 为什么重要 |
|---|---|---|
| **[Finamp](https://github.com/finamp-app/finamp)** | ✅ MPL-2.0 | Flutter 写的 Jellyfin 音乐客户端，约 4.6k★，还在活跃维护。技术栈和我们的 UI 层完全一样，许可证也一样。正在播放页、队列、离线下载、歌词显示、Jellyfin API 模型都可以**直接拷代码再改**，是 Flutter 迁移最大的加速器 |
| **[beets](https://github.com/beetbox/beets)** | ✅ MIT | Python 写的音乐库管理工具，它的自动打标（autotagger）是这个领域最成熟的匹配算法：专辑级匹配、距离函数、各字段权重。`lekis-enrich` 的候选打分可以照着它移植 |
| **[psst](https://github.com/jpochyla/psst)** | ✅ MIT | Rust 写的 Spotify 客户端。它的音频管线（解码线程、环形缓冲区、预加载下一首）可以拿来对照，做无缝播放时参考 |

## 2. 按模块

### 2.1 UI 层（Flutter）

#### Finamp 文件级复用清单（2026-11-20 实际读过）

Finamp 是 MPL-2.0。下列文件的结构/交互可以直接参考；复制时保留 MPL 文件头并登记到 `THIRD_PARTY_NOTICES.md`。只复用 Flutter UI 结构，不复用 Jellyfin 数据模型。

| Finamp 文件 | 用途 | 我们对应位置 |
|---|---|---|
| `lib/components/now_playing_bar.dart` | 迷你播放器布局、进度、封面 | `app/lib/src/features/player/mini_player.dart` |
| `lib/components/audio_fade_progress_visualizer_container.dart` | 播放/淡入淡出进度可视化 | `app/lib/src/features/player/player_bar.dart` |
| `lib/screens/player_screen.dart` | 正在播放页结构 | `app/lib/src/features/now_playing/now_playing_page.dart` |
| `lib/screens/player_settings_screen.dart` | 播放设置分组 | `app/lib/src/features/settings/settings_page.dart` |
| `lib/screens/lyrics_screen.dart` / `lyrics_settings_screen.dart` | 歌词页和歌词设置 | `app/lib/src/features/now_playing/lyrics_view.dart` |
| `lib/components/AddToPlaylistScreen/*` | 加入歌单弹层、新建歌单 | `app/lib/src/features/playlists/add_to_playlist_sheet.dart` |
| `lib/screens/playlist_edit_screen.dart` | 歌单编辑/排序 | `app/lib/src/features/playlists/playlist_detail_page.dart` |
| `lib/screens/queue_restore_screen.dart` | 启动时恢复队列 | `app/lib/src/features/player/playback_session.dart` |
| `lib/screens/active_downloads_screen.dart` / `downloads_*` | 下载队列、错误、下载位置 | `app/lib/src/features/downloads/` |
| `lib/services/downloads_service.dart` / `downloads_service_backend.dart` | 下载状态机、缓存文件 | 下载逻辑在 Rust 核心（`lekis-core` 离线下载 + 原子 `.part` 缓存） |
| `lib/services/audio_service_helper.dart` / `audio_service_smtc.dart` | audio_service / SMTC 集成 | `app/lib/src/platform/android_media_session.dart`、`core/crates/lekis-bridge/src/media_controls.rs` |
| `lib/components/album_image.dart` / `blurred_image.dart` | 封面占位、模糊背景 | `app/lib/src/features/library/widgets/artwork.dart`、`now_playing_background.dart` |
| `lib/components/global_snackbar.dart` / `confirmation_prompt_dialog.dart` | 统一提示/确认对话框 | 需要补一个共享组件 |

主表：

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 整体页面结构、播放器页、队列、下载管理 | Finamp | ✅ | 拷代码，保留 MPL 文件头，视觉按我们的 `design/tokens.json` 重做 |
| 调用 Rust 核心 | flutter_rust_bridge v2 | ✅ MIT | 见 ADR-0006 |
| 状态管理 | Riverpod | ✅ MIT | |
| 锁屏、通知、蓝牙按键（Android / iOS） | audio_service | ✅ MIT | 只用它的媒体会话部分，音频由 Rust 核心输出 |
| 桌面窗口控制、托盘 | window_manager、tray_manager | ✅ MIT | 已在用（Windows 托盘、关闭到托盘） |
| Windows Mica / Acrylic 材质 | flutter_acrylic | ✅ MIT | |
| Windows SMTC、Linux MPRIS、macOS Now Playing | souvlaki | ✅ MIT | 已在用，放在 Rust 侧（`lekis-bridge/src/media_controls.rs`） |
| Apple Music 风格逐字歌词动效 | [AMLL](https://github.com/amll-dev/applemusic-like-lyrics) | 🔒 AGPL-3.0 | 只看它的效果和公开的 TTML 歌词格式说明，自己用 Flutter 实现 |
| 歌词舞台（Flow / Steps / Tilt）、桌面产品形态 | [mygo-music](https://github.com/egoist/mygo-music) | 🔒 AGPL-3.0 | 只借鉴交互，独立实现 |
| 桌面端信息架构 | [Feishin](https://github.com/jeffvli/feishin) | 🔒 GPL-3.0 | 看它的布局和交互 |

### 2.2 播放引擎

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 解码 | Symphonia | ✅ MPL-2.0 | 已在用 |
| 输出设备 | cpal、wasapi | ✅ Apache-2.0 / MIT | 已在用；cpal 只支持共享模式，WASAPI 独占用 `wasapi` crate 自己接 |
| 重采样 | rubato | ✅ MIT | 已在用 |
| 响度 | ebur128 | ✅ MIT | 已在用 |
| 无缝播放的管线设计 | psst | ✅ MIT | 对照它的预加载和缓冲区设计 |
| 长尾格式（APE、DSD、WMA） | FFmpeg | 🟡 LGPL | 动态链接，可选组件 |
| 耳机 EQ 数据 | [AutoEq](https://github.com/jaakkopasanen/AutoEq) | ✅ MIT | 均衡器现在内置的是"AutoEQ 风格"的近似曲线，不是 AutoEq 数据；要用真实测量数据时从这里取 |

### 2.3 资料库、扫描、标签

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 读写标签 | lofty | ✅ Apache-2.0 / MIT | 已在用 |
| 标签字段映射（多艺人、作曲、专辑艺人等） | MusicBrainz Picard 的公开映射文档 | 🔒 代码 GPL-2.0 | 按文档自己写映射表，不拷代码 |
| 扫描策略、多艺人拆分、OpenSubsonic 实现 | [Navidrome](https://github.com/navidrome/navidrome) | 🔒 GPL-3.0 | Go 写的，参考思路 |
| 拼音、简繁 | pinyin、ferrous-opencc | ✅ MIT / Apache-2.0 | 已在用；`zhconv` 是 GPL，已换掉 |

### 2.4 元数据补全

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 候选匹配和打分 | beets 的 autotagger | ✅ MIT | 移植算法 |
| 歌词 | [LRCLIB](https://github.com/tranxuanthang/lrclib) API | ✅ MIT | 已在用，遵守它的使用条款 |
| 封面 | Cover Art Archive、iTunes Search API | 服务条款 | 已在用 |
| 音频指纹 → AcoustID | [rusty-chromaprint](https://github.com/darksv/rusty-chromaprint) | ✅ MIT | 纯 Rust，不用链接 C 版 Chromaprint |
| 声学分析（相似歌曲电台） | bliss-rs | 🔒 GPL-3.0 | 不能链接进核心；要么自己实现特征提取，要么评估做成用户单独安装的可选组件 |

### 2.5 音源接入

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| SMB | smb2 crate | ✅（引入前再核实） | 已在用，纯 Rust |
| SMB 备选 | libsmb2 | 🟡 LGPL-2.1 | 纯 Rust 方案不稳定时的后备 |
| Jellyfin API 模型 | Finamp 里的 Dart 模型 | ✅ MPL-2.0 | 核心里已有 Rust 实现；UI 侧如果需要可以参考 |
| Jellyfin、Plex、OpenSubsonic 协议 | 各自公开的 API 文档 | 规范 | 协议本身不受代码许可证限制 |

### 2.6 插件平台

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| JS 运行时 | rquickjs | ✅ MIT | 已在用 |
| 插件格式和分发方式 | [mygo-music](https://github.com/egoist/mygo-music) | 🔒 AGPL-3.0 | 只借鉴设计（`plugin.json`、按能力导出函数、GitHub topic 收录） |
| 插件生态 | MusicFree | ❌ AGPL + 非商用条款 | 只看公开的产品形态 |

## 3. 不要碰的

| 项目 | 原因 |
|---|---|
| [Musly](https://github.com/dddevid/Musly)（Flutter Subsonic 客户端） | CC BY-NC-SA 4.0，非商用 |
| [Harmonoid](https://github.com/harmonoid/harmonoid)（Flutter 本地播放器） | PolyForm Strict，不允许修改和再分发 |
| [Namida](https://github.com/namidaco/namida)（Flutter 本地播放器） | 专有 EULA |
| [Spotube](https://github.com/team-spotube/spotube) | AGPL-3.0，而且接的是流媒体音源，法律风险高 |
| MusicFree | AGPL-3.0 + 非商用附加条款 |

这些项目的**产品形态**（截图、功能列表、用户评价）仍然可以研究。

## 4. 维护这份清单

- 新引入一个依赖或拷了一段外部代码，在这里加一行，同时登记到 `THIRD_PARTY_NOTICES.md`。
- 发现更好的现成方案，直接改这份文件，不需要 ADR。引入核心层的新依赖仍然要按 CONTRIBUTING 第 5 节写 ADR。
