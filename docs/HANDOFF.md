# 交接（2026-11-20，准备 0.1.0-alpha.1）

给接手的人或 agent：读完这一页就能接着干。阶段规则见 [ROADMAP.md](ROADMAP.md)，需求编号和实现状态见 [REQUIREMENTS.md](REQUIREMENTS.md)，视觉方向见 [DESIGN.md](DESIGN.md)，代码约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 1. 现在在哪

- 分支：`phase-0`（还没合回 `main`）。
- 阶段：**Phase 0 已完成，Alpha 进行中。** 退出标准见第 3 节。
- 第一个公开预览版 `0.1.0-alpha.1`（Android APK + Windows zip）：打 `v0.1.0-alpha.1` 标签后由 `.github/workflows/release.yml` 构建并发 pre-release，变更见 [CHANGELOG.md](../CHANGELOG.md)，发布说明草稿见 [release-notes-0.1.0-alpha.1.md](release-notes-0.1.0-alpha.1.md)。
- 冻结的原生 UI（`apps/`）、`lekis-ffi`、UniFFI 绑定脚本和对应 CI 已删除，代码在 git 历史里。
- `logs/`（已在 `.gitignore`）是本机的验收截图和运行日志，不提交。

## 2. 完成度

### 已合入

| 模块 | 内容 | 真机验证 |
|---|---|---|
| 性能 | 10 万首库冷启动 323 ms（Fold5）；滚动 120 fps 0 掉帧；Windows 冷启动 714–746 ms | ✅ |
| 播放 | 样本级无缝、WASAPI 独占/共享/回退、20 ms 淡入淡出、ReplayGain、会话恢复、睡眠定时、Scrobble、10 段均衡器 + AutoEQ 风格耳机预设 | ✅ Fold5（含均衡器）；Windows 均衡器只验了一部分（见第 4 节） |
| 资料库 | 专辑/艺人/歌曲/流派/文件夹/喜欢、1–5 星、歌单 + 智能歌单、M3U/XSPF 导入导出、播放历史、年度回顾、重复检测/库健康、标签编辑并写回 | ✅ Fold5（库健康、标签编辑已走一遍） |
| 音源 | 本地、SMB、WebDAV、Jellyfin/Emby/Plex/OpenSubsonic 表单、局域网 NAS 发现、凭据存储（Android Keystore）、离线下载（单曲/歌单/合集） | ✅ NAS 发现；下载和凭据待复验 |
| 歌词 | 逐行/逐字、Flow/Steps/Tilt 舞台、手动编辑/偏移/版本 | ✅ |
| 补全 | 封面/歌词自动补全 + 待确认页 | ✅ |
| 插件 | 本地插件管理（安装/启用/权限/设置/删除） | ✅ |
| 桌面 | SMTC 媒体控件、Windows 托盘 + 关闭到托盘 | 托盘未验 |
| UI | 液态玻璃/扁平 TabBar、展开态竖向 Tab、浮动迷你播放器、封面墙、桌面队列面板、扁平设置页、诊断日志页、设置导出/导入 | ✅ Fold5 + Windows |
| 工程 | FRB 生成代码在 `lekis-bridge` crate；dev 构建精简调试信息；只编设备 ABI（`tools/dev-android.ps1`）；Android 不再全局放开明文流量 | ✅ |

均衡器、库健康、标签编辑、托盘、电台按路线图本属 Alpha 之后，是提前做的。按阶段闸门：保留、修 bug，Alpha 退出前不再扩展（下面"正在进行"里用户明确要求的改动除外）。

### 最近合入、还没在真机上完整复验

| 工作 | 说明 |
|---|---|
| 歌词默认样式改为经典 | 默认用 Apple Music 式经典歌词（`lyrics_classic.dart`），Flow/Steps/Tilt 舞台改为可选 |
| 设置信息架构 | 分成"音乐 / 通用 / 更多"，进阶选项收进"高级"；手机推页、桌面列表 + 详情 |
| 播客 | 播客页（Apple 目录搜索、榜单、RSS、OPML）替换电台 Tab；网络电台从播客菜单进入 |
| 桌面播放条 | 右侧歌词 / 队列 / 输出设备，侧边面板默认收起 |
| `SRC-14` 网络感知选路 | NAS 不可达时切到备用地址（文件源和媒体服务器源都支持） |

### 核心做好、UI 还没接（按阶段闸门冻结）

| 功能 | 计划接入阶段 |
|---|---|
| NFS、SFTP 音源 | 1.0 |
| 多设备同步 `SYN-*`（核心有操作日志） | Beta |
| NAS headless 节点 `lekis-node` | 1.0 |
| Android USB DAC 直出、macOS 自动切换采样率 | Beta |
| 桌面悬浮歌词 `UIX-07`（P0，还没开始） | Beta |

## 3. Alpha 退出标准

| 标准 | 状态 |
|---|---|
| 连续两周只用它听歌，没有因为 bug 换播放器 | ⏳ 还没开始计时 |
| 无缝播放用专门的无缝测试专辑实测无间隙 | ⏳ 只用合成 WAV 测过 |
| WASAPI 独占下输出和源文件逐位一致 | ⏳ 缺逐位捕获证据 |
| 10 万首库性能达标 | ✅ |

## 4. 已知问题

- **Windows 启动崩溃（阻塞）**：数据库里有已保存的播放会话（`playback_state`）时，Windows release 启动约 3.8 s 后崩在 `flutter_windows.dll+0x3cf16`（`0xC0000005`），stderr 只有 Flutter accessibility bridge 的 `Failed to update ui::AXTree`；删掉 `playback_state` 那一行就不崩，空库也不崩。交互中也偶发。
- Windows 验收没做完：均衡器只验了开关和预设列表；库健康、标签编辑、托盘、正在播放页截图都没做。
- 在 "Lekis Stage Preview" 这首暂停时歌词面板空白（歌词改版可能顺带解决，改完要复查）。

## 5. 下一步（按顺序）

1. **修 Windows 会话恢复崩溃**，再把 Windows 验收补完（均衡器预设/频段持久化、库健康、标签编辑、托盘、正在播放页截图）。
2. 把第 2 节"最近合入"的几项在 Android + Windows 各过一遍。
3. **Alpha 硬指标**：无缝测试专辑实听 + 帧级检查；WASAPI 独占逐位捕获对比源文件。
4. **开始两周日用**：从这一步起只修 bug，不加功能。
5. Alpha 退出后：`phase-0` 合回 `main`，进入 Beta（macOS/iOS/Linux、同步 UI、桌面悬浮歌词、商店版）。

## 6. 工作约定

- `tools/dev-android.ps1` 默认在 `%USERPROFILE%\dev` 下找工具链（Flutter、Rust、JDK 17、Android SDK/NDK），`LEKIS_DEV_ROOT` 可覆盖。
- Android 日常联调用 `tools/dev-android.ps1`，只编当前设备 ABI；别动不动 `cargo clean`。
- 折叠屏（如 Fold5）的内屏截图要 `screencap -d <内屏 display id>`。
- Windows 免安装包用 `tools/package-windows.ps1`（输出到不提交的 `dist/`）。
- 截某个页面可用 `--dart-define=LEKIS_START_TAB=library|search|sources|settings`；换数据目录用 `--dart-define=LEKIS_DATA_DIR=<目录>`。
- 提交前有隐私钩子：不能出现个人路径、邮箱等。
