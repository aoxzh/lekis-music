//! 核心推给 UI 的事件。
//!
//! UI 通过事件更新界面，不要轮询。新增事件只能往后加变体，平台端遇到不认识的事件要忽略。

use crate::ids::*;
use crate::model::PlaybackState;
use serde::{Deserialize, Serialize};

/// 扫描阶段（LIB-03 渐进式扫描）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanPhase {
    /// 遍历目录（这一步结束后就可以按文件夹浏览了）。
    Walking,
    /// 读取标签。
    ReadingTags,
    /// 生成缩略图。
    Artwork,
    /// 写 NAS 共享索引。
    WritingSharedIndex,
}

/// 资料库哪部分变了（UI 据此决定刷新哪些页面）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryScope {
    /// 曲目 / 专辑 / 艺人。
    Catalog,
    /// 歌单。
    Playlists,
    /// 收藏、评分、播放次数。
    UserState,
    /// 音源列表。
    Sources,
}

/// 同步状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncState {
    /// 空闲（已是最新）。
    Idle,
    /// 正在同步。
    Syncing,
    /// 同步目录不可用（NAS 离线或只读）。
    Unavailable,
}

/// 核心事件。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CoreEvent {
    /// 播放状态或当前曲目变了。
    PlaybackChanged {
        /// 状态。
        state: PlaybackState,
        /// 当前曲目。
        track_id: Option<TrackId>,
        /// 当前位置（毫秒）。
        position_ms: u64,
        /// 总时长（毫秒）。
        duration_ms: u64,
    },
    /// 播放进度（播放中每 250ms 一次；UI 自己做插值动画）。
    PositionTick {
        /// 当前位置（毫秒）。
        position_ms: u64,
        /// 已缓冲到的位置（毫秒），网络源才有意义。
        buffered_ms: u64,
    },
    /// 播放队列变了。
    QueueChanged {
        /// 队列长度。
        length: u32,
        /// 当前下标。
        current_index: Option<u32>,
    },
    /// 扫描进度。
    ScanProgress {
        /// 音源。
        source_id: SourceId,
        /// 阶段。
        phase: ScanPhase,
        /// 已完成数量。
        done: u64,
        /// 总数（未知时为 `None`）。
        total: Option<u64>,
    },
    /// 扫描完成。
    ScanFinished {
        /// 音源。
        source_id: SourceId,
        /// 新增文件数。
        added: u64,
        /// 更新文件数。
        updated: u64,
        /// 删除文件数。
        removed: u64,
    },
    /// 资料库变化。
    LibraryChanged {
        /// 变化范围。
        scope: LibraryScope,
    },
    /// 补全"待确认"队列数量变了。
    EnrichQueueChanged {
        /// 待确认数量。
        pending: u32,
    },
    /// 同步状态变了。
    SyncStatus {
        /// 状态。
        state: SyncState,
    },
    /// 音源可达性变了（SRC-14 网络感知选路）。
    SourceReachability {
        /// 音源。
        source_id: SourceId,
        /// 是否可达。
        reachable: bool,
    },
}
