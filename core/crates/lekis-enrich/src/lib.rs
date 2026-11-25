//! 元数据补全（ENR-01~12）。
//!
//! ```text
//! 内嵌数据 → 同目录 sidecar → 指纹识别（AcoustID → MBID）→ 在线提供方（按优先级）→ 打分
//!   分数 ≥ AUTO_APPLY_THRESHOLD：自动应用（写覆盖层，不改原文件）
//!   REVIEW_THRESHOLD ≤ 分数 < AUTO_APPLY_THRESHOLD：进入待确认队列
//!   分数 < REVIEW_THRESHOLD：丢弃
//! ```
//!
//! 所有提供方都要遵守各自的速率限制（例如 MusicBrainz 每秒 1 次），结果本地缓存。
//!
//! | 模块 | 内容 |
//! |---|---|
//! | [`providers`] | 内置在线提供方：LRCLIB 歌词、Cover Art Archive 封面、iTunes 封面 |
//! | [`scoring`] | ENR-05 的加权模糊匹配（标题 0.40 / 艺人 0.30 / 时长 0.20 / 专辑 0.10）|
//! | [`throttle`] | ENR-09 的限速与失败退避 |
//! | [`cache`] | ENR-09 的结果本地缓存（带 TTL 与容量上限）|
//! | [`http`] | 各在线功能共用的 HTTP 基础件（UA、超时、状态码映射）|
//! | [`scrobble`] | DIS-07 的第三方听歌记录上报（Last.fm / ListenBrainz / Libre.fm）|
//! | [`ruby`] | UIX-11 的注音歌词：中文歌词逐字标拼音（离线、静态拼音表）|
//! | [`ruby_ja`] | UIX-11 的日语注音：振假名 / 罗马音（离线、静态汉字读音表）|
//! | `md5` | Last.fm 签名要用的 MD5（RFC 1321），仅供 [`scrobble`] 内部使用 |

pub mod apple_music;
pub mod artist_image;
pub mod artwork_ingest;
pub mod bangumi;
pub mod cache;
pub mod http;
pub mod providers;
pub mod providers_extra;
/// 注音歌词（UIX-11）：给中文歌词逐字标拼音，渲染成 ruby。
pub mod ruby;
/// 日语注音（UIX-11）：给日语歌词标振假名或罗马音。
pub mod ruby_ja;
pub mod scoring;
pub mod scrobble;
pub mod spotify;
pub mod throttle;

mod md5;
mod qq_lyrics;
mod ruby_ja_data;

use async_trait::async_trait;
use lekis_types::{LyricsFormat, Result};

pub use qq_lyrics::QqLyrics;
pub use scoring::{score_match, similarity, Explanation};
pub use scrobble::{
    api_signature, should_scrobble, AuthRequest, NowPlaying, Scrobble, ScrobbleClient,
    ScrobbleConfig, ScrobbleQueue, ScrobbleService,
};

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
    /// Return recording versions for explicit selection in the editor.
    async fn search_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        self.find_lyrics(hint).await
    }
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
