//! 元数据补全（REQUIREMENTS 3.3 节，ENR-01~12）。
//!
//! ```text
//! 内嵌数据 → 同目录 sidecar → 指纹识别（AcoustID → MBID）→ 在线提供方（按优先级）→ 打分
//!   分数 ≥ AUTO_APPLY_THRESHOLD：自动应用（写覆盖层，不改原文件）
//!   REVIEW_THRESHOLD ≤ 分数 < AUTO_APPLY_THRESHOLD：进入待确认队列
//!   分数 < REVIEW_THRESHOLD：丢弃
//! ```
//!
//! 所有提供方都要遵守各自的速率限制（例如 MusicBrainz 每秒 1 次），结果本地缓存。

pub mod providers;
pub mod scoring;

use async_trait::async_trait;
use lekis_types::{LyricsFormat, Result};

/// 分数达到这个值就自动应用。
pub const AUTO_APPLY_THRESHOLD: f32 = 0.85;
/// 分数达到这个值才进入待确认队列。
pub const REVIEW_THRESHOLD: f32 = 0.5;

/// 查询线索：我们对这首歌已知的信息。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TrackHint {
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artists: Vec<String>,
    /// 专辑。
    pub album: Option<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// MusicBrainz 录音 ID。
    pub mbid_recording: Option<String>,
    /// MusicBrainz 专辑 ID。
    pub mbid_release: Option<String>,
}

/// 提供方返回的候选结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate<T> {
    /// 内容。
    pub payload: T,
    /// 提供方名称（`lrclib`、`coverartarchive`……）。
    pub source: String,
    /// 候选本身描述的曲目信息（用来和 [`TrackHint`] 比对打分）。
    pub matched: TrackHint,
    /// 提供方自己给的置信度（没有就是 1.0）。
    pub provider_confidence: f32,
}

/// 封面候选。
#[derive(Debug, Clone, PartialEq)]
pub struct ArtworkPayload {
    /// 图片地址。
    pub url: String,
    /// 宽。
    pub width: Option<u32>,
    /// 高。
    pub height: Option<u32>,
}

/// 歌词候选。
#[derive(Debug, Clone, PartialEq)]
pub struct LyricsPayload {
    /// 格式。
    pub format: LyricsFormat,
    /// 内容。
    pub content: String,
}

/// 封面提供方。
#[async_trait]
pub trait ArtworkProvider: Send + Sync {
    /// 名称。
    fn name(&self) -> &str;
    /// 查找封面。
    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>>;
}

/// 歌词提供方。
#[async_trait]
pub trait LyricsProvider: Send + Sync {
    /// 名称。
    fn name(&self) -> &str;
    /// 查找歌词。
    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>>;
}

/// 对一个候选做出的决定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// 自动应用。
    AutoApply,
    /// 进入待确认队列。
    Review,
    /// 丢弃。
    Discard,
}

/// 根据分数决定怎么处理。
pub fn decide(score: f32) -> Decision {
    if score >= AUTO_APPLY_THRESHOLD {
        Decision::AutoApply
    } else if score >= REVIEW_THRESHOLD {
        Decision::Review
    } else {
        Decision::Discard
    }
}
