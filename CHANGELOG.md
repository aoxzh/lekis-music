# 更新日志

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号用语义化版本；只记用户看得见的变化和影响发布的工程变更，内部重构和测试不列。逐项进度和验收情况见 [docs/HANDOFF.md](docs/HANDOFF.md)。

## [0.1.0-alpha.1] - 2026-11-20

第一个公开预览版，只有 Android APK 和 Windows 免安装 zip；macOS / iOS / Linux 留到 Beta。Flutter 客户端全面替换冻结的原生 UI，Android 和 Windows 上已经能走完日常听歌流程，但离 Alpha 退出标准还有差距。

### 新增

**播放**
- 样本级无缝播放（预解码下一首，去掉 MP3/AAC 的编码器延迟和填充）；20 ms 淡入淡出。
- Windows WASAPI 独占输出（比特完美）和共享输出，独占失败时自动回退。
- ReplayGain 响度均衡、10 段均衡器（含耳机预设）、睡眠定时（15/30/60/90 分钟）。
- 播放会话和队列持久化并恢复，播放历史按实际播放统计。
- Last.fm / ListenBrainz / Libre.fm 上报，离线先入队、联网后补报。
- 锁屏、通知、蓝牙按键和 Windows SMTC 媒体控件。

**资料库**
- 专辑、艺人、歌曲、流派、文件夹、喜欢六个维度；1–5 星评分；歌单和智能歌单规则。
- 拼音和简繁搜索；M3U / M3U8 与 XSPF 歌单导入导出；年度回顾（月度、时段聚合）。
- 重复检测和库健康检查；编辑标签并写回文件。
- 封面 / 歌词自动补全和待确认队列。

**音源**
- 本地文件夹、SMB、WebDAV；局域网 NAS 自动发现（mDNS / WS-Discovery / SSDP）和文件夹浏览。
- 音源多地址故障切换（`SRC-14`）：地址不可达时换备用地址。
- 凭据按引用保存（`SRC-15`）：Windows 用 DPAPI、Android 用 Keystore 加密，数据库里只有引用，界面层读不回明文。
- 离线下载单曲、歌单和合集，原子写入，启动时恢复未完成的下载。

**歌词**
- 逐行和逐字歌词（增强 LRC，卡拉 OK 式高亮）。
- 默认 Apple Music 式经典歌词；Flow / Steps / Tilt 歌词舞台可选。
- 手动编辑歌词，支持格式、时间偏移和版本。

**播客**
- 播客页（迁移 0011）：Apple Podcasts 目录搜索、榜单、RSS / Atom 订阅、OPML 导入导出、续播位置；网络电台（Radio Browser 目录 + 自定义流）入口并入播客页。

**插件**
- 本地插件管理：从文件夹或 zip 安装、启用、查看权限、改设置、删除。

**桌面与界面**
- Windows 托盘图标和关闭到托盘。
- 液态玻璃 / 扁平两种 TabBar 样式，展开状态竖向 Tab，浮动迷你播放器，封面墙，桌面播放条（歌词 / 队列 / 输出设备）。
- 设置页重构为「音乐 / 通用 / 更多」；诊断日志页（脱敏后可复制）；设置 JSON 导出 / 导入。

**性能**
- 10 万首库冷启动 323 ms（Fold5 中位数）；10 万行列表 120 fps、0 帧超过 16.7 ms；Windows 冷启动 714 ms（中位数，目标 800 ms）；分页列表改用精确计数的桥接调用，减少跨 FFI 往返。

**工程**
- 许可证改为 MPL-2.0，新增 `THIRD_PARTY_NOTICES.md`；GPL 的 `zhconv` 换成 `ferrous-opencc`。
- 删除冻结的原生 UI（`apps/`）、`lekis-ffi`、UniFFI 绑定脚本和对应 CI；FRB 生成代码统一在 `lekis-bridge`。
- Android 只编设备 ABI、dev 构建精简调试信息；新增 `v*` 标签触发的 release workflow（签名 APK + Windows zip）。

### 改进

- 正在播放页：从封面取色的自适应背景、封面切换动效，操作合并成单个工具栏。
- 列表和首页更紧凑，统一底部留白；设置页改成扁平行；空状态只留品牌标记。
- 歌词默认改成经典样式并降低舞台开销；迷你播放器和 TabBar 共用玻璃材质。

### 修复

- 离线下载启动恢复时不再误删刚写入的 `.part` 文件。
- 缺失的本地音源根目录会在界面上提示；离线相关事件同步到 Flutter 端。
- Android release 包不再对整个应用放开明文流量。
- 内置 256 px 吉祥物资源，修复图标偶尔渲染不出来的问题；桌面端选中专辑后才打开详情面板。

### 已知问题

- **Windows 崩溃（阻塞）**：数据库里有已保存的播放会话（`playback_state`）时，release 版启动约 3.8 s 后崩在 `flutter_windows.dll+0x3cf16`（`0xC0000005`），stderr 只有 Flutter accessibility bridge 的 `Failed to update ui::AXTree`；删掉那一行就不崩，空库也不崩。交互中也会偶发。
- 验收没做完：Windows 的均衡器只验了开关和预设列表，库健康、标签编辑、托盘、正在播放页截图都没做；最近合入的播客、设置页改版和桌面播放条也还没做完整真机复验。
- 在 "Lekis Stage Preview" 这首暂停时歌词面板空白（歌词改版后要复查）。
- 媒体服务器源（Jellyfin / Emby / Plex / OpenSubsonic）只有表单和核心客户端，Beta 前才完整验收。
- Android APK 在配置了 release keystore（`app/android/key.properties` 或 CI secrets）时用 release key 签名，否则退回 debug key；debug 签名的包不能发布，也不能覆盖升级。

### 升级说明

- 这是第一个公开预览版，没有更早的公开版本可升级。
- 数据库迁移在启动时自动执行（当前到 0011，含电台和播客两张表），不需要手动操作；迁移只增不改，已有的开发版数据目录可以直接沿用。
