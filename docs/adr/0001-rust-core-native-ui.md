# ADR-0001：Rust 核心 + 各平台原生 UI

- 状态：已采纳
- 日期：2026-11-19
- 相关需求：`NFR-01`~`NFR-14`

## 背景

产品要覆盖 Android、Windows、Linux（苹果平台以后再做），对性能（冷启动、10 万首歌的列表滚动、耗电）和系统集成（锁屏、车机、系统媒体控制、桌面歌词）要求很高。方案初稿选的是 Flutter，评审后决定改成原生 UI。

## 决策

1. **所有业务逻辑放在 Rust 核心里**（扫描、资料库、播放引擎、刮削、同步、插件）。
2. **每个平台用自己的原生 UI 技术**：
   - Android：Kotlin + Jetpack Compose + Media3
   - Windows：C# + WinUI 3（Windows App SDK）。Windows 版 Apple Music 本身就是用 WinUI 3 做的，这证明它能做出我们想要的质感（Mica / Acrylic 材质、流畅动画）
   - Linux：Rust + GTK4 + libadwaita，直接调用核心，不需要 FFI
   - 苹果平台以后：Swift + SwiftUI
3. 核心通过 UniFFI 对外暴露接口（见 ADR-0005）。

## 备选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| Flutter + Rust | 一套 UI 覆盖所有平台 | 自绘 UI 和系统控件不一致；桌面端原生感差；车机、小组件、媒体会话还是要写原生代码 |
| Tauri + Web 前端 | 前端人才多 | Android WebView 性能不稳定；10 万行列表和复杂动效很难做好 |
| Go 核心 | 开发快 | 有 GC，不适合实时音频；嵌入移动端的生态弱 |
| **Rust 核心 + 原生 UI（采纳）** | 性能和系统集成最好；核心只写一遍 | UI 要写三份，人力成本更高 |

## 后果

- UI 要写多份，所以**"UI 不写业务逻辑"是硬性规则**（ARCHITECTURE.md 第 2 节），否则三端行为会不一致。
- 三端的页面划分、ViewModel 命名、设计 Token 必须保持一致（ARCHITECTURE.md 第 7 节）。
- Linux 端优先级低于 Android 和 Windows，先维持能编译的骨架。
