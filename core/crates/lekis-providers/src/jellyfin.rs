//! Jellyfin / Emby（SRC-05）。两者 API 大部分相同，用同一个实现，按 `SourceKind` 区分细节。
//!
//! 要点：`/Users/AuthenticateByName` 登录拿 token；`/Items?IncludeItemTypes=Audio` 分页拉曲目；
//! `/Audio/{id}/universal` 获取播放地址（服务器决定直连还是转码）；`/Sessions/Playing` 上报播放。

use crate::{MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{LekisError, Result, SourceKind};

/// Jellyfin / Emby 客户端（占位）。
pub struct Jellyfin {
    kind: SourceKind,
}

impl Jellyfin {
    /// 创建客户端。`kind` 只能是 `Jellyfin` 或 `Emby`。
    pub fn new(kind: SourceKind) -> Result<Self> {
        match kind {
            SourceKind::Jellyfin | SourceKind::Emby => Ok(Self { kind }),
            other => Err(LekisError::invalid(format!(
                "not a jellyfin-like source: {other:?}"
            ))),
        }
    }
}

#[async_trait]
impl MediaServer for Jellyfin {
    fn kind(&self) -> SourceKind {
        self.kind
    }

    async fn ping(&self) -> Result<()> {
        Err(LekisError::not_implemented("jellyfin ping"))
    }

    async fn list_tracks(
        &self,
        _offset: u32,
        _limit: u32,
        _since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        Err(LekisError::not_implemented("jellyfin list_tracks"))
    }

    async fn stream(&self, _external_id: &str, _quality: StreamQuality) -> Result<StreamTarget> {
        Err(LekisError::not_implemented("jellyfin stream"))
    }

    async fn scrobble(&self, _external_id: &str, _played_at_ms: i64) -> Result<()> {
        Err(LekisError::not_implemented("jellyfin scrobble"))
    }
}
