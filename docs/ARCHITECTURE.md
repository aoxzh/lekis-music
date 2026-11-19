# 架构说明

> 这份文档是**约束**，不是建议。违反下面任何一条规则的 PR 都不应该被合入；如果你认为某条规则不合理，先写 ADR。

## 1. 总体分层

```
┌──────────────── Flutter UI（一套代码：Windows / Android，Beta 起加 macOS / iOS / Linux）────────────────┐
│ 页面 + Riverpod 状态（只负责显示和交互）                                                                 │
│ 薄原生层：audio_service（锁屏/通知）· SMTC · MPRIS · 桌面悬浮歌词窗口 · CarPlay / Android Auto / 小组件   │
└──────────────────────────────────────────────┬───────────────────────────────────────────────────────────┘
                                               │ flutter_rust_bridge（Future / Stream）
┌──────────────────────────────────────────────▼─────────────────────────────────────────┐
│ lekis-ffi：把 lekis-core 的门面翻译成 FFI 友好的类型（Record / Enum / Object / 回调） │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ lekis-core：门面 + 服务组装 + 事件总线 + tokio 运行时（对外的唯一入口）                │
├──────────┬──────────┬──────────┬──────────┬──────────┬──────────┬──────────────────────┤
│ scanner  │ library  │ playback │ enrich   │ providers│ sync     │ plugin-host          │
├──────────┴──────────┴──────────┴──────────┴──────────┴──────────┴──────────────────────┤
│ lekis-vfs：本地 / SMB / WebDAV / NFS / SFTP 的统一读取接口                              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ lekis-types：领域模型、ID、错误、事件（纯数据，不做 IO）                                │
└────────────────────────────────────────────────────────────────────────────────────────┘

lekis-node（可选 NAS 节点）= lekis-core + axum HTTP 服务
```

以后新增的 `lekis-analysis`（声学分析）、`lekis-cast`（投放）也放在领域层。

## 2. 依赖规则

1. **依赖方向只能自上而下。** 下层 crate 不能依赖上层 crate。
2. **`lekis-types` 不依赖任何 IO 库**（不能有 tokio、rusqlite、reqwest），只允许 serde、thiserror、uuid、time 这类纯数据库。
3. **领域 crate 之间不能互相依赖**，只能依赖 `lekis-types` 和 `lekis-vfs`。已批准的例外：
   - `lekis-scanner` → `lekis-library`（写入扫描结果）
   - `lekis-enrich` → `lekis-library`（写入覆盖层和候选）
   - `lekis-sync` → `lekis-library`（物化用户状态）

   其他任何跨领域调用都必须在 `lekis-core` 里组装。新增例外需要 ADR。
4. **只有 `lekis-ffi` 能出现 FFI 框架的代码**（flutter_rust_bridge，见 [ADR-0006](adr/0006-flutter-ui.md)）。领域 crate 不能为了 FFI 去改自己的类型。
5. **平台 UI 不能有业务逻辑。** "该不该播"、"该选哪个源"、"这首歌的封面是哪张"这类判断，一律放在核心里。UI 只能：调用核心的方法、订阅核心的事件、渲染界面、对接系统 API（媒体控制、通知、文件选择器等）。
6. **平台特有的能力通过回调接口反向注入**（例如凭据存储、网络状态、音频焦点）：在 `lekis-core` 里定义 trait（见 `platform.rs`），在 `lekis-ffi` 里导出对应的接口，由 Dart 侧实现。

## 3. 线程与并发模型

| 线程 / 执行器 | 谁拥有 | 用途 | 规则 |
|---|---|---|---|
| tokio 多线程运行时 | `lekis-core` | 网络、文件 IO、扫描、刮削、同步 | 核心内部只有这一个运行时；**FFI 调用方不需要也不应该知道它的存在** |
| 数据库写线程 | `lekis-library` | 所有写操作串行执行 | 一个专用线程 + 命令队列；批量提交（每 500 条一个事务）|
| 数据库读连接池 | `lekis-library` | 查询 | WAL 模式，多个只读连接 |
| 音频实时线程 | `lekis-playback`（由输出后端创建）| 把样本送给声卡 | **禁止**：内存分配、加锁、IO、日志、调用 tokio。只能从无锁环形缓冲区读数据 |
| 解码线程 | `lekis-playback` | 解码 + DSP，写入环形缓冲区 | 每个"解码槽位"一个线程（当前曲目 + 预加载的下一首）|
| 后台低优先级任务 | `lekis-core` 调度 | 缩略图、ReplayGain、声学分析 | 有全局并发上限；移动端只在充电 + 空闲时运行 |
| 平台 UI 线程 | 平台 | 渲染 | **不能调用阻塞的核心方法**。核心的 FFI 方法要么是 async，要么保证 1ms 内返回 |

## 4. 核心与 UI 的通信

