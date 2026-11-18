//! 插件宿主（REQUIREMENTS 3.11 节，ADR-0003）。
//!
//! - 清单格式的唯一定义：`plugin-sdk/schema/plugin.schema.json`，[`manifest::PluginManifest`] 必须和它一致；
//! - 能力即导出函数：调用插件就是"调用某个导出函数，传一个 JSON 对象，拿回一个 JSON 对象"；
//! - 宿主 API（`host.http`、`host.storage`……）由运行时注入，每次调用都经过 [`permission::Permissions`] 检查。

pub mod manifest;
pub mod permission;
pub mod runtime;

pub use manifest::{Capability, PluginKind, PluginManifest};
pub use permission::Permissions;
pub use runtime::{PluginError, PluginRuntime};

/// 当前宿主实现的插件 API 版本。插件清单的 `apiVersion` 主版本号必须相同。
pub const PLUGIN_API_VERSION: (u32, u32) = (1, 0);
