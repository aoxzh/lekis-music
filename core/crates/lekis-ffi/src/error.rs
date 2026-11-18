use lekis_types::{ErrorCode, LekisError};

/// 错误类别。平台根据它显示本地化提示（不要直接显示 `detail`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ErrorKind {
    NotFound,
    InvalidArgument,
    Unsupported,
    NotImplemented,
    Io,
    Network,
    Auth,
    Database,
    Decode,
    Plugin,
    PermissionDenied,
    Cancelled,
    RateLimited,
    Internal,
}

impl From<ErrorCode> for ErrorKind {
    fn from(c: ErrorCode) -> Self {
        match c {
            ErrorCode::NotFound => Self::NotFound,
            ErrorCode::InvalidArgument => Self::InvalidArgument,
            ErrorCode::Unsupported => Self::Unsupported,
            ErrorCode::NotImplemented => Self::NotImplemented,
            ErrorCode::Io => Self::Io,
            ErrorCode::Network => Self::Network,
            ErrorCode::Auth => Self::Auth,
            ErrorCode::Database => Self::Database,
            ErrorCode::Decode => Self::Decode,
            ErrorCode::Plugin => Self::Plugin,
            ErrorCode::PermissionDenied => Self::PermissionDenied,
            ErrorCode::Cancelled => Self::Cancelled,
            ErrorCode::RateLimited => Self::RateLimited,
            ErrorCode::Internal => Self::Internal,
        }
    }
}

/// 核心对外抛出的唯一错误类型。
///
/// 字段**不能**叫 `message`：Kotlin/C# 的异常基类已经有 `message` / `Message` 属性，
/// UniFFI 生成的代码会和它冲突导致编译失败。
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{detail}")]
    Failed {
        /// 错误类别。
        kind: ErrorKind,
        /// 给开发者看的详情（日志用，不直接展示给用户）。
        detail: String,
    },
}

impl From<LekisError> for CoreError {
    fn from(e: LekisError) -> Self {
        Self::Failed {
            kind: e.code.into(),
            detail: e.message,
        }
    }
}
