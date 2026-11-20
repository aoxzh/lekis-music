# 路线图

> 2026-11-19 制定。按"一个人 + 多个 AI agent"的人力排期，取代 PRD 第 8 章按 10 人团队估算的版本。产品愿景和需求范围不变，见 [REQUIREMENTS.md](REQUIREMENTS.md)。

## 0. 已定的决策

| 事项 | 决定 | 依据 |
|---|---|---|
| UI 技术 | Flutter，一套代码覆盖所有平台；Rust 核心不变 | [ADR-0006](adr/0006-flutter-ui.md) |
| 许可证和商业模式 | MPL-2.0 开源 + 可选付费 Pro（Pro 放在单独的私有仓库） | [ADR-0007](adr/0007-license-and-reuse-first.md) |
| 复用 | 复用优先，按许可证四档规则执行 | [ADR-0007](adr/0007-license-and-reuse-first.md)、[REUSE.md](REUSE.md) |
| 应用商店 | 上商店；商店版隐藏音源类插件分类，完整版走官网和 GitHub | REQUIREMENTS 第 5 节 |
| 平台顺序 | Alpha：Windows + Android；Beta：加 macOS、iOS、Linux | 本文件 |
| 比特完美 | 从 P1 提到 P0，是产品核心卖点 | REQUIREMENTS `PLY-05` |

## 1. 阶段闸门（最重要的规则）

**当前阶段的退出标准没达成之前，不做后面阶段的功能。**

这一条是为了避免之前的问题：核心做到了 1.0 阶段的功能（Plex、SFTP、NFS、插件宿主、NAS 节点），Alpha 阶段的无缝播放和界面却还没做。

- 已经提前做好的后面阶段的功能**保留，不删也不扩展**，到对应阶段再接 UI。
- 给 agent 派任务时，任务必须属于当前阶段，或者是修当前阶段要用到的 bug。
- 想插队做后面阶段的功能，先改这份文件，写清楚为什么。

## 2. 当前状态（2026-11-20）

**Phase 0 ✅ 已完成（三条退出标准全部实测通过）；Alpha 进行中。** 按用户要求，部分 Alpha 之后的功能已提前并行做完（见第 3 节各阶段表里的"已提前完成"）。逐项完成度、正在进行的工作、已知问题和下一步都只记在 [HANDOFF.md](HANDOFF.md)，这里不重复；各需求编号的实现状态见 [REQUIREMENTS 第 1.1 节](REQUIREMENTS.md)。

### 2.1 Phase 0 验证记录（2026-11-20）

性能基线见 [REQUIREMENTS 第 4.1 节](REQUIREMENTS.md)。

| 验收项 | 设备 / 条件 | 结果 | 判定 |
|---|---|---|---|
| 冷启动到首帧，10 万首库 | Samsung Fold5（SM-F946N，Android 16，主调试机），数据库放在应用内部存储，force-stop 后连续 7 次 | 中位数 **323 ms**，范围 279–364 ms | ✅ 目标 ≤ 1.2 s |
| 10 万行列表滚动 | Fold5 展开态，10 万行歌曲列表，连续快速滑动 | 126 帧 / 1041.4 ms，**120 fps**；p50 8.33 ms，p99 8.34 ms，**0 帧 > 16.7 ms** | ✅ 120 fps 不丢帧 |
| 10 万首库可交互 | 同一设备，首帧后首页显示 99999 首的专辑架 | 首帧 323 ms；1 s 内内容可见 | ✅ |
| Android 本地播放 + 进度 | Fold5，44.1 kHz / 立体声 WAV，AAudio 输出 | `dumpsys audio` 显示 AAudio `state:started`；播放位置推进到 18.8 s 后暂停，重启恢复到 32% | ✅ |
| Windows 冷启动 | Windows 桌面 release，进程启动到首个可见窗口；媒体会话移出首帧路径后 5 次 | 中位数 **714 ms**（689–743 ms） | ✅ 目标 ≤ 800 ms |
| Windows 播放 / 独占 | Windows 桌面 release，真实声卡 | 共享、独占、独占失败回退三条 smoke 均 `SMOKE_OK`；独占时实际模式 `exclusive`，播放位置正常推进 | ✅ |

测量口径：冷启动用 `adb shell am start -W` 的 `TotalTime`（首帧）；滚动用 `dumpsys SurfaceFlinger --latency` 的实际呈现时间戳计算帧间隔。之前记录的 3.2 s 是因为构建时数据库路径被 shell 改写、应用启动失败，已作废。性能库由 `lekis-library/examples/seed_fake_library.rs` 生成，只含元数据，不含封面图片。

## 3. 阶段计划

时间是按一个人加 agent 粗估的，以退出标准为准，不以日期为准。

### Phase 0：迁移准备和技术验证 ✅

