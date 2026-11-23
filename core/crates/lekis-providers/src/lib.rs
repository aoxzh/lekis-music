//! 媒体服务器源（SRC-04~06）。
//!
//! 和文件系统类源不同，服务器源的元数据由服务器提供，我们不扫描文件；
//! 但我们自己的补全结果（封面、歌词）仍然存在本地覆盖层里，按 `external_id` 关联。
//!
//! 三个实现：
//!
//! | 类型 | 结构体 | 认证 | 分页 |
//! |---|---|---|---|
//! | Subsonic / OpenSubsonic | [`opensubsonic::OpenSubsonic`] | `u` + `t=md5(pw+salt)` + `s` | `search3` / `getAlbumList2` |
//! | Jellyfin / Emby | [`jellyfin::Jellyfin`] | `X-Emby-Token` 请求头 | `/Items` 的 `StartIndex` |
//! | Plex | [`plex::Plex`] | `X-Plex-Token` 请求头 | `/library/sections/{id}/all` |
//!
//! 三条通用约定：
//! - **构造函数不发网络请求**（只做参数校验），连通性由 [`MediaServer::ping`] 验证，
//!   这样上层可以在扫描开始时同步建好客户端；
//! - 凭据只放在请求头或 query 里，**永远不进日志**；错误信息里也只有动作名和状态码；
//! - 错误统一映射到 [`lekis_types::ErrorCode`]（401 → `Auth`、404 → `NotFound`、429 → `RateLimited`……）。

pub mod jellyfin;
pub mod opensubsonic;
pub mod plex;

mod datetime;
mod http;
mod md5;
mod xml;

use async_trait::async_trait;
use lekis_types::{Lyrics, Result, SourceKind};

/// 服务器上的一首歌（同步到本地资料库前的中间形式）。
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteTrack {
    /// 服务器上的 ID。
    pub external_id: String,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artists: Vec<String>,
    /// 专辑。
    pub album: Option<String>,
    /// Opaque album identity scoped to this source.
    pub external_album_id: Option<String>,
    /// Album-level artists.
    pub album_artists: Vec<String>,
    /// Disc and track position.
    pub disc_no: Option<u32>,
    /// Track number within the disc.
    pub track_no: Option<u32>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// MusicBrainz 录音 ID（服务器提供的话）。
    pub mbid_recording: Option<String>,
    /// 服务器端的封面 ID。
    pub cover_id: Option<String>,
}

/// 播放请求的质量偏好。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamQuality {
    /// 原始文件。
    Original,
    /// 服务端转码到指定码率（kbps）。
    Transcode {
        /// 目标码率。
        max_kbps: u32,
    },
}

/// 播放地址。
#[derive(Debug, Clone, PartialEq)]
pub struct StreamTarget {
    /// URL（可能是带签名的临时地址）。
    pub url: String,
    /// 需要附加的请求头。
    pub headers: Vec<(String, String)>,
    /// 是否支持 Range 请求（决定能不能拖动进度条）。
    pub seekable: bool,
}

/// 媒体服务器接口。
#[async_trait]
pub trait MediaServer: Send + Sync {
    /// 类型。
    fn kind(&self) -> SourceKind;

    /// 检查连通性和凭据。
    async fn ping(&self) -> Result<()>;

    /// 分页拉取全部曲目（首次同步和增量同步都用它；支持增量的服务器传 `since_ms`）。
    async fn list_tracks(
        &self,
        offset: u32,
        limit: u32,
        since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>>;

    /// 获取播放地址。
    async fn stream(&self, external_id: &str, quality: StreamQuality) -> Result<StreamTarget>;

    /// Server album artwork, if supported and available.
    async fn album_artwork(&self, _album_id: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }

    /// Server-native lyrics, if supported and available.
    async fn lyrics(&self, _external_id: &str) -> Result<Option<Lyrics>> {
        Ok(None)
    }

    /// 上报播放（服务器自己的播放统计）。
    async fn scrobble(&self, external_id: &str, played_at_ms: i64) -> Result<()>;
}
