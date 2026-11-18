//! 内置提供方（ENR-01、ENR-03）。都是占位，接口已经固定。
//!
//! | 提供方 | 用途 | 限制 |
//! |---|---|---|
//! | LRCLIB | 歌词（逐行同步）| 免 Key；`/api/get?track_name&artist_name&album_name&duration` |
//! | Cover Art Archive | 封面（按 MBID）| 免 Key；需要先有 Release MBID |
//! | iTunes Search API | 封面 | 免 Key；每分钟约 20 次，结果图片地址可以改尺寸参数 |
//! | Deezer | 封面、艺人图 | 免 Key |
//! | MusicBrainz / AcoustID | 识别 | MusicBrainz 每秒 1 次且必须带 User-Agent；AcoustID 需要应用 Key |
//!
//! 商业化前要逐一确认各提供方的商用许可（REQUIREMENTS 第 5 章）。
//! 第三方灰色来源（网易云、QQ 音乐等）**不内置**，由社区插件提供。

use crate::{ArtworkPayload, ArtworkProvider, Candidate, LyricsPayload, LyricsProvider, TrackHint};
use async_trait::async_trait;
use lekis_types::{LekisError, Result};

/// LRCLIB 歌词。
pub struct Lrclib;

#[async_trait]
impl LyricsProvider for Lrclib {
    fn name(&self) -> &str {
        "lrclib"
    }

    async fn find_lyrics(&self, _hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        Err(LekisError::not_implemented("lrclib"))
    }
}

/// Cover Art Archive 封面。
pub struct CoverArtArchive;

#[async_trait]
impl ArtworkProvider for CoverArtArchive {
    fn name(&self) -> &str {
        "coverartarchive"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        if hint.mbid_release.is_none() {
            return Ok(Vec::new()); // 没有 Release MBID 就查不了，交给下一个提供方
        }
        Err(LekisError::not_implemented("coverartarchive"))
    }
}

/// iTunes Search API 封面。
pub struct ITunes;

#[async_trait]
impl ArtworkProvider for ITunes {
    fn name(&self) -> &str {
        "itunes"
    }

    async fn find_artwork(&self, _hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        Err(LekisError::not_implemented("itunes search"))
    }
}
