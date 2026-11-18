//! Lekis 的领域模型、强类型 ID、错误和事件。
//!
//! 规则（见 docs/ARCHITECTURE.md 第 2 节）：这个 crate 只放纯数据，
//! 不能依赖 tokio、rusqlite、reqwest 等任何 IO 库。

pub mod error;
pub mod event;
pub mod ids;
pub mod model;

pub use error::{ErrorCode, LekisError, Result};
pub use event::{CoreEvent, LibraryScope, ScanPhase, SyncState};
pub use ids::*;
pub use model::*;

/// 当前时间（Unix 毫秒）。数据库和同步日志里的时间都用这个格式。
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
