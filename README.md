# Lekis Music（月兔音乐）

跨平台、开箱即用的本地 / NAS 音乐播放器。不需要部署服务器，直接播放本机和 NAS（SMB / WebDAV / NFS / SFTP）上的音乐，也能接入 Navidrome、Jellyfin、Plex 等自有服务器；自动补全封面和歌词；支持社区插件。

> 当前状态：**Alpha 预览版 `0.1.0-alpha.1`**（Android APK + Windows 免安装 zip，见 GitHub Releases；变更见 [CHANGELOG.md](CHANGELOG.md)）。Flutter 客户端（`app/`）在 Windows 和 Android 上可以日常使用；macOS / iOS / Linux 在 Beta 跟进。逐项进度见 [docs/HANDOFF.md](docs/HANDOFF.md)，阶段规则见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 现在能做什么

- **音源**：本地文件夹、SMB、WebDAV，局域网自动发现 NAS（mDNS / WS-Discovery / SSDP）；Jellyfin / Emby / Plex / OpenSubsonic 服务器；密码存系统钥匙串；离线下载单曲、歌单和合集。
- **资料库**：10 万首级别的库（冷启动 0.3 s、滚动 120 fps）；专辑 / 艺人 / 歌曲 / 流派 / 文件夹浏览；拼音和简繁搜索；歌单、智能歌单、喜欢、1–5 星；M3U / XSPF 导入导出；播放历史和年度回顾；重复检测、库健康检查；编辑标签并写回文件。
- **播放**：样本级无缝播放、Windows WASAPI 独占（比特完美）、ReplayGain、淡入淡出、10 段均衡器和耳机预设、睡眠定时、会话恢复、Last.fm / ListenBrainz / Libre.fm 上报；锁屏 / 通知 / SMTC 媒体控件，Windows 托盘。
- **封面和歌词**：自动补全封面和歌词（LRCLIB 等），低置信度结果进待确认页；逐行 / 逐字歌词、Flow / Steps / Tilt 歌词舞台；手动编辑歌词和时间偏移。
- **插件**：本地 JS 插件的安装、启用、权限和设置（协议见 [`plugin-sdk/`](plugin-sdk/)）。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/HANDOFF.md](docs/HANDOFF.md) | **现在做到哪、正在做什么、已知问题、下一步** |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 阶段和阶段闸门 |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | 需求编号、实现状态、验收基线 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构、模块边界、依赖规则、线程模型 —— **改代码之前必须读** |
| [docs/DESIGN.md](docs/DESIGN.md) | 视觉与交互方向 |
| [docs/CODING_GUIDELINES.md](docs/CODING_GUIDELINES.md) | Rust / Flutter 编码规范 |
| [docs/REUSE.md](docs/REUSE.md) | 复用清单：写新模块前先查这里 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 分支、提交、PR、ADR 流程 |
| [docs/adr/](docs/adr/) | 架构决策记录（为什么这么选）|

## 技术栈

| 层 | 技术 | 目录 |
|---|---|---|
| 核心（全部业务逻辑）| Rust 2021，tokio，SQLite，symphonia，cpal / WASAPI | [`core/`](core/) |
| Flutter 桥接 | flutter_rust_bridge v2 | [`core/crates/lekis-bridge`](core/crates/lekis-bridge) |
| 客户端 UI | Flutter + Riverpod，一套代码覆盖所有平台 | [`app/`](app/) |
| 可选 NAS 节点 | Rust + axum（和客户端是同一个核心）| [`core/bins/lekis-node`](core/bins/lekis-node) |
| 插件 SDK | JSON Schema + TypeScript 类型 + WIT | [`plugin-sdk/`](plugin-sdk/) |
| 设计 Token | 一份 JSON | [`design/`](design/) |

