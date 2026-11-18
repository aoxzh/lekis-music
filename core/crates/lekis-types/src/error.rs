//! 统一错误类型。
//!
//! 每个错误都有一个稳定的 [`ErrorCode`]，平台 UI 根据它显示本地化提示，
//! 不要把 `message` 直接展示给用户（它是给日志和开发者看的）。

use serde::{Deserialize, Serialize};

/// 核心对外的结果类型。
pub type Result<T> = std::result::Result<T, LekisError>;

/// 稳定的错误码。**只能新增，不能修改或删除已有的值**（平台端和插件都依赖它）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// 要找的东西不存在。
    NotFound,
    /// 参数不合法。
    InvalidArgument,
    /// 当前平台或当前源不支持这个操作。
    Unsupported,
    /// 功能还没实现（原型阶段的占位）。
    NotImplemented,
    /// 本地文件系统错误。
    Io,
    /// 网络错误（超时、连接失败、DNS 等）。
    Network,
    /// 需要登录，或者凭据无效。
    Auth,
    /// 数据库错误。
    Database,
    /// 音频解码错误或者文件损坏。
    Decode,
    /// 插件出错。
    Plugin,
    /// 没有权限（插件权限、系统权限、只读共享）。
    PermissionDenied,
    /// 操作被取消。
    Cancelled,
    /// 远端限流。
    RateLimited,
    /// 其他内部错误（一般意味着 bug）。
    Internal,
}

impl ErrorCode {
    /// 错误码的字符串形式，用于日志、FFI 和插件协议。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotFound => "not_found",
            Self::InvalidArgument => "invalid_argument",
            Self::Unsupported => "unsupported",
            Self::NotImplemented => "not_implemented",
            Self::Io => "io",
            Self::Network => "network",
            Self::Auth => "auth",
            Self::Database => "database",
            Self::Decode => "decode",
            Self::Plugin => "plugin",
            Self::PermissionDenied => "permission_denied",
            Self::Cancelled => "cancelled",
            Self::RateLimited => "rate_limited",
            Self::Internal => "internal",
        }
    }
}

/// 核心的统一错误。
#[derive(Debug, Clone, thiserror::Error)]
#[error("[{}] {message}", code.as_str())]
pub struct LekisError {
    /// 稳定错误码。
    pub code: ErrorCode,
    /// 给开发者看的说明（可能包含技术细节，不要直接展示给用户）。
    pub message: String,
}

impl LekisError {
    /// 用错误码和说明构造错误。
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// 原型阶段的占位：功能还没实现。用它代替 `todo!()`，这样 App 不会崩溃。
    pub fn not_implemented(what: &str) -> Self {
        Self::new(
            ErrorCode::NotImplemented,
            format!("not implemented yet: {what}"),
        )
    }

    /// 东西不存在。
    pub fn not_found(what: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, what)
    }

    /// 参数不合法。
    pub fn invalid(what: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidArgument, what)
    }

    /// 不支持的操作。
    pub fn unsupported(what: impl Into<String>) -> Self {
        Self::new(ErrorCode::Unsupported, what)
    }

    /// 内部错误。
    pub fn internal(what: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, what)
    }
}

impl From<std::io::Error> for LekisError {
    fn from(e: std::io::Error) -> Self {
        let code = match e.kind() {
            std::io::ErrorKind::NotFound => ErrorCode::NotFound,
            std::io::ErrorKind::PermissionDenied => ErrorCode::PermissionDenied,
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::ConnectionRefused => {
                ErrorCode::Network
            }
            _ => ErrorCode::Io,
        };
        Self::new(code, e.to_string())
    }
}
