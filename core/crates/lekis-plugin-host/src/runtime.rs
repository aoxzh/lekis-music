//! 插件运行时。
//!
//! - [`JsRuntime`]：QuickJS（rquickjs），1.0 实现。每个插件一个独立的 JS 上下文；
//!   宿主内置 TS 转译（swc / oxc 二选一，Phase 0 评估包体积）；
//! - WASM 运行时：1.x 实现，接口见 `plugin-sdk/wit/lekis-plugin.wit`。
//!
//! 每次调用都有超时（默认 15 秒）、内存上限（默认 64MB）。插件崩溃不能影响 App。

use crate::manifest::{Capability, PluginManifest};
use crate::permission::Permissions;
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, Result};
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// 默认调用超时。
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(15);

/// 插件抛出的结构化错误（PLG-07）。界面据此引导用户。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PluginError {
    /// 需要登录。
    SignIn,
    /// 需要先完成设置。
    Setup,
    /// 内容暂时不可用。
    Unavailable,
    /// 插件不支持这个操作。
    Unsupported,
    /// 被限流，稍后再试。
    RateLimited,
}

impl From<PluginError> for LekisError {
    fn from(e: PluginError) -> Self {
        let code = match e {
            PluginError::SignIn => ErrorCode::Auth,
            PluginError::Setup => ErrorCode::InvalidArgument,
            PluginError::Unavailable => ErrorCode::NotFound,
            PluginError::Unsupported => ErrorCode::Unsupported,
            PluginError::RateLimited => ErrorCode::RateLimited,
        };
        LekisError::new(code, format!("plugin error: {e:?}"))
    }
}

/// 已加载的插件实例。
#[async_trait]
pub trait PluginRuntime: Send + Sync {
    /// 清单。
    fn manifest(&self) -> &PluginManifest;

    /// 插件实际导出了哪些能力（加载时检查导出函数得到）。
    fn capabilities(&self) -> &[Capability];

    /// 调用一个能力。参数和返回值都是 JSON 对象，结构见 `plugin-sdk/js/src/index.ts`。
    async fn call(
        &self,
        capability: Capability,
        params: serde_json::Value,
    ) -> Result<serde_json::Value>;
}

/// JS 运行时（占位）。
pub struct JsRuntime {
    manifest: PluginManifest,
    #[allow(dead_code)]
    permissions: Permissions,
}

impl JsRuntime {
    /// 加载插件目录下的入口文件。
    pub fn load(manifest: PluginManifest, permissions: Permissions, _source: &str) -> Result<Self> {
        tracing::info!(target: "plugin", id = %manifest.id, "loading js plugin (stub)");
        Ok(Self {
            manifest,
            permissions,
        })
    }
}

#[async_trait]
impl PluginRuntime for JsRuntime {
    fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    fn capabilities(&self) -> &[Capability] {
        &[]
    }

    async fn call(
        &self,
        _capability: Capability,
        _params: serde_json::Value,
    ) -> Result<serde_json::Value> {
        Err(LekisError::not_implemented("quickjs runtime"))
    }
}
