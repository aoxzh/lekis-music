//! OpenSubsonic / Subsonic（Navidrome、gonic、Airsonic、Ampache）。
//!
//! 要点：
//! - 认证用 token + salt：`t = md5(password + salt)`，`s = salt`；只支持明文密码的老服务器走 `p=enc:<hex>`；
//! - 先调 `getOpenSubsonicExtensions` 判断扩展能力（逐字歌词 `songLyrics`、多艺人、`transcodeOffset`……）；
//! - 全量拉取用 `search3`（空查询 + 分页）；
//! - 播放用 `stream`（`maxBitRate`、`format` 控制转码），封面用 `getCoverArt`，歌词用 `getLyricsBySongId`。

use crate::{MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{LekisError, Result, SourceKind};

/// OpenSubsonic 客户端（占位）。
pub struct OpenSubsonic {
    #[allow(dead_code)]
    base_url: String,
    #[allow(dead_code)]
    username: String,
}

impl OpenSubsonic {
    /// 创建客户端。
    pub fn new(base_url: &str, username: &str, _password: String) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            username: username.to_string(),
        }
    }
}

#[async_trait]
impl MediaServer for OpenSubsonic {
    fn kind(&self) -> SourceKind {
        SourceKind::OpenSubsonic
    }

    async fn ping(&self) -> Result<()> {
        Err(LekisError::not_implemented("opensubsonic ping"))
    }

    async fn list_tracks(
        &self,
        _offset: u32,
        _limit: u32,
        _since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        Err(LekisError::not_implemented("opensubsonic search3"))
    }

    async fn stream(&self, _external_id: &str, _quality: StreamQuality) -> Result<StreamTarget> {
        Err(LekisError::not_implemented("opensubsonic stream"))
    }

    async fn scrobble(&self, _external_id: &str, _played_at_ms: i64) -> Result<()> {
        Err(LekisError::not_implemented("opensubsonic scrobble"))
    }
}
