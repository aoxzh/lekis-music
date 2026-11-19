//! Flutter 桥接层（ADR-0006）：用 flutter_rust_bridge 把核心暴露给 Dart。
//!
//! 规则和 lekis-ffi 一样：这里只做类型转换，不写业务逻辑。

pub mod api;
#[cfg(target_os = "android")]
mod android_context;
mod credentials;
mod internal;
mod media_controls;
mod frb_generated;
