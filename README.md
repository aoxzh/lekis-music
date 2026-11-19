# Lekis Music（月兔音乐）

跨平台、开箱即用的本地 / NAS 音乐播放器。不需要部署服务器，直接播放本机和 NAS（SMB / WebDAV / NFS / SFTP）上的音乐，也能接入 Navidrome、Jellyfin、Plex 等自有服务器；自动补全封面和歌词；支持社区插件。

> 当前状态：**Phase 0 已通过，Alpha 收尾中**。核心（Rust）的扫描、标签解析、资料库、搜索、播放、无缝播放、WASAPI 独占、网络音源、补全、同步、插件运行时都有真实实现。Flutter 客户端（`app/`）已覆盖 Windows + Android：播放、歌词、文件夹、NAS 发现、歌单、会话恢复和动态 TabBar 可用；旧的 `apps/` 已冻结。当前阶段和下一步见 [docs/ROADMAP.md](docs/ROADMAP.md)，第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 必读文档

| 文档 | 内容 |
|---|---|
| [docs/ROADMAP.md](docs/ROADMAP.md) | **当前阶段、阶段闸门、下一步做什么** |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | 需求编号与验收基线（功能、性能、兼容性）|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构、模块边界、依赖规则、线程模型 —— **改代码之前必须读** |
| [docs/CODING_GUIDELINES.md](docs/CODING_GUIDELINES.md) | Rust / Flutter 编码规范 |
| [docs/REUSE.md](docs/REUSE.md) | 复用清单：写新模块前先查这里 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 分支、提交、PR、ADR 流程 |
| [docs/adr/](docs/adr/) | 架构决策记录（为什么这么选）|

## 技术栈一览

| 层 | 技术 | 目录 |
|---|---|---|
| 核心（全部业务逻辑）| Rust 2021，tokio，SQLite，symphonia | [`core/`](core/) |
| 绑定层 | flutter_rust_bridge v2（迁移中，旧的是 UniFFI）| [`core/crates/lekis-ffi`](core/crates/lekis-ffi) |
| 客户端 UI | Flutter + Riverpod：Windows、Android 先行，macOS、iOS、Linux 在 Beta 跟进 | `app/`（Phase 0 创建）|
| 旧的原生 UI（已冻结）| Kotlin/Compose、C#/WinUI 3、Rust/GTK4 | [`apps/`](apps/) |
| 可选 NAS 节点 | Rust + axum（和客户端是同一个核心）| [`core/bins/lekis-node`](core/bins/lekis-node) |
| 插件 SDK | WIT + TypeScript 类型 + JSON Schema | [`plugin-sdk/`](plugin-sdk/) |
| 设计 Token | 所有平台共用的一份 JSON | [`design/`](design/) |

许可证：MPL-2.0，复用优先（[ADR-0007](docs/adr/0007-license-and-reuse-first.md)）。

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
│   │   └── lekis-ffi          FFI 导出层（给 Flutter 用）
│   └── bins/lekis-node        可选的 headless NAS 节点
├── app/                   Flutter 客户端（Phase 0 创建）
├── apps/                  旧的原生 UI（已冻结，Flutter 端追上后删除）
├── plugin-sdk/            插件协议（WIT / JSON Schema / TS SDK / 示例）
├── design/                设计 Token
├── tools/                 构建和代码生成脚本
└── docs/                  需求、架构、规范、ADR
```

## 开发环境

| 目标 | 需要安装 |
|---|---|
| 核心 | Rust（版本见 [`core/rust-toolchain.toml`](core/rust-toolchain.toml)），`cargo install cargo-deny` |
| Flutter App | Flutter stable（3.50+，见 `app/.metadata`）、`dart`；`flutter doctor` 通过 |
| Android | JDK 17、Android SDK 37 + NDK `28.2.13676358`、`rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`；Cargokit 会在 `flutter build` 时自动编译 Rust |
| Windows | Flutter Windows 桌面工具链 + Visual Studio 的 C++ 桌面负载（Cargokit 需要 MSVC）；本机开发和测试 |
| Linux | 后续 Beta 再补 GTK/Flutter Linux 依赖 |

Windows 上用 GNU Rust 工具链开发核心时，先 dot-source [`tools/env-windows-gnu.ps1`](tools/env-windows-gnu.ps1)：它会配好 `dlltool`（**必须用 GNU binutils 的 `dlltool.exe`，`llvm-dlltool` 生成的 import library 会让程序一启动就 `0xC0000005`**）、CC/AR 和 `CARGO_HOME`。Flutter Windows App 本身用 MSVC 构建。

## 常用命令

```bash
# 核心：格式化、静态检查、测试
cd core && cargo fmt --all && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

```bash
# Flutter App：静态分析 + 单元/组件测试
cd app && flutter pub get && flutter analyze && flutter test
```

```bash
# Android：Cargokit 会自动构建 Rust 核心；只打 arm64 最快
cd app && flutter build apk --release --target-platform android-arm64
# 安装到主调试机 Fold5（SM-F946N）
adb -s <fold5-serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

```powershell
# Windows：本机 release 构建，产物在 app/build/windows/x64/runner/Release/lekis.exe
cd app; flutter build windows --release
```

```bash
# 10 万首性能库（可选）：生成到任意本地数据目录（不要提交）
cd core && cargo run -p lekis-library --example seed_fake_library --release -- <data-dir> 100000
# 构建时用 --dart-define=LEKIS_DATA_DIR=<data-dir> 指向它；正常安装不要带这个参数
```

> Android 主调试机是 **Samsung Fold5（SM-F946N）**；Windows 就在本机开发和测试。旧的 `apps/android`、`apps/windows` 是冻结的原生 UI，不再作为日常构建目标。
