//! 无服务器多设备同步（REQUIREMENTS 3.8 节，SYN-01~07，ADR-0002、ADR-0004）。
//!
//! - 每个修改生成一条 [`SyncOp`]，带混合逻辑时钟 [`Hlc`]；
//! - 每台设备只往自己的日志目录追加（`.lekis/sync/<device_id>/`），所以没有写冲突；
//! - 读取所有设备的日志，按"字段级最后写入者胜"合并（[`merge`]）；
//! - 歌单排序用位置键（`position_key`，字典序）实现序列 CRDT，见 [`position`]。
//!
//! 这个 crate 只认识"实体 + ID + 字段 + 值"，不知道业务含义。物化到数据库由 lekis-core 完成。

pub mod channel;
pub mod hlc;
pub mod merge;
pub mod position;

pub use hlc::{Hlc, HlcClock};

use serde::{Deserialize, Serialize};

/// 可同步的实体类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityKind {
    /// 曲目的用户状态（收藏、评分），ID 是 TrackUid。
    TrackState,
    /// 曲目的元数据覆盖层（补全结果、用户修正），ID 是 TrackUid。
    TrackOverlay,
    /// 歌单属性（名称、规则……），ID 是歌单 uid。
    Playlist,
    /// 歌单条目，ID 是 `歌单uid/位置键`。
    PlaylistItem,
    /// 播放记录（只追加，不合并），ID 是事件 uid。
    PlayEvent,
    /// 设置项，ID 是设置键。
    Setting,
}

/// 一条同步操作。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncOp {
    /// 时间戳（同时是全局唯一的操作 ID）。
    pub hlc: Hlc,
    /// 实体类型。
    pub entity: EntityKind,
    /// 实体 ID。
    pub entity_id: String,
    /// 字段名。
    pub field: String,
    /// 新值；`None` 表示删除（墓碑）。
    pub value: Option<serde_json::Value>,
}
