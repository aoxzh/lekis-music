//! 手动封面搜索与在线封面应用 FFI 接口。

use crate::api::dto::ArtworkChangeDto;
use crate::api::error::CoreError;
use crate::internal::core;
use lekis_types::{AlbumId, TrackId};

/// 一条在线搜索到的封面候选。
#[derive(Debug, Clone)]
pub struct ArtworkSearchResultDto {
    /// 图片 URL。
    pub url: String,
    /// 来源提供方名（如 `itunes` / `deezer` / `netease` / `vocadb` / `coverartarchive`）。
    pub source: String,
    /// 图片宽度（可选）。
    pub width: Option<u32>,
    /// 图片高度（可选）。
    pub height: Option<u32>,
    /// 匹配到的标题。
    pub title: Option<String>,
    /// 匹配到的艺人。
    pub artist: Option<String>,
    /// 匹配到的专辑。
    pub album: Option<String>,
    /// 匹配分（`0.0..=1.0`）。
    pub score: f32,
}

impl From<lekis_core::ArtworkSearchResult> for ArtworkSearchResultDto {
    fn from(value: lekis_core::ArtworkSearchResult) -> Self {
        Self {
            url: value.url,
            source: value.source,
            width: value.width,
            height: value.height,
            title: value.title,
            artist: value.artist,
            album: value.album,
            score: value.score,
        }
    }
}

/// 手动在线搜索封面候选。
pub async fn search_artwork_candidates(
    track_id: i64,
    title: String,
    artist: String,
    album: Option<String>,
) -> Result<Vec<ArtworkSearchResultDto>, CoreError> {
    Ok(core()
        .search_artwork_candidates(TrackId(track_id), title, artist, album)
        .await?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// 下载在线图片 URL 并应用为指定曲目（及可选专辑）的封面，返回换前状态以便撤销。
pub async fn set_artwork_from_url(
    url: String,
    track_ids: Vec<i64>,
    album_id: Option<i64>,
) -> Result<ArtworkChangeDto, CoreError> {
    let ids = track_ids.into_iter().map(TrackId).collect();
    Ok(core()
        .set_artwork_from_url(url, ids, album_id.map(AlbumId))
        .await?
        .into())
}