许可证：MPL-2.0，复用优先（[ADR-0007](docs/adr/0007-license-and-reuse-first.md)）；第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

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
│   │   ├── lekis-enrich       封面 / 歌词 / 标签补全、匹配打分、Scrobble
│   │   ├── lekis-playback     播放引擎：解码 → DSP → 输出
│   │   ├── lekis-sync         无服务器多设备同步（操作日志 + HLC）
│   │   ├── lekis-plugin-host  插件清单、权限、JS 运行时
│   │   ├── lekis-core         门面：组装所有服务，对外的唯一入口
│   │   └── lekis-bridge       flutter_rust_bridge 导出层（Flutter 用）
│   ├── bins/lekis-node        可选的 headless NAS 节点
│   └── vendor/rquickjs-sys    给 Android 补 bindgen 输出的 rquickjs-sys
├── app/                   Flutter 客户端（app/lib/src/…，Rust 由 Cargokit 自动编译）
├── plugin-sdk/            插件协议（JSON Schema / TS SDK / WIT / 示例）
├── design/                设计 Token
├── tools/                 开发脚本（Android 联调、Windows 打包、隐私检查、图标生成）
└── docs/                  需求、架构、规范、ADR、交接
```

## 开发环境

| 目标 | 需要安装 |
|---|---|
| 核心 | Rust（版本见 [`core/rust-toolchain.toml`](core/rust-toolchain.toml)），`cargo install cargo-deny` |
| Flutter App | Flutter stable（3.50+，见 `app/.metadata`）、`dart`；`flutter doctor` 通过 |
| Android | JDK 17、Android SDK 37 + NDK `28.2.13676358`、`rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`；Cargokit 会在 `flutter build` 时自动编译 Rust |
| Windows | Flutter Windows 桌面工具链 + Visual Studio 的 C++ 桌面负载（Cargokit 需要 MSVC）；本机开发和测试 |
| Linux | Beta 再补 |

Flutter Windows App 用 MSVC 构建。只有在 Windows 上用 GNU Rust 工具链单独跑核心时才需要 dot-source [`tools/env-windows-gnu.ps1`](tools/env-windows-gnu.ps1)（配 GNU `dlltool`；`llvm-dlltool` 生成的 import library 会让程序一启动就 `0xC0000005`）。

## 常用命令

```bash
# 核心：格式化、静态检查、测试
cd core && cargo fmt --all && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

```bash
# Flutter App：静态分析 + 单元/组件测试
cd app && flutter pub get && flutter analyze && flutter test
```

```powershell
# Android 日常联调：只为已连接设备的 ABI 编 Rust 核心
tools/dev-android.ps1                  # flutter run（debug，可热重载）
tools/dev-android.ps1 -Mode release    # 构建 release APK 并安装
```

```bash
# Android 手动构建：Cargokit 会自动构建 Rust 核心；只打 arm64 最快
cd app && flutter build apk --release --target-platform android-arm64
adb -s <device-serial> install -r build/app/outputs/flutter-apk/app-release.apk
```

```bash
# 改了 core/crates/lekis-bridge/src/api/ 之后重新生成 Dart 绑定
cd app && flutter_rust_bridge_codegen generate
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

```powershell
# Windows 免安装包：把 release 构建打成 dist/lekis-<版本>-windows-x64.zip（dist/ 不提交）
tools/package-windows.ps1            # 先 flutter build windows --release；-SkipBuild 只打包
```

## 发布

推送 `v*` 标签（例如 `v0.1.0-alpha.1`）会触发 [`.github/workflows/release.yml`](.github/workflows/release.yml)：构建签名的 Android APK（arm64-v8a、armeabi-v7a）和 Windows x64 zip，并创建 GitHub pre-release。需要的仓库 secrets：`LEKIS_KEYSTORE_BASE64`、`LEKIS_KEYSTORE_PASSWORD`、`LEKIS_KEY_ALIAS`、`LEKIS_KEY_PASSWORD`。

本机签名：在 `app/android/key.properties`（不提交）里写 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`，keystore 放在仓库外。没有 keystore 时 release 构建会退回 debug 签名并在 Gradle 输出里警告，这样的包不能发布。

> Android 主调试机是 Samsung Fold5；Windows 在本机开发和测试。
