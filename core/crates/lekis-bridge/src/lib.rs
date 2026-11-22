//! Flutter 桥接层（ADR-0006）：用 flutter_rust_bridge 把核心暴露给 Dart。
//!
//! 规则：这里只做类型转换，不写业务逻辑。

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

#[cfg(target_os = "android")]
mod android_context;
pub mod api;
mod credentials;
mod internal;
mod media_controls;
mod usb_audio;
// FRB 生成代码里有大量序列化 unwrap；不把手写代码的 lint 规则套到它上面。
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod frb_generated;
