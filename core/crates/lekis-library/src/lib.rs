//! Lekis 资料库。
//!
//! - 一个专用写线程串行执行所有写操作（[`Library::write`]）；
//! - 多个只读连接处理查询（[`Library::read`]），WAL 模式下读写互不阻塞；
//! - 表结构只能通过 `migrations/` 下的迁移文件修改。
//!
//! **数据库文件必须在本机**，不能放在网络共享上（ADR-0004）。

mod artwork;
mod browse;
mod db;
mod enrich_queue;
mod lyrics;
mod migrations;
pub mod normalize;
mod playlists;
mod position;
mod remote;
mod scanned;
mod search;
mod settings;
mod smart;
mod sources;
mod sync;
mod tracks;

pub use artwork::{cache_relative_path, ArtworkRow};
pub use db::{DbResultExt, Library};
pub use enrich_queue::{EnrichCandidateRow, NewEnrichCandidate};
pub use lyrics::LyricsRow;
pub use playlists::{Playlist, PlaylistEntry, PlaylistItem, PlaylistKind};
pub use remote::{RemoteTrackRow, RemoteUpsertStats};
pub use scanned::{quality_score, ScannedFile, ScannedTags, UpsertStats};
pub use smart::{AllowedColumns, Rule, RuleField, RuleGroup, RuleOp, RuleValue, SmartRules};
pub use sync::OutboxEntry;
pub use tracks::{TrackFile, TrackUserState};
