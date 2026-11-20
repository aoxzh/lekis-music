# ADR-0005：FFI 使用 UniFFI

- 状态：**已取代**，被 [ADR-0006](0006-flutter-ui.md) 取代（Flutter 端改用 flutter_rust_bridge，代码在 `lekis-bridge`）。本 ADR 描述的 `lekis-ffi` + UniFFI、`tools/gen-bindings.*`、`bins/uniffi-bindgen` 已随冻结的 `apps/` 一起在 0.1.0-alpha.1 前删除，代码见 git 历史。
- 日期：2026-11-19
- 相关需求：ADR-0001

## 背景

Rust 核心需要被 Kotlin（Android）和 C#（Windows）调用，以后还有 Swift（苹果平台）。

## 决策

- 使用 Mozilla 的 **UniFFI**（proc-macro 方式，不写 UDL 文件）。
  - Kotlin：官方 `uniffi-bindgen`，运行时依赖 JNA。
  - C#：NordSecurity 的 `uniffi-bindgen-cs`（第三方，版本要和 uniffi 对齐；原来 `lekis-ffi/Cargo.toml` 里的注释已随代码删除）。
  - Swift：官方支持，以后用。
- 所有 FFI 类型集中在 `lekis-ffi`，和领域类型分开，通过 `From` 转换。
- 生成的绑定代码**不提交到仓库**，由 `tools/gen-bindings.sh` 生成（CI 里也会生成；脚本已删除，见 git 历史）。

## 备选方案

| 方案 | 缺点 |
|---|---|
| 手写 JNI + C ABI | 三个平台各写一遍胶水代码，容易出内存错误 |
| flutter_rust_bridge | 只适用于 Flutter，已经不用 Flutter 了 |
| gRPC / 本地 HTTP | 有序列化和进程间通信开销，不适合播放控制这种高频调用 |

## 后果

- `uniffi-bindgen-cs` 是第三方项目，更新可能比 uniffi 慢，升级 uniffi 前先确认它已经支持。
- async 函数和回调接口要遵守 UniFFI 的限制（例如回调接口必须 `Send + Sync`）。