- **命令**：UI 调用 `LekisCore` 对象上的方法（`play_tracks`、`start_scan`、`search`……）。耗时操作都是 async（flutter_rust_bridge 生成 Dart `Future`）。
- **事件**：核心通过事件流（Dart 侧是 `Stream`）把事件推给 UI（播放状态、扫描进度、资料库变化、待确认队列变化、同步状态……）。UI 在 Riverpod Provider 里把事件转成界面状态；高频事件（播放进度）要节流。
- **大列表**：分页（`offset + limit`）；**绝不一次性返回 10 万条数据**。列表页只拿精简的 `TrackRow`，详情页再取完整信息。
- **图片**：核心只返回本地缓存文件路径（缩略图已经按尺寸生成好），UI 用 Flutter 的图片组件加载。不通过 FFI 传图片字节。
- **错误**：核心对外只抛 `CoreError`，每个错误都带一个稳定的 `code`，UI 根据 `code` 显示本地化的提示文字，不直接显示 `message`。

## 5. 数据与存储

| 数据 | 位置 | 说明 |
|---|---|---|
| 主数据库 `library.sqlite` | 本机应用数据目录 | **绝对不能放在网络共享上**（[ADR-0004](adr/0004-sqlite-never-on-network-share.md)）|
| 缩略图缓存 | 本机缓存目录 `artwork/<哈希前 2 位>/<哈希>_<尺寸>.webp` | 可以随时删除重建 |
| 播放缓存 | 本机缓存目录 `audio-cache/` | LRU |
| 离线下载 | 本机数据目录 `offline/` | 放在数据目录，避免被系统自动清理 |
| 凭据 | 系统钥匙串 | 通过 `CredentialStore` 回调存取；数据库里只存引用 ID |
| NAS 共享索引 | `<共享根目录>/.lekis/index/` | 按目录分片的 `cbor + zstd` 文件 |
| 同步日志 | `<共享根目录>/.lekis/sync/<device_id>/` | 每台设备只写自己的目录 |
| 插件 | 本机数据目录 `plugins/<plugin_id>/` | |

数据库表结构的唯一来源是 [`core/crates/lekis-library/migrations/`](../core/crates/lekis-library/migrations/)。**迁移文件只增不改。**

## 6. 各 crate 职责

| Crate | 负责 | 不负责 |
|---|---|---|
| `lekis-types` | 领域模型、强类型 ID、错误、事件 | 任何 IO |
| `lekis-vfs` | 目录遍历、`stat`、按范围读取、（可选）写入 `.lekis/` | 理解音频文件 |
| `lekis-library` | 表结构、迁移、增删改查、全文搜索（含拼音、简繁）、智能歌单求值 | 扫描文件、联网 |
| `lekis-scanner` | 遍历 → 部分读取 → 解析标签 → 写库；增量扫描；NAS 共享索引 | 补全封面歌词 |
| `lekis-providers` | 媒体服务器 API（OpenSubsonic、Jellyfin、Plex、Emby）| 本地文件 |
| `lekis-enrich` | 封面/歌词/标签的提供方、指纹识别、候选打分、待确认队列 | 写回原始文件（用户确认后由 core 调用 scanner 的写标签功能）|
| `lekis-playback` | 队列、解码、DSP、无缝播放、淡入淡出、输出设备 | 决定播放哪个源（core 解析好之后交给它）|
| `lekis-sync` | 混合逻辑时钟、操作日志、合并、同步通道 | 业务含义（它只认识"实体 + 字段 + 值"）|
| `lekis-plugin-host` | 清单解析、权限检查、运行时（JS / WASM）、调用超时 | 把插件结果合并进资料库（由 core 做）|
| `lekis-core` | 组装服务、配置、事件总线、选源、离线策略、对外门面 | 平台 API |
| `lekis-ffi` | flutter_rust_bridge 导出、类型转换、事件流 | 任何业务逻辑 |

## 7. UI 的结构约定

Flutter 端按功能模块组织（`app/lib/features/<名字>/`），每个模块是"页面 + Provider"：

| 模块 | 内容 |
|---|---|
| home | 首页：继续播放、最近添加、混音推荐 |
| library | 资料库：歌曲 / 专辑 / 艺人 / 歌单 / 文件夹 |
| search | 搜索 |
| nowplaying | 正在播放 + 歌词 |
| sources | 添加和管理音源（NAS 自动发现、服务器登录）|
| enrich | 补全结果待确认队列 |
| settings | 设置 |

Provider 只调用桥接层 `CoreBridge`（`app/lib/bridge/`），**不直接调用生成的绑定代码**，这样绑定代码重新生成时只需要改桥接层。

旧的原生 UI（`apps/android`、`apps/windows`、`apps/linux`）已冻结，见 ADR-0006。

设计 Token（颜色、圆角、间距、字号、动效参数）的唯一来源是 [`design/tokens.json`](../design/tokens.json)。

## 8. 构建产物

| 平台 | 核心产物 | 打包 |
|---|---|---|
| Windows | `lekis_ffi.dll`（x64、arm64，MSVC 工具链）| MSIX（微软商店）+ 免安装 zip |
| Android | `liblekis_ffi.so`（arm64-v8a、armeabi-v7a、x86_64），用 `cargo-ndk` 编译 | AAB（Google Play）+ 按 ABI 拆分的 APK（官网版）|
| macOS / iOS（Beta）| 静态库 / XCFramework | App Store + 官网 dmg |
| Linux（Beta）| `liblekis_ffi.so` | Flatpak / AppImage / deb |
| NAS 节点 | `lekis-node` 可执行文件 | Docker（amd64 / arm64）、群晖 SPK 等 |

商店版和官网版的区别：商店版隐藏音源类插件分类（REQUIREMENTS 第 5 节）。
