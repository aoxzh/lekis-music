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

## 2. 当前状态（2026-11-19）

| 部分 | 状态 |
|---|---|
| Rust 核心 | 3.7 万行，446 个测试；扫描、资料库、搜索、播放、重采样、SMB/WebDAV/NFS/SFTP、Jellyfin/Plex/OpenSubsonic、封面歌词补全、同步、插件运行时都已实现 |
| 无缝播放 `PLY-01` | ❌ 没做（`lekis-playback/src/engine.rs` 里的 TODO） |
| 比特完美 `PLY-05` | ❌ 没做（`cpal_output.rs` 里 `supports_exclusive` 写死为 false） |
| UI | 三套原生 UI 都是骨架，已冻结，迁移到 Flutter |
| 版本控制 | ⚠️ 这一轮的 105 项改动还没提交，进入 Phase 0 前先提交 |

**当前阶段：Phase 0。**

## 3. 阶段计划

时间是按一个人加 agent 粗估的，以退出标准为准，不以日期为准。

### Phase 0：迁移准备和技术验证（约 2~3 周）

| 任务 | 说明 |
|---|---|
| 提交现有改动 | 按模块拆成几个提交 |
| 许可证落地 | 根目录 `LICENSE`（MPL-2.0）、`THIRD_PARTY_NOTICES.md`、源文件 MPL 文件头 |
| 读 Finamp 代码 | 列出能直接拷的文件（播放器页、队列、下载、歌词组件），写进 REUSE.md |
| 创建 Flutter 工程 `app/` | Windows + Android 两个目标 |
| `lekis-ffi` 改用 flutter_rust_bridge | 先导出最小集合：列专辑、播放、暂停、事件流 |
| 设计 Token → Dart 主题 | 从 `design/tokens.json` 生成 |
| 选定 SMTC / MPRIS 方案 | 挑现成插件，没有合适的再写平台代码 |

**退出标准：**

1. Windows 和 Android 上，Flutter 界面通过 Rust 核心播放一首本地歌曲，进度条实时更新
2. 中端 Android 手机上，10 万行列表快速滚动不掉帧
3. 冷启动达到 REQUIREMENTS 第 4.1 节的指标

任何一条不达标，回到 ADR-0006 重新评估。

### Alpha：自己每天能用（约 2~3 个月，Windows + Android）

| 功能 | 需求编号 |
|---|---|
| 资料库：专辑墙（带封面）、艺人、歌曲、文件夹、搜索（含拼音） | `LIB-*`、`UIX-*` |
| 正在播放页：大封面、取色动态背景、逐行和逐字歌词 | `UIX-*` |
| 音源页：本地文件夹 + SMB + WebDAV，局域网自动发现 NAS | `SRC-01`~`SRC-03` |
| 封面和歌词自动补全 + 待确认队列页 | `ENR-*` |
| 无缝播放 | `PLY-01` |
| Windows 比特完美（WASAPI 独占） | `PLY-05`（Windows 部分） |
| 锁屏、通知、蓝牙按键、Windows SMTC | `PTF-*` |
| ReplayGain、Scrobble 实测 | 代码已有，补验证 |

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
| 离线缓存和下载 | `OFF-*` |
| 桌面悬浮歌词 | `UIX-07`，每个桌面平台一个小的原生窗口 |
| 智能歌单 | |
| 商店版构建 | 隐藏音源分类，走一遍三个商店的审核 |

**退出标准：** 公开 Beta，崩溃率 < 1%，所有 P0 完成。

### 1.0：正式版（约 3 个月）

- 开放插件平台：SDK、脚手架 CLI、文档站、GitHub topic 插件索引、开发者模式
- 接上已做好的核心功能的 UI：Plex、SFTP、NFS 源；NAS 节点一键部署
- 均衡器 + AutoEq、Chromecast / DLNA 投放、年度回顾、从其他播放器迁移
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
