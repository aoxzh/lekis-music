use lekis_types::{ErrorCode, LekisError};

/// 错误类别。平台根据它显示本地化提示（不要直接显示 `detail`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
/// 用普通结构体而不是单变体枚举：frb 会把单变体枚举生成成 freezed 联合类型，
/// 而 freezed 对这种情况生成的 copyWith 无法编译。
#[derive(Debug, thiserror::Error)]
#[error("{detail}")]
pub struct CoreError {
    /// 错误类别。
    pub kind: ErrorKind,
    /// 给开发者看的详情（日志用，不直接展示给用户）。
    pub detail: String,
}

impl From<LekisError> for CoreError {
    fn from(e: LekisError) -> Self {
        Self {
            kind: e.code.into(),
            detail: e.message,
        }
    }
}
