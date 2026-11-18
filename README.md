# Lekis Music（月兔音乐）

跨平台、开箱即用的本地 / NAS 音乐播放器。不需要部署服务器，直接播放本机和 NAS（SMB / WebDAV / NFS / SFTP）上的音乐，也能接入 Navidrome、Jellyfin、Plex 等自有服务器；自动补全封面和歌词；支持社区插件。

> 当前状态：**工程地基（原型骨架）**。目录结构、模块边界、接口、数据库表结构、插件协议和 CI 都已定好；大部分实现还是 `todo!()` 或占位。接手开发前请先读完下面"必读文档"。

## 必读文档

| 文档 | 内容 |
|---|---|
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | 需求编号与验收基线（功能、性能、兼容性）|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构、模块边界、依赖规则、线程模型 —— **改代码之前必须读** |
| [docs/CODING_GUIDELINES.md](docs/CODING_GUIDELINES.md) | Rust / Kotlin / C# 编码规范 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 分支、提交、PR、ADR 流程 |
| [docs/adr/](docs/adr/) | 架构决策记录（为什么这么选）|

## 技术栈一览

| 层 | 技术 | 目录 |
|---|---|---|
| 核心（全部业务逻辑）| Rust 2021，tokio，SQLite，symphonia | [`core/`](core/) |
| 绑定层 | UniFFI（自动生成 Kotlin / C# 绑定）| [`core/crates/lekis-ffi`](core/crates/lekis-ffi) |
| Android | Kotlin + Jetpack Compose + Media3 + Hilt | [`apps/android/`](apps/android/) |
| Windows | C# / .NET 10 + WinUI 3（Windows App SDK）+ CommunityToolkit.Mvvm | [`apps/windows/`](apps/windows/) |
| Linux | Rust + GTK4 + libadwaita（直接调用核心，不经过 FFI）| `apps/linux/`（未开始）|
| 可选 NAS 节点 | Rust + axum（和客户端是同一个核心）| [`core/bins/lekis-node`](core/bins/lekis-node) |
| 插件 SDK | WIT + TypeScript 类型 + JSON Schema | [`plugin-sdk/`](plugin-sdk/) |
| 设计 Token | 三个平台共用的一份 JSON | [`design/`](design/) |

苹果平台（iOS / macOS）暂不开发，但核心和 FFI 的设计已经为它预留（UniFFI 也能生成 Swift 绑定）。

## 目录结构

```
.
├── core/                  Rust workspace（所有业务逻辑都在这里）
│   ├── crates/
│   │   ├── lekis-types        领域模型、ID、错误、事件（不依赖任何 IO）
│   │   ├── lekis-vfs          虚拟文件系统：本地 / SMB / WebDAV / NFS / SFTP
│   │   ├── lekis-library      SQLite 数据库、迁移、查询、全文搜索
│   │   ├── lekis-scanner      扫描流水线、标签读取、NAS 共享索引
│   │   ├── lekis-providers    媒体服务器源：OpenSubsonic / Jellyfin / Plex / Emby
│   │   ├── lekis-enrich       封面 / 歌词 / 标签补全、匹配打分
│   │   ├── lekis-playback     播放引擎：解码 → DSP → 输出
│   │   ├── lekis-sync         无服务器多设备同步（操作日志 + HLC）
│   │   ├── lekis-plugin-host  插件清单、权限、JS / WASM 运行时
│   │   ├── lekis-core         门面：组装所有服务，对外的唯一入口
│   │   └── lekis-ffi          UniFFI 导出层（Android / Windows 用）
│   └── bins/lekis-node        可选的 headless NAS 节点
├── apps/
│   ├── android/           Kotlin + Compose
│   ├── windows/           C# + WinUI 3
│   └── linux/             Rust + GTK4（未开始）
├── plugin-sdk/            插件协议（WIT / JSON Schema / TS SDK / 示例）
├── design/                设计 Token
├── tools/                 构建和代码生成脚本
└── docs/                  需求、架构、规范、ADR
```

## 开发环境

| 目标 | 需要安装 |
|---|---|
| 核心 | Rust（版本见 [`core/rust-toolchain.toml`](core/rust-toolchain.toml)），`cargo install cargo-deny` |
| Android | JDK 17、Android SDK + NDK r27、`cargo install cargo-ndk`、`rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android` |
| Windows | .NET 10 SDK、Visual Studio 2022（"Windows 应用开发"工作负载）、`cargo install uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs` |
| Linux | `libgtk-4-dev`、`libadwaita-1-dev`、`libasound2-dev` |

## 常用命令

```bash
# 核心：格式化、静态检查、测试
cd core && cargo fmt --all && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

```bash
# 生成 Kotlin / C# 绑定（核心的对外接口变了之后必须重新生成）
./tools/gen-bindings.sh
```

```bash
# Android：先编译核心的 .so，再编译 App
./tools/build-android-core.sh && cd apps/android && ./gradlew assembleDebug
```

```powershell
# Windows：先编译核心的 .dll，再编译 App
./tools/build-windows-core.ps1; dotnet build apps/windows/Lekis.Windows.sln -c Debug -p:Platform=x64
```
