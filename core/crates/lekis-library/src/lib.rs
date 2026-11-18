//! Lekis 资料库。
//!
//! - 一个专用写线程串行执行所有写操作（[`Library::write`]）；
//! - 多个只读连接处理查询（[`Library::read`]），WAL 模式下读写互不阻塞；
//! - 表结构只能通过 `migrations/` 下的迁移文件修改。
//!
//! **数据库文件必须在本机**，不能放在网络共享上（ADR-0004）。

mod db;
mod migrations;
pub mod normalize;
mod scanned;
mod search;
mod sources;
mod tracks;

pub use db::{DbResultExt, Library};
pub use scanned::{ScannedFile, ScannedTags, UpsertStats};
pub use tracks::TrackFile;
