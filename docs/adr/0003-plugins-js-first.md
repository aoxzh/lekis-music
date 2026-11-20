# ADR-0003：插件以 JS/TS 为主，WASM 为辅

- 状态：已采纳
- 日期：2026-11-19
- 相关需求：PLG-01~10、DEV-01~10

## 背景

要对外开放插件开发。参考 mygo-music：JS/TS 免构建插件对开发者最友好。同时 iOS（以后）不允许 JIT。

## 决策

- 主运行时：JS/TS，用 QuickJS（`rquickjs`）解释执行，宿主内置 TS 转译。所有平台行为一致。
- 进阶运行时：WASM 组件模型（WIT 接口见 `plugin-sdk/wit/`），桌面和 Android 用 wasmtime，以后的 iOS 用 wasmi。1.x 再实现。
- 插件清单 `plugin.json` 的唯一定义是 `plugin-sdk/schema/plugin.schema.json`，Rust 端的 `PluginManifest` 必须和它保持一致。
- 默认零权限；网络只能访问清单里声明的域名；`spawn` 只在桌面端提供，而且需要用户逐个允许。
- 官方不开发、不托管第三方流媒体音源插件。

## 后果

- 插件接口要做语义化版本管理，破坏性变更需要新的 ADR。
- CI 要跑示例插件的兼容性测试。
