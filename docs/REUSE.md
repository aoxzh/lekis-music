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

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 整体页面结构、播放器页、队列、下载管理 | Finamp | ✅ | 拷代码，保留 MPL 文件头，视觉按我们的 `design/tokens.json` 重做 |
| 调用 Rust 核心 | flutter_rust_bridge v2 | ✅ MIT | 见 ADR-0006 |
| 状态管理 | Riverpod | ✅ MIT | |
| 锁屏、通知、蓝牙按键（Android / iOS） | audio_service | ✅ MIT | 只用它的媒体会话部分，音频由 Rust 核心输出 |
| 桌面窗口控制、自定义标题栏 | window_manager | ✅ MIT | |
| Windows Mica / Acrylic 材质 | flutter_acrylic | ✅ MIT | |
| Windows SMTC、Linux MPRIS | 待选型 | — | Phase 0 里挑一个现成插件，没有合适的再写平台代码 |
| Apple Music 风格逐字歌词动效 | [AMLL](https://github.com/amll-dev/applemusic-like-lyrics) | 🔒 AGPL-3.0 | 只看它的效果和公开的 TTML 歌词格式说明，自己用 Flutter 实现 |
| 桌面端信息架构 | [Feishin](https://github.com/jeffvli/feishin) | 🔒 GPL-3.0 | 看它的布局和交互 |

### 2.2 播放引擎

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 解码 | Symphonia | ✅ MPL-2.0 | 已在用 |
| 输出设备 | cpal | ✅ Apache-2.0 | 已在用；WASAPI 独占需要自己补，cpal 目前只支持共享模式 |
| 重采样 | rubato | ✅ MIT | 已在用 |
| 响度 | ebur128 | ✅ MIT | 已在用 |
| 无缝播放的管线设计 | psst | ✅ MIT | 对照它的预加载和缓冲区设计 |
| 长尾格式（APE、DSD、WMA） | FFmpeg | 🟡 LGPL | 动态链接，可选组件 |
| 耳机 EQ 数据 | [AutoEq](https://github.com/jaakkopasanen/AutoEq) | ✅ MIT | 直接用它的数据 |

### 2.3 资料库、扫描、标签

| 需要 | 用什么 | 档位 | 备注 |
|---|---|---|---|
| 读写标签 | lofty | ✅ Apache-2.0 / MIT | 已在用 |
| 标签字段映射（多艺人、作曲、专辑艺人等） | MusicBrainz Picard 的公开映射文档 | 🔒 代码 GPL-2.0 | 按文档自己写映射表，不拷代码 |
| 扫描策略、多艺人拆分、OpenSubsonic 实现 | [Navidrome](https://github.com/navidrome/navidrome) | 🔒 GPL-3.0 | Go 写的，参考思路 |
| 拼音、简繁 | pinyin、zhconv | ✅ | 已在用 |

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
