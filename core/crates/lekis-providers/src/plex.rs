//! Plex（SRC-06，P1）。
//!
//! 要点：通过 plex.tv 的 PIN 授权流程拿 token（在系统浏览器里完成，不在 App 里输入密码）；
//! 用 `/api/v2/resources` 找到服务器的局域网地址和远程地址，配合 SRC-14 网络感知选路。

use crate::{MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{LekisError, Result, SourceKind};

/// Plex 客户端（占位）。
pub struct Plex;

#[async_trait]
impl MediaServer for Plex {
    fn kind(&self) -> SourceKind {
        SourceKind::Plex
    }

    async fn ping(&self) -> Result<()> {
        Err(LekisError::not_implemented("plex ping"))
    }

    async fn list_tracks(
        &self,
        _offset: u32,
        _limit: u32,
        _since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        Err(LekisError::not_implemented("plex list_tracks"))
    }

    async fn stream(&self, _external_id: &str, _quality: StreamQuality) -> Result<StreamTarget> {
        Err(LekisError::not_implemented("plex stream"))
    }

    async fn scrobble(&self, _external_id: &str, _played_at_ms: i64) -> Result<()> {
        Err(LekisError::not_implemented("plex scrobble"))
    }
}
