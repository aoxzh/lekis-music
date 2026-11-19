# ADR-0006：UI 改用 Flutter，FFI 改用 flutter_rust_bridge

- 状态：已采纳（取代 [ADR-0001](0001-rust-core-native-ui.md) 的 UI 部分和 [ADR-0005](0005-ffi-uniffi.md)）
- 日期：2026-11-19
- 相关需求：`NFR-01`~`NFR-14`、`UIX-*`、`PTF-*`

## 背景

ADR-0001 决定每个平台各写一套原生 UI（Compose、WinUI 3、GTK4，以后再加 SwiftUI）。执行下来暴露了两个问题：

1. **人力对不上。** 实际投入是一个人加 AI agent，不是原 PRD 估算的 10 人团队。原生路线要维护 4~5 套 UI，每个页面写 4~5 遍，结果是核心做到了 1.0 阶段的功能，三端 UI 都还停在骨架。
2. **目标变成了全平台。** 产品要像 Jellyfin、Plex 那样覆盖 Windows、macOS、Linux、Android、iOS，以后还有电视。平台越多，原生路线越不划算。

另外，原生路线的主要好处（"像系统自带应用"）在这个产品里不重要：我们要的是 Apple Music 那样的**自有视觉语言**（大封面、取色动态背景、逐字歌词、弹簧动画），本来就不是系统控件能直接给的。

性能上的顾虑：Flutter 不是 Electron。它把 Dart 代码 AOT 编译成机器码，自带渲染引擎直接调 GPU 画界面，没有浏览器，也没有网页。而且播放器里吃性能的部分（解码、重采样、扫描、数据库、网络读取）全部在 Rust 核心里，UI 层只负责把数据画出来。

现有三端 UI 都还是骨架（Android 约 1.7k 行、Windows 约 2.2k 行、Linux 约 3.7k 行），现在换路线损失最小。

## 决策

1. **所有平台的 UI 统一用 Flutter**（Windows、Android 先行，macOS、iOS、Linux 在 Beta 跟进）。
2. **核心不变**：Rust 核心继续承担全部业务逻辑，"UI 不写业务逻辑"仍然是硬性规则。
3. **FFI 改用 flutter_rust_bridge v2**（MIT）。`lekis-ffi` 保留"把领域类型翻译成 FFI 友好类型"的职责，只把导出方式从 UniFFI 换成 flutter_rust_bridge：
   - 命令：Rust `async fn` → Dart `Future`
   - 事件：核心事件流 → Dart `Stream`（替代原来的 `CoreEventListener` 回调接口）
   - 平台能力反向注入（凭据存储、网络状态）：Dart 实现、Rust 调用，保持 `platform.rs` 里的 trait 不变
4. **音频输出仍然在 Rust 核心里**（cpal / WASAPI / AAudio），Flutter 不碰音频数据。比特完美、无缝、重采样都和 UI 框架无关。
5. **系统集成写薄薄一层原生代码**，这部分本来选哪条路线都得写：
   - 锁屏、通知、蓝牙按键、系统媒体控制：`audio_service`（MIT）对接 Android MediaSession 和 iOS Now Playing；Windows SMTC、Linux MPRIS 用对应的 Flutter 插件或小段平台代码
   - 桌面悬浮歌词：每个桌面平台一个小的原生透明窗口（Flutter 多窗口支持还不成熟）
   - CarPlay、Android Auto、小组件：只能用平台模板，按平台写原生
6. **旧的原生 UI 冻结**：`apps/android`、`apps/windows`、`apps/linux` 不再加功能，Flutter 端达到同等功能后删除。

## 备选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| 各平台原生 UI（ADR-0001） | 性能和系统集成上限最高 | 4~5 套 UI；一个人维护不了，平台之间必然不一致 |
| **Flutter + Rust 核心（采纳）** | 一套 UI 覆盖所有平台；自绘最适合定制视觉和歌词动效；有 Finamp（MPL-2.0）这样可以直接复用代码的同类项目 | 桌面端原生感弱一些；多窗口要自己补；安装包大 10~20MB |
| Compose Multiplatform | Android 体验最好 | 桌面端跑在 JVM 上，启动慢、内存高 |
| Tauri / Electron + Web 前端 | 前端生态大 | 本质是网页，移动端 WebView 撑不住 10 万行列表和复杂动效；Electron 内存占用高，这正是要避免的体验 |

## 后果

- `lekis-ffi` 去掉 `uniffi`，改用 flutter_rust_bridge 的代码生成；领域 crate 不受影响。ARCHITECTURE.md 第 2 节第 4 条相应改为"只有 `lekis-ffi` 能出现 FFI 框架的代码"。
- `tools/env-windows-gnu.ps1` 里的 dlltool 问题不再相关（Flutter Windows 用 MSVC 工具链，核心编译成 `cdylib`）。
- 原来按平台写的编码规范（Kotlin、C#）作废，改为 Flutter/Dart 规范。
- 设计 Token 继续以 `design/tokens.json` 为唯一来源，生成 Dart 主题代码。
- Phase 0 必须验证三件事，任何一项不达标都要回到这份 ADR 重新评估：
  1. 中端 Android 手机上，10 万行歌曲列表快速滚动不掉帧
  2. Windows 和 Android 上，flutter_rust_bridge 高频事件（播放进度、扫描进度）不卡 UI
  3. 冷启动时间达到 REQUIREMENTS 第 4.1 节的指标