已完成：按模块提交、`LICENSE`（MPL-2.0）+ `THIRD_PARTY_NOTICES.md`、Finamp 复用清单（[REUSE.md](REUSE.md)）、Flutter 工程 `app/`、flutter_rust_bridge 桥（落在新 crate `lekis-bridge`，旧的 `lekis-ffi` 和冻结的原生 UI `apps/` 已在 0.1.0-alpha.1 前删除）、`design/tokens.json` → `app/lib/src/theme/tokens.dart`、系统媒体控件选用 `souvlaki`（SMTC/MPRIS）+ `audio_service`（Android）。

**退出标准（2026-11-20 全部通过，数据见 2.1 节）：**

1. ✅ Windows 和 Android 上，Flutter 界面通过 Rust 核心播放本地歌曲，播放位置实时推进
2. ✅ 中端 Android 设备 10 万行列表快速滚动：120 fps，0 帧超过 16.7 ms
3. ✅ 冷启动：Android 10 万首库 323 ms（≤1.2 s）；Windows 桌面 714 ms（≤800 ms）

### Alpha：自己每天能用（约 2~3 个月，Windows + Android）

| 功能 | 需求编号 | 状态 |
|---|---|---|
| 资料库：专辑墙（带封面）、艺人、歌曲、文件夹、搜索（含拼音） | `LIB-*`、`UIX-*` | ✅ |
| 正在播放页：大封面、取色动态背景、逐行和逐字歌词 | `UIX-*` | ✅；歌词默认改为经典样式进行中 |
| 音源页：本地文件夹 + SMB + WebDAV，局域网自动发现 NAS | `SRC-01`~`SRC-03` | ✅ |
| 封面和歌词自动补全 + 待确认队列页 | `ENR-*` | ✅ |
| 无缝播放 | `PLY-01` | ✅ 合成测试；待无缝专辑实测 |
| Windows 比特完美（WASAPI 独占） | `PLY-05`（Windows 部分） | ✅ 实现；待逐位捕获 |
| 锁屏、通知、蓝牙按键、Windows SMTC | `PTF-*` | ✅ |
| ReplayGain、Scrobble 实测 | `PLY-03`、`DIS-07` | ✅ 设置和单元测试；待实测 |

**退出标准：**

1. 你自己连续两周只用它听歌，没有因为 bug 换回别的播放器
2. 无缝播放实测没有间隙（用专门的无缝测试专辑验证）
3. WASAPI 独占模式下，输出数据和源文件逐位一致
4. 10 万首歌的库，性能达到 REQUIREMENTS 第 4.1 节的指标

### Beta：小范围公测（约 3 个月）

| 功能 | 说明 |
|---|---|
| macOS、iOS、Linux | 同一套 Flutter 代码，补各平台的原生集成 |
| Android 比特完美（USB DAC 直出）、macOS 自动切换采样率 | `PLY-05` 其余部分 |
| 接上已做好的核心功能的 UI | Jellyfin、OpenSubsonic 源；多设备同步；统一资料库 |
| 离线缓存和下载 | `OFF-*`（下载已提前完成） |
| 桌面悬浮歌词 | `UIX-07`，每个桌面平台一个小的原生窗口 |
| 智能歌单 | `DIS-01`（已提前完成） |
| 商店版构建 | 隐藏音源分类，走一遍三个商店的审核 |

**退出标准：** 公开 Beta，崩溃率 < 1%，所有 P0 完成。

### 1.0：正式版（约 3 个月）

- 开放插件平台：SDK、脚手架 CLI、文档站、GitHub topic 插件索引、开发者模式
- 接上已做好的核心功能的 UI：Plex、SFTP、NFS 源；NAS 节点一键部署
- Chromecast / DLNA 投放、从其他播放器迁移
- 已提前完成：均衡器 + AutoEQ 风格耳机预设（真实 AutoEq 数据仍待接）、年度回顾、重复检测/库健康、标签编辑、本地插件管理、Windows 托盘
- 确定 Pro 版包含哪些功能

**退出标准：** 所有 P0 + 80% 的 P1 完成；兼容性矩阵全部通过；插件索引上线前过一遍法务评审。

### 1.x 以后

WASM 插件运行时、主题和歌词样式插件、CarPlay / Android Auto、电视端、端侧自动对轴歌词、局域网 P2P 同步。按用户反馈排优先级。

## 4. 还没定、但不阻塞当前阶段的问题

| 问题 | 默认做法 | 最晚什么时候定 |
|---|---|---|
| Pro 版包含哪些功能 | 先不做，1.0 前定 | 1.0 开始前 |
| 插件索引收不收音源类插件 | 自动收录，带免责声明，商店版隐藏 | 1.0 开始前 |
| 要不要做鸿蒙 NEXT、国内网盘 | 不做，1.x 再评估 | Beta 结束前 |
