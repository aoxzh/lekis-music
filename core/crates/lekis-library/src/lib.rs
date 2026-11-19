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
mod folders;
mod listening;
mod lyrics;
mod migrations;
pub mod normalize;
mod offline;
mod playback_state;
mod playlist_io;
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

pub use artwork::{cache_relative_path, ArtworkCandidate, ArtworkRow};
pub use db::{DbResultExt, Library};
pub use enrich_queue::{EnrichCandidateRow, NewEnrichCandidate};
pub use folders::{normalize_folder_path, FolderEntry, FolderListing, FolderRoot};
pub use listening::{
    AlbumListening, ArtistListening, ListeningBucket, ListeningSummary, TrackListening,
};
pub use lyrics::LyricsRow;
pub use offline::{OfflineDownload, OfflineStats};
pub use playback_state::PlaybackStateRow;
pub use playlist_io::{parse_m3u, M3uEntry, PlaylistImportReport};
pub use playlists::{Playlist, PlaylistEntry, PlaylistItem, PlaylistKind};
pub use remote::{RemoteTrackRow, RemoteUpsertStats};
pub use scanned::{quality_score, ScannedFile, ScannedTags, UpsertStats};
pub use smart::{AllowedColumns, Rule, RuleField, RuleGroup, RuleOp, RuleValue, SmartRules};
pub use sources::SourceInfo;
pub use sync::OutboxEntry;
pub use tracks::{TrackContext, TrackFile, TrackUserState};
