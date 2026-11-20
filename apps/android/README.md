# Lekis Music — Android

> **已冻结**（[ADR-0006](../../docs/adr/0006-flutter-ui.md)）：UI 已改用 Flutter（[`app/`](../../app/)）。这里不再加功能、不作为日常构建目标，Alpha 退出后连同 `core/crates/lekis-ffi`、`tools/gen-bindings.*`、`tools/build-*-core.*` 和对应 CI 一起删除。下面的内容只作历史参考。

Kotlin + Jetpack Compose + Media3 + Hilt。最低 Android 8.0（API 26），目标 API 35。

## 模块

| 模块 | 职责 | 依赖规则 |
|---|---|---|
| `:app` | 页面（`feature/*`）、导航、播放服务（`playback/`）| 只能通过 `CoreBridge` 调用核心 |
| `:core:bridge` | 包装 UniFFI 生成的绑定，对外提供 `CoreBridge` 接口和 Kotlin 版本的数据模型 | **唯一**可以 import `uniffi.lekis_ffi.*` 的模块 |
| `:core:designsystem` | 主题、设计 Token、通用组件 | 不依赖核心 |

## 播放架构

```
UI（NowPlayingScreen 等）
  └─ MediaController（PlaybackConnection）
       └─ LekisPlaybackService（MediaSessionService）
            └─ CorePlayer（Media3 SimpleBasePlayer）
                 └─ CoreBridge → Rust 播放引擎（解码、DSP、AAudio 输出）
```

**所有播放控制都走 MediaController**，这样通知栏、锁屏、蓝牙按键、Android Auto 和 App 内的控制是同一条路径。
音频由 Rust 引擎直接输出，Media3 只负责媒体会话（不使用 ExoPlayer 解码）。

## 构建

```bash
# 1. 编译 Rust 核心，输出到 core/bridge/src/main/jniLibs/
../../tools/build-android-core.sh
# 2. 生成 Kotlin 绑定，输出到 core/bridge/src/main/kotlin/uniffi/
../../tools/gen-bindings.sh
# 3. 编译 App
./gradlew assembleDebug
```

Windows 上用对应的 PowerShell 版本（环境自动探测，可在全新 shell 里直接跑）：

```powershell
..\..\tools\build-android-core.ps1          # 自动找 NDK，输出 jniLibs，列大小 + ELF 自检
..\..\tools\gen-bindings.ps1                # 只在 Rust 侧导出接口变化时需要重跑
gradle assembleDebug --no-daemon
```

生成的 `.so` 和绑定代码都不提交到仓库（见 `.gitignore`）。
